#  when u click start stream, it starts sunshine, checks the name of it, so it can tell you the name to select in moonlight etc, starts the mic routing and show the ready message.

. "$PSScriptRoot\utils.ps1"

if (-not (Get-Service $serviceName -ErrorAction SilentlyContinue)) {
  Show-Message $scriptConfig.sunshineMissing 'Error' | Out-Null
  exit 1
}

function Test-SunshineReady {
  $ports = Get-NetTCPConnection -State Listen -LocalPort 47989, 47990 -ErrorAction SilentlyContinue |
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
    [System.Windows.Forms.Application]::DoEvents()
    if (& $condition) { return $true }
    Start-Sleep -Milliseconds 500
  } until ((Get-Date) -gt $deadline)
  $false
}

$hostName = $env:COMPUTERNAME
$sunshineConf = Join-Path $sunshineConfigDir 'sunshine.conf'
if (Test-Path $sunshineConf) {
  $nameLine = Select-String -Path $sunshineConf -Pattern '^\s*sunshine_name\s*=\s*(\S.*)$' | Select-Object -First 1
  if ($nameLine) { $hostName = $nameLine.Matches[0].Groups[1].Value.Trim() }
}
$readyMessage = Format-Text $scriptConfig.ready @{ host = $hostName; app = $scriptConfig.appName }

$progressForm = New-Object System.Windows.Forms.Form -Property @{
  Text            = $scriptConfig.title
  ClientSize      = New-Object System.Drawing.Size(340, 90)
  StartPosition   = 'CenterScreen'
  FormBorderStyle = 'FixedDialog'
  ControlBox      = $false
  TopMost         = $true
}
$progressForm.Controls.Add((New-Object System.Windows.Forms.Label -Property @{
  Text      = $scriptConfig.starting
  Dock      = 'Fill'
  TextAlign = 'MiddleCenter'
  Font      = New-Object System.Drawing.Font('Segoe UI', 11)
}))
$progressForm.Show()
$progressForm.Refresh()

& (Join-Path $appDir 'broadcast.ps1') start
Start-Hidden 'webcam-overlay.ps1'

if (-not (Test-SunshineReady)) {
  Start-Process sc.exe "start $serviceName" -WindowStyle Hidden -Wait
  if (-not (Wait-Until { Test-SunshineReady } 60)) {
    & (Join-Path $appDir 'broadcast.ps1') stop
    $progressForm.Close()
    Show-Message $scriptConfig.startFailed 'Error' | Out-Null
    exit 1
  }
}

Start-Hidden 'broadcast.ps1' 'guard -session'
Wait-Until { Test-OverlayReady } 20 | Out-Null

$progressForm.Close()
Show-Message $readyMessage | Out-Null
