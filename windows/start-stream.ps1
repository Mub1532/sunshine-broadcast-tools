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
$readyMessage = Format-Text $messageConfig.ready @{ host = $hostName; app = $scriptConfig.appName }

$startingSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $startingName)
$progressForm = Show-Progress $messageConfig.checkingUpdates
if (-not $skipUpdateCheck) {
  $installed = Get-InstalledVersion
  $latestCommit = Get-LatestCommit $installed.branch
  if ($latestCommit -and $latestCommit -ne $installed.commit) {
    $progressForm.Hide()
    $choice = Show-Choice $messageConfig.updateAvailable @($messageConfig.updateNow, $messageConfig.updateLater, $messageConfig.updateSkip)
    $progressForm.Show()
    Show-OnTop $progressForm
    $updateArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $appDir 'update.ps1')`" -branch $($installed.branch) -commit $latestCommit"
    if ($choice -eq 0) {
      Set-ProgressText $progressForm $messageConfig.updating
      try {
        $updateProcess = Start-Process powershell $updateArgs -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:TEMP -Wait -PassThru
        if ($updateProcess.ExitCode -eq 0) {
          $progressForm.Close()
          Start-Hidden 'start-stream.ps1' '-skipUpdateCheck'
          exit
        }
        Show-Message $messageConfig.updateFailed 'Warning' | Out-Null
      }
      catch {}
    }
    elseif ($choice -eq 1) {
      try { Start-Process powershell "$updateArgs -afterStream" -Verb RunAs -WindowStyle Hidden -WorkingDirectory $env:TEMP }
      catch {}
    }
  }
}
Set-ProgressText $progressForm $messageConfig.starting

& (Join-Path $appDir 'broadcast.ps1') start
Start-Hidden 'webcam-overlay.ps1'

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
Wait-Until { Test-OverlayReady } 20 | Out-Null

$progressForm.Close()
$startingSignal.Dispose()
Show-Message $readyMessage | Out-Null