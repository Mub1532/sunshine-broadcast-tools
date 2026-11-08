# saves the current version (tools, sunshine config, shortcuts, service settings) into a folder that restore.ps1 can put back
param([Parameter(Mandatory)][string]$backupDir)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'sunshine-broadcast-tools'

Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item (Join-Path $backupDir 'shortcuts') -ItemType Directory -Force | Out-Null
Copy-Item $installDir (Join-Path $backupDir 'tools') -Recurse
$sunshineConfigDir = Join-Path $env:ProgramFiles 'Sunshine\config'
if (Test-Path $sunshineConfigDir) { Copy-Item $sunshineConfigDir (Join-Path $backupDir 'sunshine-config') -Recurse }

$shell = New-Object -ComObject WScript.Shell
$savedShortcuts = @()
foreach ($folder in (Join-Path $env:PUBLIC 'Desktop'), (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp')) {
  foreach ($link in Get-ChildItem $folder -Filter '*.lnk' -ErrorAction SilentlyContinue) {
    $target = $shell.CreateShortcut($link.FullName)
    if ("$($target.TargetPath) $($target.Arguments)" -notlike "*$installDir*") { continue }
    $file = "$($savedShortcuts.Count)-$($link.Name)"
    Copy-Item $link.FullName (Join-Path $backupDir "shortcuts\$file")
    $savedShortcuts += [pscustomobject]@{ file = $file; path = $link.FullName }
  }
}
ConvertTo-Json -InputObject @($savedShortcuts) | Set-Content (Join-Path $backupDir 'shortcuts.json') -Encoding UTF8

$serviceInfo = Get-CimInstance Win32_Service -Filter "Name='SunshineService'" -ErrorAction SilentlyContinue
if ($serviceInfo) {
  $startType = @{ Auto = 'auto'; Manual = 'demand'; Disabled = 'disabled' }[$serviceInfo.StartMode]
  $security = (sc.exe sdshow SunshineService | Where-Object { $_ }) -join ''
  [ordered]@{ start = $startType; security = $security } | ConvertTo-Json | Set-Content (Join-Path $backupDir 'service.json') -Encoding UTF8
}

Copy-Item (Join-Path $PSScriptRoot 'restore.ps1') $backupDir
$undoShortcut = $shell.CreateShortcut((Join-Path $backupDir 'Undo Sunshine Broadcast Tools update.lnk'))
$undoShortcut.TargetPath = Join-Path $env:windir 'System32\conhost.exe'
$undoShortcut.Arguments = "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $backupDir 'restore.ps1')`""
$undoShortcut.Save()
