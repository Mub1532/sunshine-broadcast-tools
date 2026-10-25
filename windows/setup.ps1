param([string]$applyFrom)

. "$PSScriptRoot\utils.ps1"

function Write-Utf8File([string]$path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Update-SunshineConf([string]$audioSink) {
  $confPath = Join-Path $sunshineConfigDir 'sunshine.conf'
  $keptLines = @()
  if (Test-Path $confPath) {
    Copy-Item $confPath "$confPath.bak" -Force
    foreach ($line in Get-Content $confPath) {
      if ($line -match '^\s*(audio_sink|virtual_sink)\s*=') { continue }
      if ($line -match '^\s*global_prep_cmd\s*=\s*(.+)$') {
        $otherCommands = @(($Matches[1] | ConvertFrom-Json) | Where-Object { $_.do -notmatch '(stream|broadcast)\.ps1' })
        if ($otherCommands.Count) { $keptLines += 'global_prep_cmd = ' + (ConvertTo-Json -InputObject $otherCommands -Compress -Depth 3) }
        continue
      }
      $keptLines += $line
    }
  }
  $keptLines += "audio_sink = $audioSink"
  Write-Utf8File $confPath (($keptLines -join "`r`n") + "`r`n")
}

function Update-SunshineApps {
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
  $apps.apps = @($apps.apps | Where-Object { $_.name -ne $scriptConfig.appName }) + $broadcastApp
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

function Grant-ServiceControl {
  $securityDescriptor = (sc.exe sdshow $serviceName | Where-Object { $_ }) -join ''
  $userAccess = '(A;;RPWPLC;;;IU)'
  if ($securityDescriptor -and -not $securityDescriptor.Contains($userAccess)) {
    sc.exe sdset $serviceName ($securityDescriptor -replace '^D:', "D:$userAccess") | Out-Null
  }
  sc.exe config $serviceName start= demand | Out-Null
}

function New-DesktopShortcut([string]$name, [string]$script, [string]$tip, [string]$icon) {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut((Join-Path $env:PUBLIC "Desktop\$name.lnk"))
  $shortcut.TargetPath = Join-Path $env:windir 'System32\conhost.exe'
  $shortcut.Arguments = (Get-HiddenCommand $script) -replace '^conhost\.exe ', ''
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
      'Config'    = { Update-SunshineConf $request.audioSink }
      'Apps'      = { Update-SunshineApps }
      'Shortcuts' = {
        New-DesktopShortcut $scriptConfig.startShortcut 'start-stream.ps1' $scriptConfig.startShortcutTip "$env:ProgramFiles\Sunshine\sunshine.exe,0"
        New-DesktopShortcut $scriptConfig.endShortcut 'end-stream.ps1' $scriptConfig.endShortcutTip "$env:windir\System32\shell32.dll,27"
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
  Show-Message (Format-Text $scriptConfig.svclMissing @{ folder = $appDir }) 'Error' | Out-Null
  exit 1
}

$deviceCsv = Join-Path $env:TEMP 'sunshine-broadcast-devices.csv'
Start-Process $svclPath "/scomma `"$deviceCsv`" /Columns `"Name,Type,Direction,Device Name,Command-Line Friendly ID`"" -Wait -WindowStyle Hidden
$audioDevices = @(Import-Csv $deviceCsv -ErrorAction SilentlyContinue | Where-Object Type -eq 'Device')
Remove-Item $deviceCsv -ErrorAction SilentlyContinue
if (-not $audioDevices) {
  Show-Message $scriptConfig.devicesUnreadable 'Error' | Out-Null
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

$warnings = @()
if (-not $cable) { $warnings += $scriptConfig.cableMissing }
if (-not (Test-Path $libmpvPath)) { $warnings += $scriptConfig.mpvMissing }
if ($warnings) {
  Add-Row (New-Object System.Windows.Forms.Label -Property @{ Text = $warnings -join "`n"; ForeColor = 'Firebrick'; Height = 44 }) 50 | Out-Null
}

function Save-Config {
  if ($speakerList.SelectedIndex -lt 0 -or $microphoneList.SelectedIndex -lt 0) {
    Show-Message $scriptConfig.selectDevices 'Warning' | Out-Null
    return $false
  }
  try {
    [ordered]@{
      speakers   = $speakers[$speakerList.SelectedIndex].'Command-Line Friendly ID'
      microphone = $microphones[$microphoneList.SelectedIndex].'Command-Line Friendly ID'
      camera     = [string]$cameraList.SelectedItem
    } | ConvertTo-Json | Set-Content $deviceConfigPath -Encoding UTF8
    $true
  }
  catch {
    Show-Message (Format-Text $scriptConfig.saveFailed @{ error = $_.Exception.Message }) 'Error' | Out-Null
    $false
  }
}

function Invoke-Apply {
  if (-not (Save-Config)) { return }
  $requestPath = Join-Path $env:TEMP 'sunshine-broadcast-apply.json'
  $errorPath = "$requestPath.err"
  Remove-Item $errorPath -ErrorAction SilentlyContinue
  @{ audioSink = $audioSink } | ConvertTo-Json | Set-Content $requestPath

  try {
    $applyProcess = Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$setupPath`" -applyFrom `"$requestPath`"" `
      -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    switch ($applyProcess.ExitCode) {
      0 { Show-Message $scriptConfig.applied | Out-Null }
      3 { Show-Message "$($scriptConfig.applied)`n`n$($scriptConfig.restarted)" | Out-Null }
      default {
        $details = if (Test-Path $errorPath) { Get-Content $errorPath -Raw } else { '' }
        Show-Message (Format-Text $scriptConfig.applyFailed @{ error = $details }) 'Error' | Out-Null
      }
    }
  }
  catch {
    Show-Message $scriptConfig.adminRequired 'Warning' | Out-Null
  }
  Remove-Item $requestPath, $errorPath -ErrorAction SilentlyContinue
}

$saveButton = Add-Row (New-Object System.Windows.Forms.Button -Property @{ Text = $scriptConfig.saveButton; Height = 34 }) 0 20 120
$applyButton = Add-Row (New-Object System.Windows.Forms.Button -Property @{ Text = $scriptConfig.applyButton; Height = 34 }) 50 300 180
$applyButton.Enabled = [bool]$audioSink
$saveButton.Add_Click({ if (Save-Config) { Show-Message $scriptConfig.saved | Out-Null } })
$applyButton.Add_Click({ Invoke-Apply })

$setupForm.ClientSize = New-Object System.Drawing.Size(500, $script:nextTop)
$setupForm.Add_Shown({
  Show-OnTop $setupForm
  $setupForm.TopMost = $false
})
[void]$setupForm.ShowDialog()
