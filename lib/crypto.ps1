# =============================================================================
#  crypto.ps1 —— 口令加密模块（零依赖实现）
# -----------------------------------------------------------------------------
#  背景：校园门户在提交密码前会先加密，用的是门户自带 crypto.js 里的私有算法
#        （raas 门户称 VDX，是一种自研分组密码，与标准 DES 输出不同）。
#        因此无法用 .NET 内置算法等价替代。
#
#  本模块的做法（完全不需要安装 Python / Node.js）：
#     1. 用系统自带的能力下载门户的 crypto.js 并缓存到 data 目录；
#     2. 用系统自带的 Windows Script Host（cscript.exe，Win7 起内置）
#        执行该脚本，得到与浏览器逐字节一致的密文。
#
#  依赖：cscript.exe、ADODB.Stream（均系统自带）、注册表读取（用于代码页）。
# =============================================================================

# Windows Script Host 可执行文件路径
$script:CscriptExe = Join-Path $env:WINDIR 'System32\cscript.exe'

function Test-WshAvailable {
    <#
    .概要
        检查系统是否具备 Windows Script Host（零依赖加密的前提）。
    #>
    return (Test-Path -LiteralPath $script:CscriptExe)
}

function New-RandomPrefix {
    <#
    .概要
        生成门户前端要求的 4 个随机字符前缀。
        门户脚本里的字符表长度是 61，对应
        A-Z a-z 0-9 共 62 个字符中的前 61 个（即去掉最后一个 '9'）。
    #>
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz012345678' + '9'
    # 上述字符串共 62 个字符；门户实际从 61 个里取值（索引 0..60）
    $pool = $alphabet.Substring(0, 61)
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        [void]$sb.Append($pool[$b % $pool.Length])
    }
    return $sb.ToString()
}

function Get-CryptoJsPath {
    <#
    .概要
        返回缓存的 crypto.js 完整路径。
    #>
    return (Join-Path (Get-DataDir) 'portal_crypto.js')
}

function Get-EncodeEnginePath {
    <#
    .概要
        返回加密引擎脚本路径。
    #>
    return (Join-Path $script:AppRoot 'lib\encode_engine.js')
}

function Save-CryptoJs {
    <#
    .概要
        下载门户的 crypto.js 并缓存到 data 目录。
        说明：本程序不附带门户的私有脚本（版权原因），
              因此第一次运行需要在能访问门户的网络环境下执行一次。
    .输出
        成功返回 $true。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$Force
    )

    $target = Get-CryptoJsPath
    if ((Test-Path -LiteralPath $target) -and -not $Force) { return $true }

    $url = Get-PortalUrl -Config $Config -Key 'crypto'
    Write-Log -Message "正在从门户下载加密脚本：$url"

    try {
        $resp = Invoke-WebRequestInternal -Url $url -TimeoutSec 20
        if ($resp.StatusCode -eq 200 -and $resp.Content.Length -gt 1000) {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($target, $resp.Content, $utf8)
            Write-Log -Message "加密脚本已缓存（$($resp.Content.Length) 字节）" -Level '成功'
            return $true
        }
        Write-Log -Message "下载加密脚本返回异常：HTTP $($resp.StatusCode)，长度 $($resp.Content.Length)" -Level '警告'
    }
    catch {
        Write-Log -Message "下载加密脚本失败：$($_.Exception.Message)" -Level '警告'
    }

    Write-Log -Message "无法获取门户加密脚本。请在连上校园网后重新运行本程序，或手动执行 --fetch-crypto。" -Level '错误'
    return $false
}

function Get-CryptoKey {
    <#
    .概要
        确定加密密钥：
          1) 优先使用配置文件中 crypto.key 显式指定的值；
          2) 否则从缓存的 crypto.js 里自动解析门户使用的密钥常量。
    .输出
        密钥字符串；解析失败返回 $null。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $explicit = [string](Get-ConfigValue -Config $Config -Path 'crypto.key' -Default '')
    if ($explicit.Trim() -ne '') { return $explicit.Trim() }

    $path = Get-CryptoJsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    # 门户写法（可能被压缩成方括号调用）：
    #   CryptoJS.enc.Utf8.parse('0123456789abcdef')
    #   CryptoJS['enc']['Utf8']['parse']('0123456789abcdef')
    $patterns = @(
        "parse['""]?\s*\]?\s*\]?\s*\(\s*['""]([0-9a-fA-F]{8,64})['""]\s*\)",
        "['""]([0-9a-fA-F]{16})['""]"
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($text, $p)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

function ConvertTo-EncryptedPass {
    <#
    .概要
        按门户算法把明文口令加密为十六进制字符串。
    .参数 PlainPassword
        明文密码。
    .参数 Config
        配置对象。
    .输出
        小写十六进制密文；失败时抛出中文异常。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PlainPassword,
        [Parameter(Mandatory = $true)]$Config
    )

    if (-not (Test-WshAvailable)) {
        throw "系统未找到 Windows Script Host（$script:CscriptExe），无法加密口令。`n  请确认系统文件未被安全软件拦截。"
    }

    $cryptoJs = Get-CryptoJsPath
    if (-not (Test-Path -LiteralPath $cryptoJs)) {
        if (-not (Save-CryptoJs -Config $Config)) {
            throw "缺少门户加密脚本，无法加密口令。`n  请在连上校园网后运行一次，让程序自动下载。"
        }
    }

    $key = Get-CryptoKey -Config $Config
    if (-not $key) {
        throw "无法从门户加密脚本中解析出密钥。`n  可在 config.json 的 crypto.key 中手动填写门户使用的密钥常量。"
    }

    $algorithm = [string](Get-ConfigValue -Config $Config -Path 'crypto.algorithm' -Default 'VDX')

    # 门户前端：4 个随机字符 + 明文，再整体加密
    $prefix = New-RandomPrefix
    $mixed = $prefix + $PlainPassword

    $engine = Get-EncodeEnginePath
    if (-not (Test-Path -LiteralPath $engine)) {
        throw "缺少加密引擎文件：$engine"
    }

    # 临时文件放在 data 目录，避免污染其它位置
    $jobPath = Join-Path (Get-DataDir) 'encode_job.json'
    $outPath = Join-Path (Get-DataDir) 'encode_out.json'
    if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

    # 手工拼 JSON，并转义明文中的特殊字符
    $esc = $mixed.Replace('\', '\\').Replace('"', '\"')
    $jobJson = '{"algorithm":"' + $algorithm + '","key":"' + $key + '","input":"' + $esc + '"}'
    # WSH 读 Unicode 文件最稳，这里按 UTF-16 写入
    [System.IO.File]::WriteAllText($jobPath, $jobJson, [System.Text.Encoding]::Unicode)

    $output = & $script:CscriptExe //nologo //E:JScript $engine $cryptoJs $jobPath $outPath 2>&1
    $exitCode = $LASTEXITCODE

    if (-not (Test-Path -LiteralPath $outPath)) {
        throw "加密口令失败（未生成结果文件，退出码 $exitCode）。`n  引擎输出：$output"
    }

    $resultText = [System.IO.File]::ReadAllText($outPath, [System.Text.Encoding]::Unicode).TrimStart([char]0xFEFF)
    $result = $resultText | ConvertFrom-Json

    if (-not $result.ok) {
        throw "加密口令失败：$($result.error)"
    }
    if ($result.hex -notmatch '^[0-9a-fA-F]+$') {
        throw "加密口令返回了非法结果：$($result.hex)"
    }

    # 清理临时结果文件
    try { Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue } catch {}

    return $result.hex.ToLower()
}
