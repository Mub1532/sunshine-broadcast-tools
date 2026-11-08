param([string]$applyFrom)

. "$PSScriptRoot\utils.ps1"

function Write-Utf8File([string]$path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Update-SunshineConf([string]$audioSink, $options) {
  $wanted = [ordered]@{}
  if ($options.disableInput) { $wanted.keyboard = 'disabled'; $wanted.mouse = 'disabled'; $wanted.controller = 'disabled' }
  if ($options.vigemDriver) { $wanted.gamepad_driver = 'vigembus' }
  $confPath = Join-Path $sunshineConfigDir 'sunshine.conf'
  $keptLines = @()
  if (Test-Path $confPath) {
    Copy-Item $confPath "$confPath.bak" -Force
    foreach ($line in Get-Content $confPath) {
      if ($line -match '^\s*(audio_sink|virtual_sink)\s*=') { continue }
      if ($line -match '^\s*(\w+)\s*=' -and $wanted.Contains($Matches[1])) { continue }
      if ($line -match '^\s*global_prep_cmd\s*=\s*(.+)$') {
        $otherCommands = @(($Matches[1] | ConvertFrom-Json) | Where-Object { $_.do -notmatch '(stream|broadcast)\.ps1' })
        if ($otherCommands.Count) { $keptLines += 'global_prep_cmd = ' + (ConvertTo-Json -InputObject $otherCommands -Compress -Depth 3) }
        continue
      }
      $keptLines += $line
    }
  }
  $keptLines += "audio_sink = $audioSink"
  foreach ($setting in $wanted.GetEnumerator()) { $keptLines += "$($setting.Key) = $($setting.Value)" }
  Write-Utf8File $confPath (($keptLines -join "`r`n") + "`r`n")
}

function Update-SunshineApps([bool]$removeOthers) {
  $appsPath = Join-Path $sunshineConfigDir 'apps.json'
  $apps = [pscustomobject]@{ env = [pscustomobject]@{}; apps = @() }
  if (Test-Path $appsPath) {
    Copy-Item $appsPath "$appsPath.bak" -Force
    $apps = Get-Content $appsPath -Raw | ConvertFrom-Json
  }

  $broadcastApp = [pscustomobject][ordered]@{
    'name'       = $scriptConfig.appName
    'image-path' = Join-Path $repoDir 'images\desktop-broadcast.png'
    'prep-cmd'   = @([pscustomobject][ordered]@{
        do       = Get-HiddenCommand 'broadcast.ps1' 'start'
        undo     = Get-HiddenCommand 'broadcast.ps1' 'release'
        elevated = $false
      })
    'detached'   = @((Get-HiddenCommand 'broadcast.ps1' 'guard'), (Get-HiddenCommand 'webcam-overlay.ps1'))
  }
  $otherApps = @($apps.apps | Where-Object { -not $removeOthers -and $_.name -ne $scriptConfig.appName })
  $apps.apps = $otherApps + $broadcastApp
  Write-Utf8File $appsPath (ConvertTo-Json $apps -Depth 6)
}

function Install-SunshineService {
  if (Get-Service $serviceName -ErrorAction SilentlyContinue) { return }
  $installScript = Join-Path $env:ProgramFiles 'Sunshine\scripts\install-service.bat'
  if (Test-Path $installScript) { Start-Process cmd.exe "/c `"$installScript`"" -WindowStyle Hidden -Wait }
  if (-not (Get-Service $serviceName -ErrorAction SilentlyContinue)) { throw 'The Sunshine service is missing. Reinstall Sunshine as administrator.' }
}

function Add-FirewallRules {
  $sunshinePath = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'
  Get-NetFirewallRule -DisplayName 'Sunshine Broadcast' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName 'Sunshine Broadcast' -Direction Inbound -Program $sunshinePath -Action Allow -Profile Any | Out-Null
}

function Set-DefaultCredentials {
  $statePath = Join-Path $sunshineConfigDir 'sunshine_state.json'
  if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($state.username) { return }
  }
  & (Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe') --creds admin admin | Out-Null
}

function Grant-ServiceControl {
  $securityDescriptor = (sc.exe sdshow $serviceName | Where-Object { $_ }) -join ''
  $userAccess = '(A;;RPWPLC;;;IU)'
  if ($securityDescriptor -and -not $securityDescriptor.Contains($userAccess)) {
    sc.exe sdset $serviceName ($securityDescriptor -replace '^D:', "D:$userAccess") | Out-Null
  }
  sc.exe config $serviceName start= demand | Out-Null
}

$sunshineIconPath = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'

function Install-Launcher {
  $launcherPath = Join-Path $appDir 'Sunshine Broadcast Tools.exe'
  if ((Test-Path $launcherPath) -and (Get-AuthenticodeSignature $launcherPath).Status -eq 'Valid') { return $launcherPath }

  $buildDir = Join-Path $env:TEMP 'sunshine-broadcast-launcher'
  New-Item $buildDir -ItemType Directory -Force | Out-Null
  $sourcePath = Join-Path $buildDir 'launcher.cs'
  $manifestPath = Join-Path $buildDir 'launcher.manifest'
  Write-Utf8File $sourcePath @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("Sunshine Broadcast Tools")]
[assembly: AssemblyProduct("Sunshine Broadcast Tools")]
[assembly: AssemblyCompany("Mubashar Khan")]

static class Launcher {
  static void Main(string[] args) {
    if (args.Length == 0) return;
    string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, args[0]);
    string extra = string.Join(" ", args, 1, args.Length - 1);
    Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + extra) {
      UseShellExecute = false,
      CreateNoWindow = true
    });
  }
}
'@
  Write-Utf8File $manifestPath @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false" /></requestedPrivileges></security>
  </trustInfo>
</assembly>
'@
  $compiler = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  & $compiler /nologo /target:winexe "/out:$launcherPath" "/win32manifest:$manifestPath" "/win32icon:$sunshineIconPath" $sourcePath | Out-Null
  if ($LASTEXITCODE) { throw 'Could not build the launcher.' }

  foreach ($store in 'Root', 'TrustedPublisher') {
    Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object Subject -eq 'CN=Mubashar Khan' | Remove-Item
  }
  $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Mubashar Khan' -FriendlyName 'Mubashar Khan Sunshine Broadcast Tools Certificate' `
    -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(30)
  try {
    $publicPath = Join-Path $buildDir 'publisher.cer'
    Export-Certificate -Cert $certificate -FilePath $publicPath | Out-Null
    foreach ($store in 'Root', 'TrustedPublisher') { Import-Certificate -FilePath $publicPath -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null }
    $signature = Set-AuthenticodeSignature $launcherPath $certificate -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid') { throw "Could not sign the launcher: $($signature.StatusMessage)" }
  }
  finally {
    Remove-Item "Cert:\LocalMachine\My\$($certificate.Thumbprint)" -DeleteKey
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $launcherPath
}

function New-LauncherShortcut([string]$name, [string]$script, [string]$tip, [string]$icon) {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut((Join-Path (Join-Path $env:PUBLIC 'Desktop') "$name.lnk"))
  $shortcut.TargetPath = Install-Launcher
  $shortcut.Arguments = $script
  $shortcut.WorkingDirectory = $appDir
  $shortcut.Description = $tip
  $shortcut.IconLocation = $icon
  $shortcut.Save()
}

function New-DesktopShortcut([string]$name, [string]$script, [string]$tip, [string]$icon, [string]$folder = (Join-Path $env:PUBLIC 'Desktop'), [string]$arguments = '') {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut((Join-Path $folder "$name.lnk"))
  $shortcut.TargetPath = Join-Path $env:windir 'System32\conhost.exe'
  $shortcut.Arguments = (Get-HiddenCommand $script $arguments) -replace '^conhost\.exe ', ''
  $shortcut.Description = $tip
  $shortcut.IconLocation = $icon
  $shortcut.Save()
}

if ($applyFrom) {
  try {
    $request = Get-Content $applyFrom -Raw | ConvertFrom-Json
    $failures = @()
    $steps = [ordered]@{
      'Service'   = { Install-SunshineService; Grant-ServiceControl }
      'Firewall'  = { Add-FirewallRules }
      'Login'     = { if ($request.options.defaultLogin) { Set-DefaultCredentials } }
      'Config'    = { Update-SunshineConf $request.audioSink $request.options }
      'Apps'      = { Update-SunshineApps ([bool]$request.options.removeOtherApps) }
      'Shortcuts' = {
        New-LauncherShortcut $scriptConfig.startShortcut 'start-stream.ps1' $scriptConfig.startShortcutTip "$sunshineIconPath,0"
        $startupFolder = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
        New-DesktopShortcut 'Sunshine Broadcast Cleanup' 'broadcast.ps1' 'Restore audio if a stream was left running' "$env:windir\System32\shell32.dll,27" $startupFolder 'cleanup'
      }
    }
    foreach ($step in $steps.GetEnumerator()) {
      try { & $step.Value }
      catch { $failures += "$($step.Key): $($_.Exception.Message)" }
    }
    if ($failures) { throw ($failures -join "`n") }

    if ((Get-Service $serviceName).Status -eq 'Running') {
      Restart-Service $serviceName -Force
      exit 3
    }
    exit 0
  }
  catch {
    Set-Content "$applyFrom.err" $_.Exception.Message
    exit 1
  }
}

if (-not (Test-Path $svclPath)) {
  Show-Message (Format-Text $messageConfig.svclMissing @{ folder = $appDir }) 'Error' | Out-Null
  exit 1
}

$deviceCsv = Join-Path $env:TEMP 'sunshine-broadcast-devices.csv'
Start-Process $svclPath "/scomma `"$deviceCsv`" /Columns `"Name,Type,Direction,Device Name,Command-Line Friendly ID`"" -Wait -WindowStyle Hidden
$audioDevices = @(Import-Csv $deviceCsv -ErrorAction SilentlyContinue | Where-Object Type -eq 'Device')
Remove-Item $deviceCsv -ErrorAction SilentlyContinue
if (-not $audioDevices) {
  Show-Message $messageConfig.devicesUnreadable 'Error' | Out-Null
  exit 1
}

$physicalDevices = $audioDevices | Where-Object { $_.'Device Name' -notmatch 'VB-Audio' }
$speakers = @($physicalDevices | Where-Object Direction -eq 'Render')
$microphones = @($physicalDevices | Where-Object Direction -eq 'Capture')
$cameras = @(Get-PnpDevice -PresentOnly -Status OK -ErrorAction SilentlyContinue |
  Where-Object Class -in 'Camera', 'Image' | Select-Object -ExpandProperty FriendlyName)

$cable = $audioDevices | Where-Object { $_.Direction -eq 'Render' -and $_.Name -eq 'CABLE Input' -and $_.'Device Name' -match 'VB-Audio' } |
  Select-Object -First 1
$audioSink = if ($cable) { "$($cable.Name) ($($cable.'Device Name'))" } else { '' }

$savedConfig = if (Test-Path $deviceConfigPath) { Get-Content $deviceConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$setupPath = $PSCommandPath

function Get-SavedIndex($devices, [string]$savedId) {
  for ($index = 0; $index -lt $devices.Count; $index++) {
    if ($devices[$index].'Command-Line Friendly ID' -eq $savedId) { return $index }
  }
  0
}

$setupForm = New-Object System.Windows.Forms.Form -Property @{
  Text            = $scriptConfig.setupTitle
  StartPosition   = 'CenterScreen'
  FormBorderStyle = 'FixedDialog'
  MaximizeBox     = $false
  MinimizeBox     = $false
  Font            = New-Object System.Drawing.Font('Segoe UI', 10)
}
$script:nextTop = 16

function Add-Row($control, [int]$rowHeight, [int]$left = 20, [int]$width = 460) {
  $control.SetBounds($left, $script:nextTop, $width, $control.Height)
  $setupForm.Controls.Add($control)
  $script:nextTop += $rowHeight
  $control
}

function Add-Label([string]$caption) {
  Add-Row (New-Object System.Windows.Forms.Label -Property @{ Text = $caption; Height = 22 }) 24 | Out-Null
}

function Add-DropDown([string[]]$items, [int]$selectedIndex) {
  $dropDown = Add-Row (New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList' }) 40
  if ($items) {
    $dropDown.Items.AddRange([object[]]$items)
    $dropDown.SelectedIndex = [Math]::Min($selectedIndex, $items.Count - 1)
  }
  $dropDown
}

function Get-DeviceLabel($device) { "$($device.Name) ($($device.'Device Name'))" }

Add-Label $scriptConfig.speakersLabel
$speakerList = Add-DropDown ($speakers | ForEach-Object { Get-DeviceLabel $_ }) (Get-SavedIndex $speakers $savedConfig.speakers)
Add-Label $scriptConfig.microphoneLabel
$microphoneList = Add-DropDown ($microphones | ForEach-Object { Get-DeviceLabel $_ }) (Get-SavedIndex $microphones $savedConfig.microphone)
Add-Label $scriptConfig.cameraLabel
$cameraList = Add-DropDown $cameras ([Math]::Max(0, [Array]::IndexOf($cameras, [string]$savedConfig.camera)))

Add-Label $scriptConfig.audioSinkLabel
Add-Row (New-Object System.Windows.Forms.TextBox -Property @{ Text = $audioSink; ReadOnly = $true }) 0 20 370 | Out-Null
$copyButton = Add-Row (New-Object System.Windows.Forms.Button -Property @{ Text = $scriptConfig.copyButton }) 44 400 80
$copyButton.Enabled = [bool]$audioSink
$copyButton.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($audioSink) })

$optionBoxes = [ordered]@{}
foreach ($option in 'defaultLogin', 'removeOtherApps', 'disableInput', 'vigemDriver') {
  $checked = [bool]$savedConfig.options.$option
  $optionBoxes[$option] = Add-Row (New-Object System.Windows.Forms.CheckBox -Property @{ Text = $scriptConfig."$($option)Option"; Checked = $checked; AutoSize = $true }) 26
}
$script:nextTop += 10

$warnings = @()
if (-not $cable) { $warnings += $messageConfig.cableMissing }
if (-not (Test-Path $libmpvPath)) { $warnings += $messageConfig.mpvMissing }
if ($warnings) {
  Add-Row (New-Object System.Windows.Forms.Label -Property @{ Text = $warnings -join "`n"; ForeColor = 'Firebrick'; Height = 44 }) 50 | Out-Null
}

function Get-Options {
  $options = [ordered]@{}
  foreach ($box in $optionBoxes.GetEnumerator()) { $options[$box.Key] = $box.Value.Checked }
  $options
}

function Save-Config {
  if ($speakerList.SelectedIndex -lt 0 -or $microphoneList.SelectedIndex -lt 0) {
    Show-Message $messageConfig.selectDevices 'Warning' | Out-Null
    return $false
  }
  try {
    [ordered]@{
      speakers   = $speakers[$speakerList.SelectedIndex].'Command-Line Friendly ID'
      microphone = $microphones[$microphoneList.SelectedIndex].'Command-Line Friendly ID'
      camera     = [string]$cameraList.SelectedItem
      options    = Get-Options
    } | ConvertTo-Json | Set-Content $deviceConfigPath -Encoding UTF8
    $true
  }
  catch {
    Show-Message (Format-Text $messageConfig.saveFailed @{ error = $_.Exception.Message }) 'Error' | Out-Null
    $false
  }
}

function Invoke-Apply {
  if (-not (Save-Config)) { return }
  $requestPath = Join-Path $env:TEMP 'sunshine-broadcast-apply.json'
  $errorPath = "$requestPath.err"
  Remove-Item $errorPath -ErrorAction SilentlyContinue
  @{ audioSink = $audioSink; options = Get-Options } | ConvertTo-Json | Set-Content $requestPath

  try {
    $applyProcess = Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$setupPath`" -applyFrom `"$requestPath`"" `
      -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    switch ($applyProcess.ExitCode) {
      0 { Show-Message "$($messageConfig.applied)`n`n$($scriptConfig.messagesNote)" | Out-Null; $setupForm.Close() }
      3 { Show-Message "$($messageConfig.applied)`n`n$($messageConfig.restarted)`n`n$($scriptConfig.messagesNote)" | Out-Null; $setupForm.Close() }
      default {
        $details = if (Test-Path $errorPath) { Get-Content $errorPath -Raw } else { '' }
        Show-Message (Format-Text $messageConfig.applyFailed @{ error = $details }) 'Error' | Out-Null
      }
    }
  }
  catch {
    Show-Message $messageConfig.adminRequired 'Warning' | Out-Null
  }
  Remove-Item $requestPath, $errorPath -ErrorAction SilentlyContinue
}

$applyButton = Add-Row (New-Object System.Windows.Forms.Button -Property @{ Text = $scriptConfig.applyButton; Height = 34 }) 50 300 180
$applyButton.Add_Click({
  if ($audioSink) { Invoke-Apply }
  elseif (Save-Config) { Show-Message "$($messageConfig.saved)`n`n$($scriptConfig.messagesNote)" | Out-Null; $setupForm.Close() }
})

$formWidth = [Math]::Max(500, ($optionBoxes.Values | ForEach-Object { $_.Right } | Measure-Object -Maximum).Maximum + 20)
$setupForm.ClientSize = New-Object System.Drawing.Size($formWidth, $script:nextTop)
$setupForm.Add_Shown({
  Show-OnTop $setupForm
  $setupForm.TopMost = $false
})
[void]$setupForm.ShowDialog()
