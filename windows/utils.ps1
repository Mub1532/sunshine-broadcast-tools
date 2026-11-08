Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$appDir = $PSScriptRoot
$svclPath = Join-Path $appDir 'svcl.exe'
$libmpvPath = Join-Path $appDir 'libmpv-2.dll'
$deviceConfigPath = Join-Path $appDir 'deviceConfig.json'

$repoDir = Split-Path $appDir -Parent
$scriptConfig = Get-Content (Join-Path $repoDir 'scriptConfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$messagesPath = Join-Path $repoDir 'messageConfig.json'
$defaultMessagesPath = Join-Path $repoDir 'messageConfig.default.json'
if (-not (Test-Path $messagesPath) -and (Test-Path $defaultMessagesPath)) {
  try { Copy-Item $defaultMessagesPath $messagesPath } catch {}
}
$messageConfig = Get-Content $(if (Test-Path $messagesPath) { $messagesPath } else { $defaultMessagesPath }) -Raw -Encoding UTF8 | ConvertFrom-Json

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
$launcherPath = Join-Path $appDir 'Sunshine Broadcast Tools.exe'
$launcherVersion = '2.0.1.0'
$runnerPath = Join-Path $appDir 'run-hidden.exe'
$runnerVersion = '2.0.0.0'

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

  $textSize = [System.Windows.Forms.TextRenderer]::MeasureText($message, $form.Font, (New-Object System.Drawing.Size([int](440 * $scale), 0)), 'WordBreak')
  $label = New-Object System.Windows.Forms.Label -Property @{ Text = $message; TextAlign = 'MiddleCenter' }
  $form.Controls.Add($label)

  $buttons = @()
  for ($index = 0; $index -lt $choices.Count; $index++) {
    $button = New-Object System.Windows.Forms.Button -Property @{ Text = $choices[$index]; Tag = $index; AutoSize = $true; MinimumSize = New-Object System.Drawing.Size([int](100 * $scale), [int](32 * $scale)); Padding = New-Object System.Windows.Forms.Padding($gap, 0, $gap, 0) }
    $button.Add_Click({ $this.FindForm().Tag = $this.Tag; $this.FindForm().Close() })
    $form.Controls.Add($button)
    $buttons += $button
  }
  # buttons wrap onto new rows like flex-wrap, all the same width, and a shorter last row is centred
  $widestButton = ($buttons | ForEach-Object { $_.Width } | Measure-Object -Maximum).Maximum
  $buttonHeight = $buttons[0].Height
  $maxRowWidth = [Math]::Max([int](640 * $scale), $widestButton)
  $columns = [Math]::Max(1, [Math]::Min($buttons.Count, [Math]::Floor(($maxRowWidth + $gap) / ($widestButton + $gap))))
  $rows = [Math]::Ceiling($buttons.Count / $columns)
  $contentWidth = [Math]::Max($textSize.Width, $widestButton * $columns + $gap * ($columns - 1))
  $buttonWidth = [int](($contentWidth - $gap * ($columns - 1)) / $columns)
  $label.SetBounds($pad, $pad, $contentWidth, $textSize.Height + [int](4 * $scale))
  $buttonTop = $label.Bottom + [int](20 * $scale)
  for ($index = 0; $index -lt $buttons.Count; $index++) {
    $row = [Math]::Floor($index / $columns)
    $inRow = [Math]::Min($columns, $buttons.Count - $row * $columns)
    $rowLeft = $pad + [int](($contentWidth - ($buttonWidth * $inRow + $gap * ($inRow - 1))) / 2)
    $buttons[$index].AutoSize = $false
    $buttons[$index].Size = New-Object System.Drawing.Size($buttonWidth, $buttonHeight)
    $buttons[$index].Location = New-Object System.Drawing.Point(($rowLeft + ($index % $columns) * ($buttonWidth + $gap)), ($buttonTop + $row * ($buttonHeight + $gap)))
  }
  $form.ClientSize = New-Object System.Drawing.Size(($contentWidth + $pad * 2), ($buttonTop + $rows * $buttonHeight + ($rows - 1) * $gap + $pad))
  $form.AcceptButton = $buttons[0]
  $form.Tag = -1
  $form.Add_Shown({ Show-OnTop $this })
  [void]$form.ShowDialog()
  [int]$form.Tag
}

function New-RecordIcon {
  $bitmap = New-Object System.Drawing.Bitmap 32, 32
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = 'AntiAlias'
  $graphics.FillEllipse([System.Drawing.Brushes]::White, 3, 3, 26, 26)
  $graphics.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 40, 40))), 6, 6, 20, 20)
  $graphics.Dispose()
  [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

function New-EndTrayIcon([scriptblock]$onEnd) {
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $menu.Items.Add($scriptConfig.endButton).Add_Click($onEnd) | Out-Null
  $tray = New-Object System.Windows.Forms.NotifyIcon -Property @{
    Text             = $scriptConfig.title
    Icon             = New-RecordIcon
    ContextMenuStrip = $menu
    Visible          = $true
  }
  $tray.Add_MouseUp({
    param($sender, $click)
    if ($click.Button -eq 'Left') { $sender.GetType().GetMethod('ShowContextMenu', [Reflection.BindingFlags]'Instance, NonPublic').Invoke($sender, $null) }
  })
  $tray
}

function Test-LauncherReady {
  (Test-Path $launcherPath) -and (Get-Item $launcherPath).VersionInfo.FileVersion -eq $launcherVersion -and (Get-AuthenticodeSignature $launcherPath).Status -eq 'Valid'
}

function Start-TrayIcon {
  if (Test-LauncherReady) {
    $trayArgs = @('--tray', $scriptConfig.endButton, $messageConfig.endConfirm, $scriptConfig.title) | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    Start-Process $launcherPath ($trayArgs -join ' ')
  }
  else { Start-Hidden 'end-button.ps1' }
}

function Test-UserServiceAccess {
  $securityDescriptor = (sc.exe sdshow $serviceName) -join ''
  foreach ($ace in [regex]::Matches($securityDescriptor, '\(A;;([A-Z]+);;;IU\)')) {
    $rights = $ace.Groups[1].Value
    if ($rights.Contains('RP') -and $rights.Contains('WP') -and $rights.Contains('LC')) { return $true }
  }
  $false
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

# runs run-hidden the same way sunshine does and checks our script actually ran
function Test-Runner {
  $markerPath = Join-Path $env:TEMP 'sunshine-broadcast-selftest.txt'
  Remove-Item $markerPath -ErrorAction SilentlyContinue
  try {
    $testProcess = Start-Process $runnerPath 'broadcast.ps1 selftest' -PassThru
    if (-not $testProcess.WaitForExit(30000)) { Stop-Process -Id $testProcess.Id -Force -ErrorAction SilentlyContinue }
  }
  catch { return $false }
  Test-Path $markerPath
}

# start command for sunshine. uses run-hidden when it works on this laptop, otherwise the old hidden powershell way
function Get-StartCommand([bool]$runnerWorks) {
  if ($runnerWorks) { "`"$runnerPath`" broadcast.ps1 start" } else { Get-HiddenCommand 'broadcast.ps1' 'start' }
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
