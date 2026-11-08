#  when u click start stream, it starts sunshine, checks the name of it, so it can tell you the name to select in moonlight etc, starts the mic routing and show the ready message.

param([switch]$skipUpdateCheck)

. "$PSScriptRoot\utils.ps1"
Enable-SharpText

if (-not (Get-Service $serviceName -ErrorAction SilentlyContinue)) {
  Show-Message $messageConfig.sunshineMissing 'Error' | Out-Null
  exit 1
}

function Test-SunshineReady {
  $ports = Get-NetTCPConnection -State Listen -LocalPort $sunshinePort, ($sunshinePort + 1) -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty LocalPort | Sort-Object -Unique
  @($ports).Count -eq 2
}

function Test-OverlayReady {
  $overlayReady = $null
  [System.Threading.EventWaitHandle]::TryOpenExisting($overlayReadyName, [ref]$overlayReady)
}

function Wait-Until([scriptblock]$condition, [int]$timeoutSeconds) {
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  do {
    if (& $condition) { return $true }
    for ($tick = 0; $tick -lt 5; $tick++) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 100
    }
  } until ((Get-Date) -gt $deadline)
  $false
}

$hostName = $env:COMPUTERNAME
$sunshinePort = 47989
$sunshineConf = Join-Path $sunshineConfigDir 'sunshine.conf'
if (Test-Path $sunshineConf) {
  $nameLine = Select-String -Path $sunshineConf -Pattern '^\s*sunshine_name\s*=\s*(\S.*)$' | Select-Object -First 1
  if ($nameLine) { $hostName = $nameLine.Matches[0].Groups[1].Value.Trim() }
  $portLine = Select-String -Path $sunshineConf -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -Last 1
  if ($portLine) { $sunshinePort = [int]$portLine.Matches[0].Groups[1].Value }
}
$savedConfig = Get-Content $deviceConfigPath -Raw | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isCasting = $savedConfig.mode -eq 'casting'
$appName = if ($isCasting) { 'Desktop' } else { $scriptConfig.appName }
$readyMessage = Format-Text $messageConfig.ready @{ host = $hostName; app = $appName }

if ((Test-Path $launcherPath) -and -not (Test-LauncherReady)) {
  try { Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $appDir 'setup.ps1')`" -renewLauncher" -Verb RunAs -WindowStyle Hidden }
  catch {}
}

$startingSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $startingName)
$progressForm = Show-Progress $messageConfig.checkingUpdates
if (-not $skipUpdateCheck) {
  $installed = Get-InstalledVersion
  $latestCommit = Get-LatestCommit $installed.branch
  if ($latestCommit -and $latestCommit -ne $installed.commit) {
    $progressForm.Hide()
    $choice = Show-Choice $messageConfig.updateAvailable @($messageConfig.updateNow, $messageConfig.updateSkip)
    $progressForm.Show()
    Show-OnTop $progressForm
    $updateArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $appDir 'update.ps1')`" -branch $($installed.branch) -commit $latestCommit"
    if ($choice -eq 0) {
      Set-ProgressText $progressForm $messageConfig.updating
      try {
        $updateProcess = Start-Process powershell $updateArgs -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:TEMP -PassThru
        Wait-Until { $updateProcess.HasExited } 600 | Out-Null
        if ($updateProcess.ExitCode -eq 0) {
          $progressForm.Close()
          Start-Hidden 'start-stream.ps1' '-skipUpdateCheck'
          exit
        }
        Show-Message $messageConfig.updateFailed 'Warning' | Out-Null
      }
      catch {}
    }
  }
}
function Test-SetupNeedsRepair {
  if (-not (Get-NetFirewallRule -DisplayName 'Sunshine Broadcast' -ErrorAction SilentlyContinue)) { return $true }
  if ((Get-CimInstance Win32_Service -Filter "Name='$serviceName'").StartMode -ne 'Manual') { return $true }
  if (-not (Test-UserServiceAccess)) { return $true }
  if (-not (Test-Path $runnerPath) -or (Get-Item $runnerPath).VersionInfo.FileVersion -ne $runnerVersion) { return $true }
  $appsPath = Join-Path $sunshineConfigDir 'apps.json'
  $modeApp = if ($isCasting) { 'Desktop' } else { $scriptConfig.appName }
  if (-not (Test-Path $appsPath) -or -not ((Get-Content $appsPath -Raw | ConvertFrom-Json).apps | Where-Object { $_.name -eq $modeApp -and $_.'prep-cmd'[0].do -eq (Get-StartCommand (Test-Runner)) -and [bool]$_.'prep-cmd'[0].elevated -eq ($savedConfig.options.runAsAdmin -ne $false) })) { return $true }
  if (-not $isCasting -and -not (Select-String -Path (Join-Path $sunshineConfigDir 'sunshine.conf') -Pattern '^\s*audio_sink\s*=\s*\S' -Quiet)) { return $true }
  $false
}

if ((Test-Path $deviceConfigPath) -and (Test-SetupNeedsRepair)) {
  Set-ProgressText $progressForm $messageConfig.repairing
  $repairArgs = @{ FilePath = 'powershell'; ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $appDir 'setup.ps1')`" -repair"; WindowStyle = 'Hidden'; PassThru = $true }
  if (-not $isAdmin) { $repairArgs.Verb = 'RunAs' }
  try {
    $repairProcess = Start-Process @repairArgs
    Wait-Until { $repairProcess.HasExited } 120 | Out-Null
  }
  catch {}
}

Set-ProgressText $progressForm $messageConfig.starting

if (-not $isCasting) {
  $savedDevices = Get-Content $deviceConfigPath -Raw | ConvertFrom-Json
  if ($savedDevices.speakers) { & $svclPath /SetDefault $savedDevices.speakers all }
  if ($savedDevices.microphone) { & $svclPath /SetDefault $savedDevices.microphone all }
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '(end-button|webcam-overlay)\.ps1|broadcast\.ps1"? guard' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='Sunshine Broadcast Tools.exe'" -ErrorAction SilentlyContinue |
  Where-Object CommandLine -match '--tray' |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

& (Join-Path $appDir 'broadcast.ps1') start
if (-not $isCasting) { Start-Hidden 'webcam-overlay.ps1' }
# the launcher always asks for admin, so without admin use the plain tray button instead
if ($isAdmin) { Start-TrayIcon } else { Start-Hidden 'end-button.ps1' }

if (-not (Test-SunshineReady)) {
  Start-Process sc.exe "start $serviceName" -WindowStyle Hidden -Wait
  if (-not (Wait-Until { Test-SunshineReady } 60)) {
    & (Join-Path $appDir 'broadcast.ps1') stop
    $progressForm.Close()
    Show-Message $messageConfig.startFailed 'Error' | Out-Null
    exit 1
  }
}

Start-Hidden 'broadcast.ps1' 'guard -session'
if (-not $isCasting) { Wait-Until { Test-OverlayReady } 20 | Out-Null }

$progressForm.Close()
$startingSignal.Dispose()
Show-Message $readyMessage | Out-Null