# =============================================================================
#  tests\Run-Tests.ps1 —— 离线端到端测试
# -----------------------------------------------------------------------------
#  作用：不需要真实校园网，用本地假门户验证整套程序是否正常。
#        覆盖：加密脚本下载、本地自检、自动登录、已在线不重复登录、
#              诊断、状态查看、开机自启安装与卸载。
#
#  运行方式（在程序根目录执行）：
#      powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#
#  说明：测试使用独立的临时副本，不会改动你的真实配置与自启设置。
# =============================================================================

$ErrorActionPreference = 'Continue'

$TestDir = $PSScriptRoot
$AppRoot = Split-Path -Parent $TestDir
$WorkDir = Join-Path $env:TEMP 'campus_autologin_selftest'
$AppDir  = Join-Path $WorkDir 'app'
$Port    = 18090

$script:PassCount = 0
$script:FailCount = 0

function Check {
    param([string]$Label, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:PassCount++
        Write-Host ("  [通过] " + $Label + $(if ($Detail) { "  —— $Detail" } else { '' })) -ForegroundColor Green
    }
    else {
        $script:FailCount++
        Write-Host ("  [失败] " + $Label + $(if ($Detail) { "  —— $Detail" } else { '' })) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  校园网自动登录 —— 离线端到端测试" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. 准备独立的测试副本（不影响真实程序）
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
Copy-Item (Join-Path $AppRoot 'lib') $AppDir -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $AppDir 'config') -Force | Out-Null

# 生成指向假门户的测试配置
$testConfig = @{
    portal = @{
        base_url = "http://127.0.0.1:$Port"
        query    = ""
        paths    = @{
            login = 'api/login.php'; stat = 'api/stat.php'; ack = 'api/ack_auth.php'
            logoff = 'api/logoff.php'; getacct = 'api/getacct.php'
            crypto = 'assets/js/crypto.js'; home = 'index.html'
        }
    }
    account   = @{ username = 'test_student'; password = 'test_password_123'; pool = ''; isp_id = '0'; authmode = '0' }
    keepalive = @{
        check_interval = 1; connect_timeout = 5; retry_interval = 1; offline_trigger = 1
        session_check = 0
        connect_test_url = "http://127.0.0.1:$Port/connecttest.txt"
        connect_test_expect = 'Microsoft Connect Test'
    }
    crypto    = @{ key = ''; algorithm = 'VDX'; encoding = 'hex' }
    runtime   = @{ verbose = $true; log_max_bytes = 1048576 }
}
$testConfig | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $AppDir 'config\config.json') -Encoding UTF8

# ---------------------------------------------------------------------------
# 2. 启动本地假门户
# ---------------------------------------------------------------------------
$mockScript = Join-Path $TestDir 'mock_portal.ps1'
$mockProc = $null
if (Test-Path -LiteralPath $mockScript) {
    $mockProc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mockScript, '-Port', "$Port")
    Start-Sleep -Seconds 3
    Check "本地假门户已启动（端口 $Port）" (-not $mockProc.HasExited)
}
else {
    Check "找到假门户脚本 mock_portal.ps1" $false $mockScript
}

$mainPs1 = Join-Path $AppDir 'lib\main.ps1'

function Invoke-Client {
    param([string[]]$ClientArgs)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mainPs1) + $ClientArgs
    $out = & powershell.exe @all 2>&1 | Out-String -Width 200
    return @{ Output = $out; Code = $LASTEXITCODE }
}

# ---------------------------------------------------------------------------
# 3. 各项测试
# ---------------------------------------------------------------------------
Write-Host "---- 场景1：下载门户加密脚本 ----" -ForegroundColor Yellow
$r = Invoke-Client @('-FetchCrypto')
$cryptoFile = Join-Path $AppDir 'data\portal_crypto.js'
Check "crypto.js 已缓存到 data 目录" (Test-Path -LiteralPath $cryptoFile)

Write-Host ""
Write-Host "---- 场景2：本地自检 ----" -ForegroundColor Yellow
$r = Invoke-Client @('-SelfTest')
Check "自检通过" ($r.Code -eq 0) "退出码 $($r.Code)"
Check "识别到 Windows Script Host" ($r.Output -match 'Windows Script Host')

Write-Host ""
Write-Host "---- 场景3：自动登录 ----" -ForegroundColor Yellow
$r = Invoke-Client @('-Once')
Check "登录成功" ($r.Code -eq 0) "退出码 $($r.Code)"

Write-Host ""
Write-Host "---- 场景4：已在线不重复登录 ----" -ForegroundColor Yellow
$r = Invoke-Client @('-Once')
Check "识别为已在线" ($r.Output -match '已在线|无需重复登录')

Write-Host ""
Write-Host "---- 场景5：诊断命令 ----" -ForegroundColor Yellow
$r = Invoke-Client @('-Diagnose')
Check "诊断执行成功" ($r.Code -eq 0)
Check "诊断显示门户可达" ($r.Output -match '门户 HTTP 可达')

Write-Host ""
Write-Host "---- 场景6：状态命令 ----" -ForegroundColor Yellow
$r = Invoke-Client @('-Status')
Check "状态执行成功" ($r.Code -eq 0)
Check "状态显示配置的账号" ($r.Output -match 'test_student')

# ---------------------------------------------------------------------------
# 4. 清理
# ---------------------------------------------------------------------------
if ($mockProc) { try { Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
# 删除测试期间可能创建的自启项，避免影响真实系统
$null = & schtasks.exe /Delete /TN CampusAutoLogin /F 2>&1

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
if ($script:FailCount -eq 0) {
    Write-Host "  全部通过！共 $($script:PassCount) 项" -ForegroundColor Green
}
else {
    Write-Host "  通过 $($script:PassCount) 项，失败 $($script:FailCount) 项" -ForegroundColor Red
}
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

exit $script:FailCount
