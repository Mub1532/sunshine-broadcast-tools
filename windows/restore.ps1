# puts back the version from before the last update (tools, sunshine config, shortcuts, service settings)
$backupDir = $PSScriptRoot

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process conhost.exe "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

Add-Type -AssemblyName System.Windows.Forms
$title = 'Sunshine Broadcast Tools'
function Show-OnTopMessage([string]$text, [string]$buttons, [string]$icon) {
  $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0; Size = '1,1'; StartPosition = 'CenterScreen' }
  $owner.Show()
  $owner.Activate()
  try { [System.Windows.Forms.MessageBox]::Show($owner, $text, $title, $buttons, $icon) }
  finally { $owner.Dispose() }
}
$answer = Show-OnTopMessage 'Undo the last update and go back to the previous version?' 'YesNo' 'Question'
if ($answer -ne 'Yes') { exit }

try {
  $installDir = Join-Path $env:ProgramData 'sunshine-broadcast-tools'
  $sunshineConfigDir = Join-Path $env:ProgramFiles 'Sunshine\config'

  $endStream = Join-Path $installDir 'windows\end-stream.ps1'
  if (Test-Path $endStream) {
    $ending = Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$endStream`" -fromOverlay" -WindowStyle Hidden -PassThru
    if (-not $ending.WaitForExit(30000)) { $ending.Kill() }
  }
  Stop-Service SunshineService -Force -ErrorAction SilentlyContinue
  Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force

  robocopy (Join-Path $backupDir 'tools') $installDir /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw 'Could not restore the tools folder.' }
  if (Test-Path (Join-Path $backupDir 'sunshine-config')) {
    robocopy (Join-Path $backupDir 'sunshine-config') $sunshineConfigDir /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw 'Could not restore the Sunshine settings.' }
  }

  $shortcutsPath = Join-Path $backupDir 'shortcuts.json'
  if (Test-Path $shortcutsPath) {
    foreach ($shortcut in (Get-Content $shortcutsPath -Raw | ConvertFrom-Json)) {
      Copy-Item (Join-Path $backupDir "shortcuts\$($shortcut.file)") $shortcut.path -Force
    }
  }

  $servicePath = Join-Path $backupDir 'service.json'
  if (Test-Path $servicePath) {
    $service = Get-Content $servicePath -Raw | ConvertFrom-Json
    sc.exe config SunshineService start= $service.start | Out-Null
    if ($service.security) { sc.exe sdset SunshineService $service.security | Out-Null }
  }

  Set-Location $env:TEMP
  Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
  Show-OnTopMessage 'The previous version has been restored.' 'OK' 'Information' | Out-Null
}
catch {
  Show-OnTopMessage "Undo failed: $($_.Exception.Message)" 'OK' 'Error' | Out-Null
}
