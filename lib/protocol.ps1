# =============================================================================
#  protocol.ps1 —— 门户认证协议模块
# -----------------------------------------------------------------------------
#  实现 raas 门户的认证交互（全部使用系统自带能力，不依赖第三方工具）：
#
#      POST {门户}/api/login.php     提交账号密码
#      POST {门户}/api/stat.php      查询 / 轮询认证状态
#      POST {门户}/api/ack_auth.php  认证成功后的回执
#      POST {门户}/api/logoff.php    注销下线
#
#  接口路径都可以在 config.json 的 portal.paths 中修改，以兼容不同学校。
#
#  返回码语义：
#      ret = 0    认证成功 / 在线
#      ret = 3    已经认证成功（同样视为在线，避免重复登录）
#      ret = 2    正在认证中（继续轮询）
#      ret = 255  且 msg 以 ARG 开头 -> 服务端要求 URL 附带 AC 参数
# =============================================================================

# 认证结果返回码常量
$script:RET_OK       = 0
$script:RET_ALREADY  = 3
$script:RET_PENDING  = 2
$script:RET_ARG      = 255
# 明确表示「账号或密码不正确」等失败码
$script:RET_BADCRED  = @(4, 5, 6, 7, 8, 9, 10, 11, 20, 21)

# 浏览器 User-Agent，尽量与常见浏览器一致
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# ---------------------------------------------------------------------------
# URL 与请求辅助
# ---------------------------------------------------------------------------

function Get-PortalUrl {
    <#
    .概要
        拼出某个接口的完整 URL。
    .参数 Key
        portal.paths 中的键名：login / stat / ack / logoff / crypto / home
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $base = ([string](Get-ConfigValue -Config $Config -Path 'portal.base_url' -Default '')).TrimEnd('/')
    $path = ([string](Get-ConfigValue -Config $Config -Path "portal.paths.$Key" -Default '')).TrimStart('/')
    $url = "$base/$path"

    # AC 跳转参数（一般留空，个别门户要求携带）
    $query = ([string](Get-ConfigValue -Config $Config -Path 'portal.query' -Default '')).Trim('&', '?')
    if ($query -ne '') {
        if ($url.Contains('?')) { $url += "&$query" } else { $url += "?$query" }
    }
    return $url
}

function Invoke-WebRequestInternal {
    <#
    .概要
        HTTP 请求的底层封装。不抛异常，离线时返回 StatusCode=0。
        强制使用 TLS 1.2（部分老系统默认不启用，会导致 HTTPS 门户连不上）。
    .输出
        具有 StatusCode 与 Content 两个属性的对象。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Method = 'GET',
        [string]$Body = $null,
        [string]$ContentType = 'application/x-www-form-urlencoded; charset=UTF-8',
        [int]$TimeoutSec = 15,
        [byte[]]$RawBody = $null,
        [switch]$Binary
    )

    # 部分 Windows 版本默认不启用 TLS 1.2，这里显式打开，避免 HTTPS 门户握手失败
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch { }

    $result = [pscustomobject]@{ StatusCode = 0; Content = ''; Error = '' }
    try {
        $params = @{
            Uri             = $Url
            Method          = $Method
            UseBasicParsing = $true
            TimeoutSec      = $TimeoutSec
            UserAgent       = $script:UserAgent
            Headers         = @{
                'Accept'          = '*/*'
                'Accept-Language' = 'zh-CN,zh;q=0.9'
            }
        }
        # 注意：PowerShell 中未传入的 [string] 参数是空字符串而不是 $null。
        # 若把空字符串当作 Body 交给 GET 请求，.NET 会抛出
        # "Cannot send a content-body with this verb-type"，
        # 因此这里必须先把「空」归一化为「无正文」再判断。
        $hasRaw  = ($PSBoundParameters.ContainsKey('RawBody') -and $null -ne $RawBody -and $RawBody.Length -gt 0)
        $hasBody = ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body -and ([string]$Body).Length -gt 0)

        if ($hasRaw) {
            $params['Body'] = $RawBody
            $params['ContentType'] = $ContentType
        }
        elseif ($hasBody) {
            $params['Body'] = $Body
            $params['ContentType'] = $ContentType
        }

        $resp = Invoke-WebRequest @params
        $result.StatusCode = [int]$resp.StatusCode
        if ($Binary) { $result.Content = $resp.Content }
        else { $result.Content = [string]$resp.Content }
    }
    catch {
        $webResp = $null
        try { $webResp = $_.Exception.Response } catch { }
        if ($webResp -and $webResp.StatusCode) {
            $result.StatusCode = [int]$webResp.StatusCode
            try {
                $sr = New-Object System.IO.StreamReader($webResp.GetResponseStream())
                $result.Content = $sr.ReadToEnd()
                $sr.Close()
            }
            catch { }
        }
        $result.Error = $_.Exception.Message
    }
    return $result
}

function ConvertFrom-PortalJson {
    <#
    .概要
        解析门户返回的 JSON，兼容 callback({...}) 形式的外层包裹。
    .输出
        解析成功返回对象；失败返回 $null。
    #>
    param([Parameter(Mandatory = $true)][string]$Text)

    $t = $Text.Trim()
    if ($t -eq '') { return $null }
    try { return ($t | ConvertFrom-Json) } catch { }

    # 兼容 callback({...})
    $m = [regex]::Match($t, '\{.*\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) {
        try { return ($m.Groups[0].Value | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Get-AccountFields {
    <#
    .概要
        构造所有接口都要带的基础表单字段（账号 + 认证模式）。
    #>
    param([Parameter(Mandatory = $true)]$Config)
    return @{
        user     = [string](Get-ConfigValue -Config $Config -Path 'account.username' -Default '')
        authmode = [string](Get-ConfigValue -Config $Config -Path 'account.authmode' -Default '0')
    }
}

function Invoke-PortalPost {
    <#
    .概要
        向门户接口发起 POST 请求，内置 3 种适配方案自动重试：
          方案1：标准 UTF-8 表单编码 + 浏览器请求头
          方案2：改用 GBK 编码提交（部分老门户按 GBK 解析表单）
          方案3：改用系统自带 curl.exe 提交（绕过 .NET 的细节差异）
    .输出
        具有 Ok / Json / Raw / StatusCode 的对象。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][hashtable]$Fields,
        [int]$TimeoutSec = 15
    )

    $url = Get-PortalUrl -Config $Config -Key $Key
    $pairs = @()
    foreach ($k in $Fields.Keys) {
        $pairs += ("{0}={1}" -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Fields[$k]))
    }
    $bodyText = $pairs -join '&'

    $result = [pscustomobject]@{ Ok = $false; Json = $null; Raw = ''; StatusCode = 0; Adapter = ''; Error = '' }

    # ---- 方案1：标准 UTF-8 表单提交 ----
    $r1 = Invoke-WebRequestInternal -Url $url -Method 'POST' -Body $bodyText -TimeoutSec $TimeoutSec
    $result.StatusCode = $r1.StatusCode
    $result.Raw = $r1.Content
    $result.Error = $r1.Error
    $json = ConvertFrom-PortalJson -Text $r1.Content
    if ($null -ne $json) {
        $result.Ok = $true; $result.Json = $json; $result.Adapter = '方案1(标准UTF-8表单)'
        return $result
    }

    # ---- 方案2：GBK 编码提交 ----
    try {
        $gbk = [System.Text.Encoding]::GetEncoding(936)
        $r2 = Invoke-WebRequestInternal -Url $url -Method 'POST' `
            -RawBody $gbk.GetBytes($bodyText) `
            -ContentType 'application/x-www-form-urlencoded' -TimeoutSec $TimeoutSec
        $json2 = ConvertFrom-PortalJson -Text $r2.Content
        if ($null -ne $json2) {
            $result.Ok = $true; $result.Json = $json2; $result.Raw = $r2.Content
            $result.StatusCode = $r2.StatusCode; $result.Adapter = '方案2(GBK表单编码)'
            return $result
        }
    }
    catch { }

    # ---- 方案3：改用系统自带 curl.exe ----
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        try {
            $curlArgs = @(
                '--silent', '--show-error', '--max-time', "$TimeoutSec",
                '--request', 'POST',
                '--header', 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8',
                '--user-agent', $script:UserAgent,
                '--data', $bodyText,
                $url
            )
            $curlOut = & $curl @curlArgs 2>&1
            $outText = ($curlOut | Out-String).Trim()
            $json3 = ConvertFrom-PortalJson -Text $outText
            if ($null -ne $json3) {
                $result.Ok = $true; $result.Json = $json3; $result.Raw = $outText
                $result.Adapter = '方案3(系统自带curl)'
                return $result
            }
            if (-not $result.Raw) { $result.Raw = $outText }
        }
        catch { }
    }

    return $result
}

# ---------------------------------------------------------------------------
# 门户业务接口
# ---------------------------------------------------------------------------

function Get-PortalStat {
    <#
    .概要
        查询门户在线状态。
    .输出
        门户返回的对象；不可达或无法解析时返回 $null。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$Quiet
    )
    $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)
    $r = Invoke-PortalPost -Config $Config -Key 'stat' -Fields (Get-AccountFields -Config $Config) -TimeoutSec $timeout
    if (-not $r.Ok -and -not $Quiet) {
        Write-Log -Message "状态接口无有效响应（$($r.Adapter) $($r.Error)）：$($r.Raw)" -Level '警告'
    }
    return $r.Json
}

function Test-PortalAuthenticated {
    <#
    .概要
        根据状态接口返回值判断是否已认证在线。
    #>
    param($Stat)
    if ($null -eq $Stat) { return $false }
    $ret = $Stat.PSObject.Properties['ret']
    if ($null -eq $ret) { return $false }
    return ($ret.Value -eq $script:RET_OK -or $ret.Value -eq $script:RET_ALREADY)
}

function Test-RetCodeIsBadCred {
    <#
    .概要
        判断返回码是否表示「账号密码错误」这类明确失败。
    #>
    param($Ret)
    if ($null -eq $Ret) { return $false }
    return ($script:RET_BADCRED -contains [int]$Ret)
}

function Invoke-PortalLogin {
    <#
    .概要
        提交登录请求。
    .输出
        具有 Ret / Msg / Adapter 的对象。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$EncryptedPass
    )

    $fields = Get-AccountFields -Config $Config
    $fields['pass'] = $EncryptedPass

    # 仅在配置了运营商线路时才携带 pool / isp_id
    $pool = [string](Get-ConfigValue -Config $Config -Path 'account.pool' -Default '')
    if ($pool.Trim() -ne '') {
        $fields['pool'] = $pool
        $fields['isp_id'] = [string](Get-ConfigValue -Config $Config -Path 'account.isp_id' -Default '0')
        $fields['pxyacct'] = ''
    }

    $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)
    $r = Invoke-PortalPost -Config $Config -Key 'login' -Fields $fields -TimeoutSec $timeout

    $out = [pscustomobject]@{ Ret = $null; Msg = ''; Adapter = $r.Adapter; Raw = $r.Raw; Error = $r.Error }
    if (-not $r.Ok) {
        $out.Msg = "无有效响应：$($r.Error)"
        return $out
    }
    $retProp = $r.Json.PSObject.Properties['ret']
    if ($retProp) { $out.Ret = $retProp.Value }
    $msgProp = $r.Json.PSObject.Properties['msg']
    if ($msgProp) { $out.Msg = [string]$msgProp.Value }
    return $out
}

function Send-PortalAck {
    <#
    .概要
        登录成功后通知门户（与前端 aff_ack_auth 行为一致）。失败不影响认证结果。
    #>
    param([Parameter(Mandatory = $true)]$Config)
    try {
        $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)
        [void](Invoke-PortalPost -Config $Config -Key 'ack' -Fields (Get-AccountFields -Config $Config) -TimeoutSec $timeout)
    }
    catch {
        Write-Log -Message "回执通知失败（可忽略）：$($_.Exception.Message)" -Level '警告'
    }
}

function Invoke-PortalLogoff {
    <#
    .概要
        注销下线（排查用）。
    #>
    param([Parameter(Mandatory = $true)]$Config)
    try {
        $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)
        $r = Invoke-PortalPost -Config $Config -Key 'logoff' -Fields (Get-AccountFields -Config $Config) -TimeoutSec $timeout
        return $r.Raw
    }
    catch {
        return "注销失败：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 连通性检测
# ---------------------------------------------------------------------------

function Test-InternetAccess {
    <#
    .概要
        判断「现在能不能正常上网」。
        做法：请求一个可信小文件并校验返回内容，
              这样能识别出「被门户劫持到登录页」的情况（只判断能否连通是不够的）。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $url = [string](Get-ConfigValue -Config $Config -Path 'keepalive.connect_test_url' -Default '')
    $expect = [string](Get-ConfigValue -Config $Config -Path 'keepalive.connect_test_expect' -Default '')
    $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)

    if ($url -eq '') { return $false }

    $r = Invoke-WebRequestInternal -Url $url -TimeoutSec $timeout
    if ($r.StatusCode -eq 200 -and $expect -ne '' -and $r.Content -like "*$expect*") { return $true }
    return $false
}

function Test-PortalReachable {
    <#
    .概要
        判断门户服务器是否可达（能建立 HTTP 连接）。
    #>
    param([Parameter(Mandatory = $true)]$Config)
    $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)
    $r = Invoke-WebRequestInternal -Url (Get-PortalUrl -Config $Config -Key 'home') -TimeoutSec $timeout
    return ($r.StatusCode -eq 200)
}
