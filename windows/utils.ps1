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

function Show-OnTop([System.Windows.Forms.Form]$form) {
  $form.TopMost = $true
  $form.Activate()
}

function Show-Message([string]$message, [string]$icon = 'Information', [string]$buttons = 'OK') {
  $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0; Size = '1,1'; StartPosition = 'CenterScreen' }
  $owner.Show()
  $owner.Activate()
  try { [System.Windows.Forms.MessageBox]::Show($owner, $message, $scriptConfig.title, $buttons, $icon) }
  finally { $owner.Dispose() }
}

function Get-HiddenCommand([string]$script, [string]$arguments = '') {
  "conhost.exe --headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $appDir $script)`" $arguments".TrimEnd()
}

function Start-Hidden([string]$script, [string]$arguments = '') {
  Start-Process conhost.exe ((Get-HiddenCommand $script $arguments) -replace '^conhost\.exe ', '')
}

function Import-CSharp([string]$name, [string]$source, [string[]]$references = @()) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
  $cacheDir = Join-Path $env:LOCALAPPDATA 'sunshine-broadcast-tools'
  $dllPath = Join-Path $cacheDir "$name-$hash.dll"
  if (-not (Test-Path $dllPath)) {
    New-Item $cacheDir -ItemType Directory -Force | Out-Null
    Get-ChildItem $cacheDir -Filter "$name-*.dll" -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    $compileOptions = @{ TypeDefinition = $source }
    if ($references) { $compileOptions.ReferencedAssemblies = $references }
    try { Add-Type @compileOptions -OutputAssembly $dllPath -OutputType Library }
    catch { Add-Type @compileOptions; return }
  }
  Add-Type -Path $dllPath
}

function Stop-Stream {
  Start-Process sc.exe "stop $serviceName" -WindowStyle Hidden -Wait
  & (Join-Path $appDir 'broadcast.ps1') stop
}
