# =============================================================================
#  config.ps1 —— 配置读取与校验模块
# -----------------------------------------------------------------------------
#  职责：定位并读取 config.json，提供读取与必填项校验功能。
#        所有个性化信息（学号、密码、门户地址等）都只存在于配置文件中，
#        本程序代码内不含任何真实隐私信息。
#
#  依赖：仅使用 PowerShell 与 .NET 自带组件。
# =============================================================================

# ---------------------------------------------------------------------------
# 全局路径（由 main.ps1 在启动时调用 Initialize-Paths 设置）
# ---------------------------------------------------------------------------
# 注意：这里的变量名统一加 App 前缀，避免与主脚本中的同名变量冲突
#       （模块是点源加载的，作用域相同，变量重名会互相覆盖）
# ---------------------------------------------------------------------------
$script:AppBaseDir = $null   # 程序根目录
$script:DataDir    = $null   # 数据目录（日志、缓存）
$script:LogFile    = $null   # 日志文件
$script:StateFile  = $null   # 运行状态文件
$script:ConfigPath = $null   # 实际使用的配置文件路径

function Initialize-Paths {
    <#
    .概要
        设置程序运行所需的目录与文件路径，并创建 data 目录。
    #>
    param(
        # 不加 Mandatory：允许调用方传入空值，由下面的兜底逻辑自行推导
        [string]$Root,
        [int]$LogMaxBytes = 1048576
    )

    # 兜底：若调用方没能算出根目录，用脚本自身位置推回去
    if (-not $Root) {
        $libDir = $PSScriptRoot
        if ($libDir) { $Root = Split-Path -Parent $libDir }
    }
    if (-not $Root) { throw "无法确定程序根目录。" }

    $script:AppBaseDir = $Root
    $script:DataDir = Join-Path $Root 'data'
    $script:LogFile = Join-Path $script:DataDir 'autologin.log'
    $script:StateFile = Join-Path $script:DataDir 'state.json'
    $script:LogMaxBytes = $LogMaxBytes

    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
}

function Get-AppDir { return $script:AppBaseDir }
function Get-DataDir   { return $script:DataDir }
function Get-LogFile   { return $script:LogFile }
function Get-StateFile { return $script:StateFile }

# ---------------------------------------------------------------------------
# 读取配置文件
# ---------------------------------------------------------------------------

function Find-ConfigFile {
    <#
    .概要
        按优先级定位配置文件：
          1. 命令行显式指定的路径
          2. 环境变量 CAMPUS_AUTOLOGIN_CONFIG
          3. 程序目录下 config\config.json
    #>
    param([string]$ExplicitPath)

    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $envPath = $env:CAMPUS_AUTOLOGIN_CONFIG
    if ($envPath -and (Test-Path -LiteralPath $envPath)) {
        return (Resolve-Path -LiteralPath $envPath).Path
    }
    $def = Join-Path $script:AppRoot 'config\config.json'
    if (Test-Path -LiteralPath $def) { return $def }
    return $null
}

function Read-JsonFile {
    <#
    .概要
        读取 UTF-8 编码的 JSON 文件并返回对象。
        这里手动处理编码，避免中文在部分系统上变成乱码。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    # 去掉可能存在的 BOM，否则 ConvertFrom-Json 会报错
    $text = $text.TrimStart([char]0xFEFF)
    return ($text | ConvertFrom-Json)
}

function Import-Config {
    <#
    .概要
        读取并校验配置文件。失败时抛出中文异常，由调用方打印给用户。
    .参数 AllowPlaceholder
        为 $true 时跳过「未填写」校验，用于自检等需要报告缺项的场景。
    #>
    param(
        [string]$ExplicitPath,
        [switch]$AllowPlaceholder
    )

    $path = Find-ConfigFile -ExplicitPath $ExplicitPath
    if (-not $path) {
        $example = Join-Path $script:AppRoot 'config\config.example.json'
        throw @"
找不到配置文件。

  请先创建自己的配置文件：
    1) 把  config\config.example.json  复制为  config\config.json
    2) 用记事本打开 config\config.json
    3) 填写 门户地址、学号、密码 三项

  示例文件位置：$example
  提示：直接双击运行「1-初始化配置.bat」可以自动完成复制。

"@
    }

    try {
        $cfg = Read-JsonFile -Path $path
    }
    catch {
        throw "配置文件格式错误：$path`n  原因：$($_.Exception.Message)`n  常见问题：少了逗号、多了逗号、用了中文引号（“”）而不是英文引号（`"）。"
    }

    $script:ConfigPath = $path

    if (-not $AllowPlaceholder) {
        $missing = Get-MissingRequired -Config $cfg
        if ($missing.Count -gt 0) {
            throw @"
配置文件还有必填项没有填写：$($missing -join '、')

  请打开配置文件：$path
  把这几个选项改成你自己的信息后重试。
  提示：直接双击运行「1-初始化配置.bat」可以用记事本打开它。

"@
        }
    }
    return $cfg
}

function Get-ConfigValue {
    <#
    .概要
        安全读取配置项，支持 "a.b.c" 形式的路径。取不到时返回默认值。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Path,
        $Default = $null
    )
    $cur = $Config
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$part]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur -or ($cur -is [string] -and $cur.Trim() -eq '')) { return $Default }
    return $cur
}

function Get-MissingRequired {
    <#
    .概要
        返回仍为占位符的必填项列表（中文提示用）。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $missing = @()
    $base = [string](Get-ConfigValue -Config $Config -Path 'portal.base_url' -Default '')
    if ($base -eq '' -or $base -match '示例门户地址' -or $base -notmatch '^https?://') {
        $missing += '门户地址 portal.base_url'
    }
    $user = [string](Get-ConfigValue -Config $Config -Path 'account.username' -Default '')
    if ($user -eq '' -or $user -match '这里填你的学号') {
        $missing += '学号 account.username'
    }
    $pwd = [string](Get-ConfigValue -Config $Config -Path 'account.password' -Default '')
    if ($pwd -eq '' -or $pwd -match '这里填你的密码') {
        $missing += '密码 account.password'
    }
    return $missing
}

# ---------------------------------------------------------------------------
# 运行状态（data\state.json）
# ---------------------------------------------------------------------------

function Get-RuntimeState {
    <#
    .概要
        读取运行状态（上次成功时间、重连次数等）。文件不存在时返回空哈希表。
    #>
    $file = Get-StateFile
    if (-not (Test-Path -LiteralPath $file)) { return @{} }
    try {
        $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        $obj = $text | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    catch { return @{} }
}

function Set-RuntimeState {
    <#
    .概要
        保存运行状态。写入失败不影响主流程。
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)
    try {
        $file = Get-StateFile
        if (-not $file) { return }
        $json = $State | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Log -Message "保存运行状态失败：$($_.Exception.Message)" -Level '警告'
    }
}
