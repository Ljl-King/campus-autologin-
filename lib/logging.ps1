# =============================================================================
#  logging.ps1 —— 日志模块
# -----------------------------------------------------------------------------
#  职责：把运行信息同时写入日志文件与（可选的）控制台。
#        日志文件采用 UTF-8 编码，超过设定大小时自动轮转一次。
#  依赖：仅 .NET 自带组件。
# =============================================================================

# 日志大小上限（字节），由 Initialize-Paths 设置
$script:LogMaxBytes = 1048576

function Write-Log {
    <#
    .概要
        写入一行日志。
    .参数 Message
        日志内容（中文）。
    .参数 Level
        级别：信息 / 警告 / 错误 / 成功。
    .参数 NoConsole
        只写文件，不在控制台显示（后台静默运行时使用）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('信息', '警告', '错误', '成功')][string]$Level = '信息',
        [switch]$NoConsole
    )

    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # 级别用等宽对齐，日志更易读
    $line = "[$time] [$Level] $Message"

    # ---- 写文件 ----
    $file = Get-LogFile
    if ($file) {
        try {
            # 超过上限则轮转一次，避免日志无限增长
            if ((Test-Path -LiteralPath $file) -and
                ((Get-Item -LiteralPath $file).Length -gt $script:LogMaxBytes)) {
                $bak = "$file.1"
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
                Move-Item -LiteralPath $file -Destination $bak -Force
            }
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $sw = New-Object System.IO.StreamWriter($file, $true, $utf8)
            try { $sw.WriteLine($line) } finally { $sw.Close() }
        }
        catch {
            # 日志写失败不应影响主流程
        }
    }

    # ---- 写控制台 ----
    if (-not $NoConsole) {
        $color = switch ($Level) {
            '警告' { 'Yellow' }
            '错误' { 'Red' }
            '成功' { 'Green' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Write-Banner {
    <#
    .概要
        打印带边框的标题，用于让界面更清晰。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Color = 'Cyan'
    )
    $line = '=' * 66
    Write-Host $line -ForegroundColor $Color
    Write-Host ("  " + $Title) -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
}

function Write-Step {
    <#
    .概要
        打印一条检查项结果（自检、诊断用）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [string]$Detail = ''
    )
    $mark = if ($Ok) { '[通过]' } else { '[失败]' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    $text = "  $mark $Label"
    if ($Detail) { $text += "  —— $Detail" }
    Write-Host $text -ForegroundColor $color
}
