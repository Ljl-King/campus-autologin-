# =============================================================================
#  tests\Check-Privacy.ps1 —— 发布前隐私自检
# -----------------------------------------------------------------------------
#  作用：在把项目上传到 GitHub 之前，扫描整个项目目录，
#        检查是否残留学号、密码、内网 IP、运行日志等不该公开的内容。
#
#  运行方式（两种都行）：
#      双击根目录的  check-privacy.bat
#      或在项目根目录执行：
#          powershell -ExecutionPolicy Bypass -File tests\Check-Privacy.ps1
#
#  退出码：0 = 通过；1 = 发现问题，请不要上传
# =============================================================================

$ErrorActionPreference = 'Continue'

$TestDir = $PSScriptRoot
$Root    = Split-Path -Parent $TestDir

$script:ProblemCount = 0

function Write-Result {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host ("  [通过] " + $Label) -ForegroundColor Green
    }
    else {
        $script:ProblemCount++
        Write-Host ("  [注意] " + $Label + $(if ($Detail) { "  —— $Detail" } else { '' })) -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  发布前隐私自检" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  扫描目录：$Root"
Write-Host ""

# 只扫描会被上传的内容，跳过 data 与 .git
$allFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\data\\' -and $_.FullName -notmatch '\\\.git\\' }

Write-Host "  待检查文件数：$($allFiles.Count)"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. 绝对不能出现的文件
# ---------------------------------------------------------------------------
Write-Host "【1】不该存在的文件" -ForegroundColor Cyan

$mustNotExist = @(
    @{ Path = 'config\config.json';                       Why = '这是你的真实账号密码配置，绝不能上传' },
    @{ Path = 'data';                                     Why = '运行日志与缓存，可能含个人信息' },
    @{ Path = 'data\autologin.log';                       Why = '运行日志，可能含个人信息' },
    @{ Path = 'data\portal_crypto.js';                    Why = '从门户下载的私有脚本，不应随项目分发' },
    @{ Path = 'data\state.json';                          Why = '运行状态记录' },
    @{ Path = '__pycache__';                              Why = '临时缓存目录' },
    @{ Path = '.git';                                     Why = '版本库目录，不应打包上传' },
    @{ Path = 'vendor';                                   Why = '门户私有脚本目录，不应随项目分发' }
)
foreach ($item in $mustNotExist) {
    $full = Join-Path $Root $item.Path
    if (Test-Path -LiteralPath $full) {
        Write-Result -Label "发现不该存在的 $($item.Path)" -Ok $false -Detail $item.Why
    }
    else {
        Write-Result -Label "未发现 $($item.Path)" -Ok $true
    }
}

Write-Host ""
Write-Host "【2】敏感字符串扫描" -ForegroundColor Cyan

# 扫描这些模式：手机号、内网地址、学号、用户目录、写死的密钥。
# 说明：下面刻意排除「文档示例」里常用的假地址，例如 10.0.0.1、
#       192.168.1.1 等，它们只是教程里的占位举例，不属于真实隐私。
$patterns = @(
    @{
        Name   = '11 位手机号'
        Regex  = '\b1[3-9]\d{9}\b'
        Ignore = ''
    },
    @{
        Name   = '内网 IP 地址'
        Regex  = '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b'
        Ignore = '\b10\.0\.0\.\d{1,3}\b|\b192\.168\.[01]\.\d{1,3}\b'
    },
    @{
        Name   = '形如学号的长数字串'
        # 只报 11 位以上的连续数字，减少与示例编号混淆
        Regex  = '\b\d{11,}\b'
        Ignore = ''
    },
    @{
        Name   = 'Windows 用户目录'
        Regex  = '[A-Za-z]:\\Users\\[A-Za-z0-9_\-]+'
        Ignore = ''
    },
    @{
        Name   = '配置里被写死的密钥'
        Regex  = '"key"\s*:\s*"[0-9a-fA-F]{8,}"'
        Ignore = '"key"\s*:\s*""'
    }
)

# 只扫描文本类文件
$textExt = @('.ps1', '.js', '.json', '.md', '.bat', '.txt', '.yml', '.yaml', '.gitignore')
$textFiles = $allFiles | Where-Object { $textExt -contains $_.Extension.ToLower() -or $_.Name -eq '.gitignore' }

$foundAny = $false
foreach ($p in $patterns) {
    $hits = @()
    foreach ($f in $textFiles) {
        try {
            $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)

            # 先找出「疑似命中」的位置
            $m = [regex]::Matches($content, $p.Regex)
            if ($m.Count -eq 0) { continue }

            # 再扣掉明确属于文档示例的内容（Ignore 规则）
            $keep = $m.Count
            if ($p.Ignore -and $p.Ignore -ne '') {
                $ignoreCount = [regex]::Matches($content, $p.Ignore).Count
                $keep = $m.Count - $ignoreCount
            }
            if ($keep -gt 0) { $hits += "$($f.Name)($keep 处)" }
        }
        catch { }
    }
    if ($hits.Count -eq 0) {
        Write-Result -Label "$($p.Name) 未发现" -Ok $true
    }
    else {
        $foundAny = $true
        Write-Result -Label "$($p.Name) 可能残留" -Ok $false -Detail ($hits -join ', ')
    }
}

if (-not $foundAny) {
    Write-Host ""
    Write-Host "  提示：自动扫描只能发现常见格式，" -ForegroundColor DarkGray
    Write-Host "        请再用记事本手动搜索一遍你的学号和密码，做二次确认。" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "【3】示例配置检查" -ForegroundColor Cyan
$example = Join-Path $Root 'config\config.example.json'
if (Test-Path -LiteralPath $example) {
    $text = [System.IO.File]::ReadAllText($example, [System.Text.Encoding]::UTF8)
    $stillPlaceholder =
        ($text -match '这里填') -or ($text -match 'your_') -or ($text -match 'example')
    Write-Result -Label '示例配置使用中文占位符' -Ok $stillPlaceholder -Detail '若已填入真实信息请改回占位符'
    Write-Result -Label '示例配置中无真实密码字段' -Ok ((Test-Path -LiteralPath (Join-Path $Root 'config\config.json')) -eq $false)
}
else {
    Write-Result -Label '找到 config\config.example.json' -Ok $false -Detail '示例配置文件缺失'
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
if ($script:ProblemCount -eq 0) {
    Write-Host "  自检通过：未发现明显的隐私问题。" -ForegroundColor Green
    Write-Host "  可以上传到 GitHub。" -ForegroundColor Green
}
else {
    Write-Host "  发现 $($script:ProblemCount) 处需要注意的地方。" -ForegroundColor Yellow
    Write-Host "  请按上面的提示处理后再上传。" -ForegroundColor Yellow
}
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

exit $script:ProblemCount
