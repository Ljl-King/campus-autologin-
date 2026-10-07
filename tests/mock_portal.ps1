# =============================================================================
#  tests\mock_portal.ps1 —— 本地假门户（仅供离线测试）
# -----------------------------------------------------------------------------
#  模拟一个 raas 门户的接口，用于在不连校园网的情况下验证整套程序：
#      GET  /index.html               门户首页
#      GET  /assets/js/crypto.js      门户加密脚本（用测试替身）
#      GET  /connecttest.txt          连通性检测文件
#      POST /api/login.php            提交登录
#      POST /api/stat.php             查询认证状态
#      POST /api/ack_auth.php         认证回执
#      POST /api/logoff.php           注销
#
#  由 tests\Run-Tests.ps1 自动启动，一般不需要手动调用。
# =============================================================================

param([int]$Port = 18090, [int]$MaxSeconds = 180)

$script:Online    = $false
$script:FailLogin = $false
$script:StartTime = Get-Date
$script:Hits      = New-Object System.Collections.ArrayList

function Write-JsonResponse {
    param($Context, $Object)
    $json  = $Object | ConvertTo-Json -Compress -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Write-TextResponse {
    param($Context, $Text, $ContentType)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "假门户已启动，端口 $Port"

while ($listener.IsListening) {
    # 自动退出，避免测试异常中断后一直占用端口
    if (((Get-Date) - $script:StartTime).TotalSeconds -gt $MaxSeconds) {
        Write-Host "假门户到达运行时限，自动退出"
        break
    }

    try { $ctx = $listener.GetContext() } catch { break }

    $path   = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod
    $body   = ''
    if ($ctx.Request.HasEntityBody) {
        $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $body = $sr.ReadToEnd()
        $sr.Close()
    }
    [void]$script:Hits.Add([pscustomobject]@{ Method = $method; Path = $path; Body = $body })

    if ($path -match 'connecttest') {
        Write-TextResponse $ctx 'Microsoft Connect Test' 'text/plain'
        continue
    }
    if ($path -match 'crypto\.js') {
        $stub = Join-Path $PSScriptRoot 'mock_portal_crypto.js'
        Write-TextResponse $ctx (Get-Content -LiteralPath $stub -Raw) 'application/javascript'
        continue
    }
    if ($path -match 'login\.php') {
        if ($script:FailLogin) { Write-JsonResponse $ctx @{ ret = 4; msg = '帐号或密码不正确！[4]'; data = '' } }
        else { $script:Online = $true; Write-JsonResponse $ctx @{ ret = 0; msg = '正在认证...'; data = @{ type = 0 } } }
        continue
    }
    if ($path -match 'stat\.php') {
        if ($script:Online) { Write-JsonResponse $ctx @{ ret = 0; msg = '在线'; data = @{ type = 0 } } }
        else { Write-JsonResponse $ctx @{ ret = 1; msg = '未认证'; data = @() } }
        continue
    }
    if ($path -match 'ack') {
        Write-JsonResponse $ctx @{ ret = 0; msg = ''; data = @() }
        continue
    }
    if ($path -match 'logoff') {
        $script:Online = $false
        Write-JsonResponse $ctx @{ ret = 3; msg = '用户不在线！'; data = '' }
        continue
    }
    Write-TextResponse $ctx '<html>portal</html>' 'text/html'
}

$listener.Stop()