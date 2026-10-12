Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$appDir = $PSScriptRoot
$svclPath = Join-Path $appDir 'svcl.exe'
$libmpvPath = Join-Path $appDir 'libmpv-2.dll'
$deviceConfigPath = Join-Path $appDir 'deviceConfig.json'

$repoDir = Split-Path $appDir -Parent
$scriptConfig = Get-Content (Join-Path $repoDir 'scriptConfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$serviceName = 'SunshineService'
$sunshineConfigDir = Join-Path $env:ProgramFiles 'Sunshine\config'
$cableId = 'VB-Audio Virtual Cable\Device\CABLE Input\Render'
$stopEventName = 'Local\SunshineBroadcastStop'
$sessionLockName = 'Local\SunshineBroadcastSession'
$overlayReadyName = 'Local\SunshineBroadcastOverlayReady'
$overlayCloseName = 'Local\SunshineBroadcastOverlayClose'

function Format-Text([string]$template, [hashtable]$values) {
  foreach ($key in $values.Keys) { $template = $template.Replace("{$key}", [string]$values[$key]) }
  $template
}

function Show-Message([string]$message, [string]$icon = 'Information', [string]$buttons = 'OK') {
  [System.Windows.Forms.MessageBox]::Show($message, $scriptConfig.title, $buttons, $icon)
}

function Get-HiddenCommand([string]$script, [string]$arguments = '') {
  "conhost.exe --headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $appDir $script)`" $arguments".TrimEnd()
}

function Start-Hidden([string]$script, [string]$arguments = '') {
  Start-Process conhost.exe ((Get-HiddenCommand $script $arguments) -replace '^conhost\.exe ', '')
}

function Stop-Stream {
  Start-Process sc.exe "stop $serviceName" -WindowStyle Hidden -Wait
  & (Join-Path $appDir 'broadcast.ps1') stop
}
