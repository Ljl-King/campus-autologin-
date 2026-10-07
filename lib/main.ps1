# =============================================================================
#  校园网自动登录程序（Windows 零依赖版）
# -----------------------------------------------------------------------------
#  完全不需要安装 Python / Node.js / Java 等任何运行环境，
#  只用 Windows 自带的组件实现：PowerShell、Windows Script Host、系统计划任务。
#
#  用法（一般通过同目录下的 .bat 文件调用，也可直接运行本脚本）：
#      powershell -ExecutionPolicy Bypass -File main.ps1                前台运行（调试）
#      powershell -ExecutionPolicy Bypass -File main.ps1 -Install       安装开机自启
#      powershell -ExecutionPolicy Bypass -File main.ps1 -Uninstall     卸载开机自启
#      powershell -ExecutionPolicy Bypass -File main.ps1 -Status        查看状态
#      powershell -ExecutionPolicy Bypass -File main.ps1 -Once          只登录一次
#      powershell -ExecutionPolicy Bypass -File main.ps1 -Diagnose      网络与门户诊断
#      powershell -ExecutionPolicy Bypass -File main.ps1 -SelfTest      本地自检
#      powershell -ExecutionPolicy Bypass -File main.ps1 -FetchCrypto   仅更新门户加密脚本
#      powershell -ExecutionPolicy Bypass -File main.ps1 -Logoff        注销下线（排查用）
#
#  最低系统要求：Windows 10 1709 或更高（PowerShell 5.1 + Windows Script Host）
#                推荐 Windows 10 1803+ / Windows 11
# =============================================================================

[CmdletBinding()]
param(
    [switch]$Install,        # 安装开机自启并后台启动
    [switch]$Uninstall,      # 卸载开机自启
    [switch]$Status,         # 查看状态
    [switch]$Once,           # 只尝试登录一次
    [switch]$LoginOnly,      # 只执行一次登录（供自动化测试使用，与 -Once 等价）
    [switch]$Diagnose,       # 诊断
    [switch]$SelfTest,       # 本地自检
    [switch]$FetchCrypto,    # 仅更新门户加密脚本
    [switch]$Logoff,         # 注销下线
    [switch]$Quiet,          # 静默模式：不输出到控制台
    [string]$ConfigPath      # 指定配置文件路径
)

# -----------------------------------------------------------------------------
# 基础设置
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 程序根目录（本脚本位于 lib\ 子目录中，因此根目录是它的上一级）
$hereDir = $PSScriptRoot
if (-not $hereDir) { $hereDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $hereDir) { $hereDir = (Get-Location).Path }

# 本脚本与各功能模块在同一目录
$ScriptDir = $hereDir

# 上一级即程序根目录；若上一级没有 lib 目录，说明脚本被单独复制到了别处
$parentDir = Split-Path -Parent $hereDir
if ($parentDir -and (Test-Path -LiteralPath (Join-Path $parentDir 'lib'))) {
    $AppRoot = $parentDir
}
else {
    $AppRoot = $hereDir
}

# 任务名与启动项名
$TaskName = 'CampusAutoLogin'
$AppName  = 'CampusAutoLogin'

# 静默模式下禁止一切控制台输出
$script:QuietMode = [bool]$Quiet

# -----------------------------------------------------------------------------
# 加载各功能模块
# -----------------------------------------------------------------------------
. (Join-Path $ScriptDir 'config.ps1')
. (Join-Path $ScriptDir 'logging.ps1')
. (Join-Path $ScriptDir 'protocol.ps1')
. (Join-Path $ScriptDir 'crypto.ps1')

# -----------------------------------------------------------------------------
# 输出辅助（静默模式下自动屏蔽）
# -----------------------------------------------------------------------------

function Write-Info {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $script:QuietMode) { Write-Host $Message -ForegroundColor $Color }
}

function Write-BannerSafe {
    param([string]$Title, [string]$Color = 'Cyan')
    if ($script:QuietMode) { return }
    Write-Banner -Title $Title -Color $Color
}

# -----------------------------------------------------------------------------
# 登录流程
# -----------------------------------------------------------------------------

function Invoke-LoginOnce {
    <#
    .概要
        执行一次完整登录：先查是否在线 → 提交登录 → 轮询确认 → 回执。
        返回 $true 表示认证成功。
    #>
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    # ---- 1. 先确认当前是否已经在线，避免重复认证 ----
    $stat = Get-PortalStat -Config $Config
    if (Test-PortalAuthenticated -Stat $stat) {
        Write-Log -Message "门户显示当前已在线（ret=$($stat.ret)），无需重复登录" -Level '成功' -NoConsole:$script:QuietMode
        return $true
    }

    # ---- 2. 加密口令 ----
    $plain = [string](Get-ConfigValue -Config $Config -Path 'account.password' -Default '')
    try {
        $encrypted = ConvertTo-EncryptedPass -PlainPassword $plain -Config $Config
    }
    catch {
        Write-Log -Message "口令加密失败：$($_.Exception.Message)" -Level '错误' -NoConsole:$script:QuietMode
        return $false
    }

    # ---- 3. 提交登录 ----
    $login = Invoke-PortalLogin -Config $Config -EncryptedPass $encrypted
    Write-Log -Message "提交登录 → 返回码=$($login.Ret) 消息=$($login.Msg)（$($login.Adapter)）" -NoConsole:$script:QuietMode

    if ($null -eq $login.Ret) {
        return $false
    }

    # 服务端要求 URL 携带 AC 参数
    if ([int]$login.Ret -eq $script:RET_ARG -and ([string]$login.Msg).ToUpper().StartsWith('ARG')) {
        Write-Log -Message "门户要求附加参数(ARG)。请把认证页地址栏里 wlanuserip 等参数填入配置项 portal.query。" -Level '错误' -NoConsole:$script:QuietMode
        return $false
    }

    # 账号密码错误
    if (Test-RetCodeIsBadCred -Ret $login.Ret) {
        Write-Log -Message "认证被拒绝：$($login.Msg)（请核对配置中的学号、密码、运营商）" -Level '错误' -NoConsole:$script:QuietMode
        $State['last_badcred'] = (Get-Date).ToString('s')
        Set-RuntimeState -State $State
        return $false
    }

    # ---- 4. 轮询状态接口确认结果（与门户前端行为一致）----
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 1500
        $stat2 = Get-PortalStat -Config $Config -Quiet
        if (Test-PortalAuthenticated -Stat $stat2) {
            Write-Log -Message "认证成功（状态返回码 $($stat2.ret)）" -Level '成功' -NoConsole:$script:QuietMode
            Send-PortalAck -Config $Config
            $State['last_success'] = (Get-Date).ToString('s')
            $State['last_error'] = ''
            $State.Remove('last_badcred')
            Set-RuntimeState -State $State
            return $true
        }
        $sret = $null
        $smsg = ''
        if ($stat2) {
            if ($stat2.PSObject.Properties['ret']) { $sret = $stat2.ret }
            if ($stat2.PSObject.Properties['msg']) { $smsg = [string]$stat2.msg }
        }
        Write-Log -Message "认证中……（状态返回码=$sret 消息=$smsg）" -NoConsole:$script:QuietMode
        if (Test-RetCodeIsBadCred -Ret $sret) {
            Write-Log -Message "认证失败：$smsg" -Level '错误' -NoConsole:$script:QuietMode
            $State['last_badcred'] = (Get-Date).ToString('s')
            $State['last_error'] = $smsg
            Set-RuntimeState -State $State
            return $false
        }
    }

    Write-Log -Message "认证超时：多次轮询仍未成功" -Level '警告' -NoConsole:$script:QuietMode
    $State['last_error'] = '状态轮询超时'
    Set-RuntimeState -State $State
    return $false
}

# -----------------------------------------------------------------------------
# 保活主循环
# -----------------------------------------------------------------------------

function Start-KeepAlive {
    <#
    .概要
        常驻保活：
          - 每隔 CHECK_INTERVAL 秒检测一次能否上网；
          - 通网则继续等待；
          - 连续 OFFLINE_TRIGGER 次不通即判定掉线并重新登录；
          - 在线时每隔 SESSION_CHECK 秒核对一次门户会话。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $interval  = [int](Get-ConfigValue -Config $Config -Path 'keepalive.check_interval' -Default 30)
    $retry     = [int](Get-ConfigValue -Config $Config -Path 'keepalive.retry_interval' -Default 10)
    $trigger   = [int](Get-ConfigValue -Config $Config -Path 'keepalive.offline_trigger' -Default 2)
    $sessionChk = [int](Get-ConfigValue -Config $Config -Path 'keepalive.session_check' -Default 300)

    $portal = [string](Get-ConfigValue -Config $Config -Path 'portal.base_url' -Default '')
    $user   = [string](Get-ConfigValue -Config $Config -Path 'account.username' -Default '')

    Write-Log -Message ('=' * 62)
    Write-Log -Message "校园网自动登录程序已启动"
    Write-Log -Message "门户=$portal  账号=$user  检测间隔=${interval}秒"
    Write-Log -Message ('=' * 62)

    $state = Get-RuntimeState

    # 启动时先判断一次
    if (Test-InternetAccess -Config $Config) {
        Write-Log -Message "启动检查：当前已能正常上网"
    }
    else {
        Write-Log -Message "启动检查：尚未联网，开始认证"
        [void](Invoke-LoginOnce -Config $Config -State $state)
    }

    $failStreak = 0
    $lastSessionCheck = Get-Date

    while ($true) {
        try {
            Start-Sleep -Seconds $interval

            if (Test-InternetAccess -Config $Config) {
                if ($failStreak -gt 0) { Write-Log -Message "网络已恢复正常" -Level '成功' }
                $failStreak = 0

                # 长时间在线时，额外核对门户会话，处理「能上网但认证已失效」的情况
                if ($sessionChk -gt 0) {
                    $elapsed = ((Get-Date) - $lastSessionCheck).TotalSeconds
                    if ($elapsed -gt $sessionChk) {
                        $lastSessionCheck = Get-Date
                        $stat = Get-PortalStat -Config $Config -Quiet
                        if (-not (Test-PortalAuthenticated -Stat $stat)) {
                            $retNow = if ($stat) { $stat.ret } else { '无响应' }
                            Write-Log -Message "能上网但门户会话异常（ret=$retNow），重新认证" -Level '警告'
                            [void](Invoke-LoginOnce -Config $Config -State $state)
                        }
                    }
                }
                continue
            }

            # ---- 检测不通 ----
            $failStreak++
            Write-Log -Message "连通性检测失败（$failStreak/$trigger）" -Level '警告'

            if ($failStreak -ge $trigger) {
                Write-Log -Message "判定为掉线，开始重新认证" -Level '警告'
                $state['last_reconnect'] = (Get-Date).ToString('s')
                $state['reconnect_count'] = [int]($state['reconnect_count']) + 1
                Set-RuntimeState -State $state

                while ($true) {
                    if (Invoke-LoginOnce -Config $Config -State $state) {
                        $failStreak = 0
                        $lastSessionCheck = Get-Date
                        break
                    }
                    Write-Log -Message "重新登录失败，${retry}秒后重试" -Level '警告'
                    Start-Sleep -Seconds $retry
                }
            }
        }
        catch {
            Write-Log -Message "保活循环出现异常：$($_.Exception.Message)" -Level '错误'
            Start-Sleep -Seconds $retry
        }
    }
}

# -----------------------------------------------------------------------------
# 开机自启（计划任务）
# -----------------------------------------------------------------------------

function Get-PythonFreeCommand {
    <#
    .概要
        返回用于启动本程序的命令行（供计划任务使用）。
        使用 PowerShell 且带 -WindowStyle Hidden，实现后台静默。
    #>
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $main = Join-Path $ScriptDir 'main.ps1'
    return @{
        Command   = $psExe
        Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$main`" -Quiet"
    }
}

function Get-CurrentUserSid {
    <#
    .概要
        获取当前用户的 SID，用于计划任务的运行身份。
    #>
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return $id.User.Value
    }
    catch {
        return "$env:USERDOMAIN\$env:USERNAME"
    }
}

function New-TaskXml {
    <#
    .概要
        生成计划任务定义 XML。
        以「当前用户 + 交互式 + 最低权限」注册时，**不需要管理员权限**。
    .参数 Trigger
        logon = 用户登录时触发（默认，普通权限即可）
        start = 开机时触发（需要管理员权限）
    #>
    param(
        [ValidateSet('logon', 'start')][string]$Trigger = 'logon',
        [switch]$AsSystem
    )

    $cmdDef = Get-PythonFreeCommand
    $esc = { param($s) $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;') }

    if ($AsSystem) {
        $principal = @"
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
"@
    }
    else {
        $sid = Get-CurrentUserSid
        $principal = @"
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
"@
    }

    if ($Trigger -eq 'start') {
        $triggers = @"
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT10S</Delay>
    </BootTrigger>
"@
    }
    else {
        $sid = Get-CurrentUserSid
        $triggers = @"
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
"@
    }

    $command = & $esc $cmdDef.Command
    $args = & $esc $cmdDef.Arguments
    $workDir = & $esc $AppRoot

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>校园网自动登录保活程序</Description>
  </RegistrationInfo>
  <Triggers>
$triggers  </Triggers>
  <Principals>
$principal  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$args</Arguments>
      <WorkingDirectory>$workDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Invoke-Schtasks {
    <#
    .概要
        安全调用 schtasks.exe，只返回退出码。
        说明：schtasks 在任务不存在时会写标准错误，
              若直接 2>&1 会被 PowerShell 当成错误记录，并在
              $ErrorActionPreference='Stop' 下中断整个脚本。
              因此这里统一使用临时文件接收标准错误。
    .输出
        schtasks 的退出码（0 表示成功）
    #>
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $errFile = Join-Path (Get-DataDir) 'schtasks_err.txt'
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $proc = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\schtasks.exe') `
            -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path (Get-DataDir) 'schtasks_out.txt') `
            -RedirectStandardError $errFile
        return [int]$proc.ExitCode
    }
    catch {
        return 1
    }
    finally {
        $ErrorActionPreference = $oldPref
    }
}

function Install-ScheduledTask {
    <#
    .概要
        创建计划任务。依次尝试「登录触发（普通权限）」与「开机触发（需管理员）」。
    .输出
        具有 Ok / Message 的对象。
    #>
    # 先删除同名任务，避免重复注册（任务不存在时返回非零，属正常情况）
    $null = Invoke-Schtasks -Arguments @('/Delete', '/TN', $TaskName, '/F')

    $errors = @()
    $attempts = @(
        @{ Trigger = 'logon'; AsSystem = $false; Desc = '登录时触发（普通权限）' },
        @{ Trigger = 'start'; AsSystem = $true;  Desc = '开机时触发（需管理员）' }
    )

    foreach ($a in $attempts) {
        try {
            $xml = New-TaskXml -Trigger $a.Trigger -AsSystem:$a.AsSystem
            $xmlFile = Join-Path (Get-DataDir) 'task_definition.xml'
            [System.IO.File]::WriteAllText($xmlFile, $xml, [System.Text.Encoding]::Unicode)

            $code = Invoke-Schtasks -Arguments @('/Create', '/TN', $TaskName, '/XML', $xmlFile, '/F')
            if ($code -eq 0) {
                return [pscustomobject]@{ Ok = $true; Message = "已创建计划任务 $TaskName（$($a.Desc)，静默后台运行）" }
            }
            $errors += "$($a.Desc)：schtasks 返回码 $code"
        }
        catch {
            $errors += "$($a.Desc)：$($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Ok = $false; Message = "计划任务创建失败 → $($errors -join ' | ')" }
}

function Uninstall-ScheduledTask {
    <#
    .概要
        删除计划任务。
        说明：schtasks 在任务不存在时会向标准错误输出内容，
              这里必须显式重定向，否则会被当成脚本错误外泄给用户。
    #>
    $global:LASTEXITCODE = 0
    $null = Invoke-Schtasks -Arguments @('/Delete', '/TN', $TaskName, '/F')
    return ($global:LASTEXITCODE -eq 0)
}

function Test-ScheduledTaskExists {
    <#
    .概要
        判断计划任务是否存在。
    #>
    $code = Invoke-Schtasks -Arguments @('/Query', '/TN', $TaskName)
    return ($code -eq 0)
}

function Get-StartupFolder {
    <#
    .概要
        返回当前用户「启动」文件夹路径。
    #>
    return (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
}

function Install-StartupShortcut {
    <#
    .概要
        备选方案：在「启动」文件夹放置一个 VBS 启动器（隐藏窗口、免安装）。
        当计划任务被组策略或安全软件拦截时使用。
    #>
    $folder = Get-StartupFolder
    if (-not (Test-Path -LiteralPath $folder)) {
        return [pscustomobject]@{ Ok = $false; Message = "找不到启动文件夹：$folder" }
    }
    $target = Join-Path $folder "$AppName.vbs"
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $main = Join-Path $ScriptDir 'main.ps1'

    # 0 = 隐藏窗口；False = 不等待程序结束
    $vbs = @"
' 校园网自动登录 —— 开机启动器（由程序自动生成，隐藏窗口运行）
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "$AppRoot"
sh.Run """$psExe"" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$main"" -Quiet", 0, False
"@
    try {
        # VBS 用 ANSI 编码最稳，避免中文乱码
        [System.IO.File]::WriteAllText($target, $vbs, [System.Text.Encoding]::Default)
        return [pscustomobject]@{ Ok = $true; Message = "已在启动文件夹创建：$target" }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Message = "创建启动项失败：$($_.Exception.Message)" }
    }
}

function Uninstall-StartupShortcut {
    <#
    .概要
        删除启动文件夹中的启动器。
    #>
    $target = Join-Path (Get-StartupFolder) "$AppName.vbs"
    try {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force
            return $true
        }
    }
    catch { }
    return $false
}

function Start-BackgroundProcess {
    <#
    .概要
        以隐藏窗口方式在后台启动保活进程。
    #>
    try {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $main = Join-Path $ScriptDir 'main.ps1'
        $args = @(
            '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass', '-File', "`"$main`"", '-Quiet'
        )
        Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden | Out-Null
        Write-Log -Message "已在后台启动保活进程" -Level '成功'
        return $true
    }
    catch {
        Write-Log -Message "后台启动失败：$($_.Exception.Message)" -Level '错误'
        return $false
    }
}

function Install-AutoStart {
    <#
    .概要
        安装开机自启：优先计划任务，失败自动降级到启动文件夹。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    Write-BannerSafe -Title '校园网自动登录 —— 安装开机自启'

    $task = Install-ScheduledTask
    Write-Log -Message $task.Message -Level $(if ($task.Ok) { '成功' } else { '警告' })

    if (-not $task.Ok) {
        Write-Log -Message "计划任务方式不可用，改用备选方案：启动文件夹" -Level '警告'
        $sc = Install-StartupShortcut
        Write-Log -Message $sc.Message -Level $(if ($sc.Ok) { '成功' } else { '错误' })
        if (-not $sc.Ok) {
            Write-Log -Message "两种自启方式都失败。可手动把下面命令加入启动项：" -Level '错误'
            Write-Log -Message "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $ScriptDir 'main.ps1')`" -Quiet" -Level '错误'
            return $false
        }
    }
    else {
        # 计划任务成功时，再放一份启动项作为双保险（失败不影响）
        $sc = Install-StartupShortcut
        Write-Log -Message "双保险：$($sc.Message)" -Level $(if ($sc.Ok) { '信息' } else { '警告' })
    }

    Write-Info ''
    Write-Info '【安装结果】' 'Cyan'
    Write-Info '  开机自启已配置完成，程序已在后台运行。' 'Green'
    Write-Info '  查看状态：双击「状态.bat」'
    Write-Info '  取消自启：双击「卸载.bat」'
    Write-Info ''

    [void](Start-BackgroundProcess)
    return $true
}

function Uninstall-AutoStart {
    <#
    .概要
        卸载开机自启。
    #>
    Write-BannerSafe -Title '校园网自动登录 —— 卸载开机自启'
    $a = Uninstall-ScheduledTask
    $b = Uninstall-StartupShortcut
    Write-Log -Message "计划任务已删除：$a"
    Write-Log -Message "启动文件夹项已删除：$b"
    Write-Info ''
    Write-Info '  自启项已移除。' 'Green'
    Write-Info '  如果后台进程仍在运行，可在任务管理器中结束 powershell.exe，或直接重启电脑。'
    Write-Info ''
    return ($a -or $b)
}

# -----------------------------------------------------------------------------
# 状态与诊断
# -----------------------------------------------------------------------------

function Show-Status {
    <#
    .概要
        打印程序配置、自启状态与当前网络情况。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    Write-BannerSafe -Title '校园网自动登录 —— 运行状态'

    $user = [string](Get-ConfigValue -Config $Config -Path 'account.username' -Default '')
    $pwd = [string](Get-ConfigValue -Config $Config -Path 'account.password' -Default '')
    $mask = '*' * [Math]::Min($pwd.Length, 20)

    Write-Info ("  程序目录   ：{0}" -f $AppRoot)
    Write-Info ("  配置文件   ：{0}" -f $script:ConfigPath)
    Write-Info ("  门户地址   ：{0}" -f (Get-ConfigValue -Config $Config -Path 'portal.base_url' -Default ''))
    Write-Info ("  账号       ：{0}" -f $user)
    Write-Info ("  密码       ：{0}" -f $mask)
    Write-Info ("  运营商线路 ：{0}" -f $(if ((Get-ConfigValue -Config $Config -Path 'account.pool' -Default '') -eq '') { '(未设置)' } else { (Get-ConfigValue -Config $Config -Path 'account.pool') }))
    Write-Info ('  ' + ('-' * 60))

    $taskExists = Test-ScheduledTaskExists
    Write-Info ("  计划任务   ：{0}" -f $(if ($taskExists) { '已安装' } else { '未安装' })) $(if ($taskExists) { 'Green' } else { 'Gray' })
    $vbs = Join-Path (Get-StartupFolder) "$AppName.vbs"
    Write-Info ("  启动文件夹 ：{0}" -f $(if (Test-Path -LiteralPath $vbs) { '已安装' } else { '未安装' }))
    Write-Info ("  加密脚本   ：{0}" -f $(if (Test-Path -LiteralPath (Get-CryptoJsPath)) { '已缓存' } else { '未缓存（首次运行需连校园网下载）' }))

    $state = Get-RuntimeState
    Write-Info ('  ' + ('-' * 60))
    Write-Info ("  最近成功   ：{0}" -f $(if ($state['last_success']) { $state['last_success'] } else { '无记录' }))
    Write-Info ("  最近重连   ：{0}" -f $(if ($state['last_reconnect']) { $state['last_reconnect'] } else { '无记录' }))
    Write-Info ("  累计重连   ：{0} 次" -f $(if ($state['reconnect_count']) { $state['reconnect_count'] } else { 0 }))
    if ($state['last_error']) { Write-Info ("  最近错误   ：{0}" -f $state['last_error']) 'Yellow' }
    if ($state['last_badcred']) { Write-Info ("  口令被拒   ：{0}" -f $state['last_badcred']) 'Red' }

    Write-Info ('  ' + ('-' * 60))
    $netOk = Test-InternetAccess -Config $Config
    $portalOk = Test-PortalReachable -Config $Config
    Write-Info ("  当前能否上网：{0}" -f $(if ($netOk) { '是' } else { '否' })) $(if ($netOk) { 'Green' } else { 'Yellow' })
    Write-Info ("  门户是否可达：{0}" -f $(if ($portalOk) { '是' } else { '否' })) $(if ($portalOk) { 'Green' } else { 'Red' })
    Write-Info ('=' * 66)
    return $true
}

function Show-Diagnose {
    <#
    .概要
        诊断系统环境、网络与门户接口，并给出排查建议。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    Write-BannerSafe -Title '校园网自动登录 —— 诊断'

    Write-Info ''
    Write-Info '【1】系统环境' 'Cyan'
    Write-Info ("  PowerShell 版本：{0}" -f $PSVersionTable.PSVersion.ToString())
    Write-Info ("  系统版本       ：{0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)
    Write-Info ("  Windows Script Host：{0}" -f $(if (Test-WshAvailable) { '可用（零依赖加密可正常工作）' } else { '缺失' }))
    Write-Info ("  系统自带 curl  ：{0}" -f $(if (Test-Path (Join-Path $env:WINDIR 'System32\curl.exe')) { '可用' } else { '缺失' }))
    Write-Info ("  是否管理员     ：{0}" -f $(if ((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { '是' } else { '否（普通权限即可）' }))

    Write-Info ''
    Write-Info '【2】网络连通性' 'Cyan'
    Write-Info ("  能正常上网     ：{0}" -f $(if (Test-InternetAccess -Config $Config) { '是' } else { '否' }))
    Write-Info ("  门户 HTTP 可达 ：{0}" -f $(if (Test-PortalReachable -Config $Config) { '是' } else { '否' }))

    Write-Info ''
    Write-Info '【3】门户接口探测' 'Cyan'
    foreach ($key in @('home', 'crypto', 'login', 'stat')) {
        $url = Get-PortalUrl -Config $Config -Key $key
        $timeout = [int](Get-ConfigValue -Config $Config -Path 'keepalive.connect_timeout' -Default 8)
        $r = Invoke-WebRequestInternal -Url $url -TimeoutSec $timeout
        if ($r.StatusCode -eq 0) {
            Write-Info ("  {0,-8} → 失败：{1}" -f $key, $r.Error) 'Red'
        }
        else {
            Write-Info ("  {0,-8} → HTTP {1}（{2} 字节）" -f $key, $r.StatusCode, $r.Content.Length) 'Green'
        }
    }

    Write-Info ''
    Write-Info '【4】门户状态' 'Cyan'
    $stat = Get-PortalStat -Config $Config -Quiet
    if ($stat) { Write-Info ("  {0}" -f ($stat | ConvertTo-Json -Compress)) }
    else { Write-Info '  无响应' 'Red' }

    Write-Info ''
    Write-Info '【5】结论与建议' 'Cyan'
    if (-not (Test-PortalReachable -Config $Config)) {
        Write-Info '  ! 门户不可达。请确认已连上校园网，且当前 IP 属于该门户服务的网段。' 'Yellow'
        Write-Info '    可用 ipconfig 查看本机 IP。' 'Yellow'
    }
    elseif ($stat -and $stat.ret -eq $script:RET_ARG) {
        Write-Info '  ! 门户要求附加参数(ARG)。请用浏览器打开认证页，' 'Yellow'
        Write-Info '    把地址栏 ? 后面的 wlanuserip / wlanacname 等参数填入 portal.query。' 'Yellow'
    }
    elseif (Test-PortalAuthenticated -Stat $stat) {
        Write-Info '  当前已在线，无需登录。' 'Green'
    }
    else {
        Write-Info '  门户可达，可运行「状态.bat 登录」尝试一次登录。' 'Green'
    }
    Write-Info ('=' * 66)
    return $true
}

function Start-SelfTest {
    <#
    .概要
        本地自检：检查系统组件、配置完整性、加密脚本缓存情况。
        不向门户发送登录请求。
    #>
    param([Parameter(Mandatory = $true)]$Config)

    Write-BannerSafe -Title '校园网自动登录 —— 本地自检'
    $failCount = 0

    function Check-Item {
        param([string]$Label, [bool]$Ok, [string]$Detail = '')
        Write-Step -Label $Label -Ok $Ok -Detail $Detail
        if (-not $Ok) { $script:__fail++ }
    }
    $script:__fail = 0

    Write-Info ''
    Write-Info '【系统组件】' 'Cyan'
    Check-Item -Label 'PowerShell 版本 >= 5.1' -Ok ($PSVersionTable.PSVersion.Major -ge 5) -Detail $PSVersionTable.PSVersion.ToString()
    Check-Item -Label 'Windows Script Host 可用' -Ok (Test-WshAvailable) -Detail $script:CscriptExe
    Check-Item -Label '加密引擎文件存在' -Ok (Test-Path -LiteralPath (Get-EncodeEnginePath))

    Write-Info ''
    Write-Info '【配置完整性】' 'Cyan'
    $missing = Get-MissingRequired -Config $Config
    Check-Item -Label '门户地址已填写' -Ok (-not ($missing -match 'portal.base_url'))
    Check-Item -Label '学号已填写' -Ok (-not ($missing -match 'account.username'))
    Check-Item -Label '密码已填写' -Ok (-not ($missing -match 'account.password'))

    Write-Info ''
    Write-Info '【加密准备】' 'Cyan'
    $hasCrypto = Test-Path -LiteralPath (Get-CryptoJsPath)
    Check-Item -Label '门户加密脚本已缓存' -Ok $hasCrypto -Detail $(if ($hasCrypto) { 'data\portal_crypto.js' } else { '未缓存，需在校园网下运行一次' })
    if ($hasCrypto) {
        $key = Get-CryptoKey -Config $Config
        Check-Item -Label '已解析出加密密钥' -Ok ([bool]$key) -Detail $(if ($key) { "长度 $($key.Length)" } else { '解析失败，可在 crypto.key 手动填写' })
        if ($key) {
            try {
                $hex = ConvertTo-EncryptedPass -PlainPassword 'selftest_password' -Config $Config
                Check-Item -Label '加密引擎可正常输出密文' -Ok ($hex -match '^[0-9a-f]+$') -Detail "长度 $($hex.Length)"
            }
            catch {
                Check-Item -Label '加密引擎可正常输出密文' -Ok $false -Detail $_.Exception.Message
            }
        }
    }

    Write-Info ''
    Write-Info ('-' * 66)
    if ($script:__fail -eq 0) {
        Write-Info '  自检通过，可以运行「状态.bat 登录」尝试真实登录。' 'Green'
    }
    else {
        Write-Info "  有 $($script:__fail) 项未通过，请按上面的提示解决。" 'Yellow'
    }
    Write-Info ('=' * 66)
    return ($script:__fail -eq 0)
}

# =============================================================================
#  主流程
# =============================================================================

function Invoke-Main {
    # ---- 初始化路径 ----
    Initialize-Paths -Root $AppRoot

    # ---- 加载配置 ----
    $cfg = $null
    try {
        # 自检需要能报告「哪些项未填」，因此跳过必填校验
        $cfg = Import-Config -ExplicitPath $ConfigPath -AllowPlaceholder:$SelfTest
    }
    catch {
        if (-not $script:QuietMode) {
            Write-Host ''
            Write-Host $_.Exception.Message -ForegroundColor Red
            Write-Host ''
        }
        return 2
    }

    # 日志大小上限
    $script:LogMaxBytes = [int](Get-ConfigValue -Config $cfg -Path 'runtime.log_max_bytes' -Default 1048576)

    switch ($true) {
        $SelfTest    { return $(if (Start-SelfTest -Config $cfg) { 0 } else { 1 }) }
        $Diagnose    { [void](Show-Diagnose -Config $cfg); return 0 }
        $Status      { [void](Show-Status -Config $cfg); return 0 }
        $FetchCrypto {
            if (Save-CryptoJs -Config $cfg -Force) { return 0 } else { return 1 }
        }
        $Logoff {
            Write-Log -Message "注销结果：$(Invoke-PortalLogoff -Config $cfg)"
            return 0
        }
        $Uninstall   { [void](Uninstall-AutoStart); return 0 }
        $Install     { return $(if (Install-AutoStart -Config $cfg) { 0 } else { 1 }) }
        $Once {
            $state = Get-RuntimeState
            return $(if (Invoke-LoginOnce -Config $cfg -State $state) { 0 } else { 1 })
        }
        $LoginOnly {
            $state = Get-RuntimeState
            return $(if (Invoke-LoginOnce -Config $cfg -State $state) { 0 } else { 1 })
        }
        default {
            Start-KeepAlive -Config $cfg
            return 0
        }
    }
}

# 兼容直接双击 .ps1 与通过 -File 调用
$exitCode = Invoke-Main
exit $exitCode
