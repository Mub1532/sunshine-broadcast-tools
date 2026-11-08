# puts back the version from before the last update (tools, sunshine config, shortcuts, service settings)
$backupDir = $PSScriptRoot

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Start-Process conhost.exe "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

Add-Type -AssemblyName System.Windows.Forms
$title = 'Sunshine Broadcast Tools'
$answer = [System.Windows.Forms.MessageBox]::Show('Undo the last update and go back to the previous version?', $title, 'YesNo', 'Question')
if ($answer -ne 'Yes') { exit }

try {
  $installDir = Join-Path $env:ProgramData 'sunshine-broadcast-tools'
  $sunshineConfigDir = Join-Path $env:ProgramFiles 'Sunshine\config'

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

  [System.Windows.Forms.MessageBox]::Show('The previous version has been restored.', $title, 'OK', 'Information') | Out-Null
}
catch {
  [System.Windows.Forms.MessageBox]::Show("Undo failed: $($_.Exception.Message)", $title, 'OK', 'Error') | Out-Null
}
