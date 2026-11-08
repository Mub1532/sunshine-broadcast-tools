Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$appDir = $PSScriptRoot
$svclPath = Join-Path $appDir 'svcl.exe'
$libmpvPath = Join-Path $appDir 'libmpv-2.dll'
$deviceConfigPath = Join-Path $appDir 'deviceConfig.json'

$repoDir = Split-Path $appDir -Parent
$scriptConfig = Get-Content (Join-Path $repoDir 'scriptConfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$messageConfig = Get-Content (Join-Path $repoDir 'messageConfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$serviceName = 'SunshineService'
$sunshineConfigDir = Join-Path $env:ProgramFiles 'Sunshine\config'
$cableId = 'VB-Audio Virtual Cable\Device\CABLE Input\Render'
$stopEventName = 'Local\SunshineBroadcastStop'
$sessionLockName = 'Local\SunshineBroadcastSession'
$overlayReadyName = 'Local\SunshineBroadcastOverlayReady'
$overlayCloseName = 'Local\SunshineBroadcastOverlayClose'
$startingName = 'Local\SunshineBroadcastStarting'
$streamActivePath = Join-Path $env:LOCALAPPDATA 'sunshine-broadcast-tools\stream-active'
$clientNamePath = Join-Path $env:LOCALAPPDATA 'sunshine-broadcast-tools\client-name'
$versionPath = Join-Path $repoDir 'version.json'

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

function Enable-SharpText {
  Import-CSharp 'SharpText' 'public static class SharpText { [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
  [SharpText]::SetProcessDPIAware() | Out-Null
}

function Get-Scale {
  $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  try { $graphics.DpiX / 96 } finally { $graphics.Dispose() }
}

function New-ScaledForm {
  New-Object System.Windows.Forms.Form -Property @{
    Text            = $scriptConfig.title
    StartPosition   = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox     = $false
    MinimizeBox     = $false
    TopMost         = $true
    Font            = New-Object System.Drawing.Font('Segoe UI', 10)
  }
}

function Show-Progress([string]$text) {
  $scale = Get-Scale
  $form = New-ScaledForm
  $form.ControlBox = $false
  $form.ClientSize = New-Object System.Drawing.Size([int](340 * $scale), [int](90 * $scale))
  $form.Controls.Add((New-Object System.Windows.Forms.Label -Property @{ Dock = 'Fill'; TextAlign = 'MiddleLeft'; Font = New-Object System.Drawing.Font('Segoe UI', 11) }))
  $dotTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 400 }
  $dotTimer.Add_Tick({
    $label = $form.Controls[0]
    $label.Tag.dots = $label.Tag.dots % 3 + 1
    $label.Text = $label.Tag.text + ('.' * $label.Tag.dots)
  }.GetNewClosure())
  $form.Add_FormClosed({ $dotTimer.Dispose() }.GetNewClosure())
  Set-ProgressText $form $text
  $dotTimer.Start()
  $form.Show()
  Show-OnTop $form
  $form.Refresh()
  $form
}

function Set-ProgressText([System.Windows.Forms.Form]$form, [string]$text) {
  $label = $form.Controls[0]
  $label.Tag = @{ text = $text.TrimEnd('.'); dots = 3 }
  $fullWidth = [System.Windows.Forms.TextRenderer]::MeasureText($label.Tag.text + '...', $label.Font).Width
  $neededWidth = $fullWidth + [int](60 * (Get-Scale))
  if ($form.ClientSize.Width -lt $neededWidth) {
    $form.ClientSize = New-Object System.Drawing.Size($neededWidth, $form.ClientSize.Height)
    $screen = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.Location = New-Object System.Drawing.Point([int]($screen.Left + ($screen.Width - $form.Width) / 2), [int]($screen.Top + ($screen.Height - $form.Height) / 2))
  }
  $label.Padding = New-Object System.Windows.Forms.Padding([Math]::Max(0, [int](($label.ClientSize.Width - $fullWidth) / 2)), 0, 0, 0)
  $label.Text = $label.Tag.text + '...'
  $form.Refresh()
}

function Show-Choice([string]$message, [string[]]$choices) {
  $scale = Get-Scale
  $pad = [int](20 * $scale)
  $gap = [int](8 * $scale)
  $form = New-ScaledForm
  $form.ShowInTaskbar = $true

  $label = New-Object System.Windows.Forms.Label -Property @{ Text = $message; AutoSize = $true; MaximumSize = New-Object System.Drawing.Size([int](440 * $scale), 0) }
  $form.Controls.Add($label)
  $label.Location = New-Object System.Drawing.Point($pad, $pad)

  $buttons = @()
  for ($index = 0; $index -lt $choices.Count; $index++) {
    $button = New-Object System.Windows.Forms.Button -Property @{ Text = $choices[$index]; Tag = $index; AutoSize = $true; MinimumSize = New-Object System.Drawing.Size([int](100 * $scale), [int](32 * $scale)); Padding = New-Object System.Windows.Forms.Padding($gap, 0, $gap, 0) }
    $button.Add_Click({ $this.FindForm().Tag = $this.Tag; $this.FindForm().Close() })
    $form.Controls.Add($button)
    $buttons += $button
  }
  $rowWidth = ($buttons | ForEach-Object { $_.Width } | Measure-Object -Sum).Sum + $gap * ($buttons.Count - 1)
  $contentWidth = [Math]::Max($label.Width, $rowWidth)
  $buttonTop = $label.Bottom + [int](20 * $scale)
  $left = $pad + $contentWidth - $rowWidth
  foreach ($button in $buttons) {
    $button.Location = New-Object System.Drawing.Point($left, $buttonTop)
    $left += $button.Width + $gap
  }
  $form.ClientSize = New-Object System.Drawing.Size(($contentWidth + $pad * 2), ($buttonTop + $buttons[0].Height + $pad))
  $form.AcceptButton = $buttons[0]
  $form.Tag = -1
  $form.Add_Shown({ Show-OnTop $this })
  [void]$form.ShowDialog()
  [int]$form.Tag
}

function Get-InstalledVersion {
  if (Test-Path $versionPath) { return Get-Content $versionPath -Raw | ConvertFrom-Json }
  [pscustomobject]@{ branch = 'main'; commit = '' }
}

function Get-LatestCommit([string]$branch) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try { return (Invoke-RestMethod "https://api.github.com/repos/Mub1532/sunshine-broadcast-tools/commits/$branch" -TimeoutSec 3 -UseBasicParsing).sha }
  catch {}
  try {
    $feed = Invoke-WebRequest "https://github.com/Mub1532/sunshine-broadcast-tools/commits/$branch.atom" -TimeoutSec 3 -UseBasicParsing
    if ($feed.Content -match 'Commit/([0-9a-f]{40})') { return $Matches[1] }
  }
  catch {}
  ''
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
  & (Join-Path $appDir 'broadcast.ps1') stop
  Start-Process sc.exe "stop $serviceName" -WindowStyle Hidden -Wait
}
