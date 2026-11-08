$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'This must be run in PowerShell as administrator. Right-click PowerShell, choose "Run as administrator", then run the command again.' -ForegroundColor Red
  return
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$closeWindow = $false
$repoName = 'sunshine-broadcast-tools'
$branch = 'main'
$silent = [bool]$sbtSilent
$commit = [string]$sbtCommit
$installDir = Join-Path $env:ProgramData $repoName
$windowsDir = Join-Path $installDir 'windows'
$keepFiles = 'messageConfig.json', 'windows\deviceConfig.json', 'windows\svcl.exe', 'windows\libmpv-2.dll', 'windows\Sunshine Broadcast Tools.exe', 'windows\run-hidden.exe', 'broadcast-config-backup', 'casting-config-backup'

$tempDir = Join-Path $env:TEMP "$repoName-install"
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $tempDir -ItemType Directory | Out-Null

function Get-Download([string]$url, [string]$name) {
  $path = Join-Path $tempDir $name
  Invoke-WebRequest $url -OutFile $path -UseBasicParsing
  $path
}

function Get-LatestCommit {
  try { return (Invoke-RestMethod "https://api.github.com/repos/Mub1532/$repoName/commits/$branch" -TimeoutSec 5 -UseBasicParsing).sha }
  catch {}
  try {
    $feed = Invoke-WebRequest "https://github.com/Mub1532/$repoName/commits/$branch.atom" -TimeoutSec 5 -UseBasicParsing
    if ($feed.Content -match 'Commit/([0-9a-f]{40})') { return $Matches[1] }
  }
  catch {}
  ''
}

try {
  Write-Host "Downloading $repoName..."
  if (-not $commit) { $commit = Get-LatestCommit }
  $zipName = if ($commit) { $commit } else { "refs/heads/$branch" }
  $repoZip = Get-Download "https://github.com/Mub1532/$repoName/archive/$zipName.zip" 'repo.zip'
  Expand-Archive $repoZip $tempDir -Force
  $sourceDir = (Get-ChildItem $tempDir -Directory -Filter "$repoName-*" | Select-Object -First 1).FullName

  $installedVersionPath = Join-Path $installDir 'version.json'
  $installedCommit = if (Test-Path $installedVersionPath) { (Get-Content $installedVersionPath -Raw | ConvertFrom-Json).commit } else { '' }
  if ((Test-Path $installDir) -and (-not $commit -or $installedCommit -ne $commit)) {
    Write-Host 'Saving the current version so it can be undone...'
    $backupDir = Join-Path $env:ProgramData "$repoName-backup"
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

    Copy-Item (Join-Path $sourceDir 'windows\restore.ps1') $backupDir
    $undoShortcut = $shell.CreateShortcut((Join-Path $backupDir 'Undo Sunshine Broadcast Tools update.lnk'))
    $undoShortcut.TargetPath = Join-Path $env:windir 'System32\conhost.exe'
    $undoShortcut.Arguments = "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $backupDir 'restore.ps1')`""
    $undoShortcut.Save()
  }

  $keptDir = Join-Path $tempDir 'kept'
  foreach ($file in $keepFiles) {
    $existing = Join-Path $installDir $file
    if (-not (Test-Path $existing)) { continue }
    $backup = Join-Path $keptDir $file
    New-Item (Split-Path $backup) -ItemType Directory -Force | Out-Null
    Copy-Item $existing $backup -Recurse
  }

  Write-Host "Installing to $installDir..."
  Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item $installDir -ItemType Directory -Force | Out-Null
  Copy-Item "$sourceDir\*" $installDir -Recurse -Force
  if (Test-Path $keptDir) { Copy-Item "$keptDir\*" $installDir -Recurse -Force }

  $messagesPath = Join-Path $installDir 'messageConfig.json'
  Copy-Item (Join-Path $sourceDir 'messageConfig.json') (Join-Path $installDir 'messageConfig.default.json') -Force
  $defaultMessages = Get-Content (Join-Path $sourceDir 'messageConfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $currentMessages = Get-Content $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $missingMessages = @($defaultMessages.PSObject.Properties | Where-Object { -not $currentMessages.PSObject.Properties[$_.Name] })
  if ($missingMessages) {
    $newLines = $missingMessages | ForEach-Object { "  `"$($_.Name)`": `"$($_.Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n'))`"" }
    $messagesText = (Get-Content $messagesPath -Raw -Encoding UTF8).TrimEnd().TrimEnd('}').TrimEnd()
    $messagesText = "$messagesText,`n`n$($newLines -join ",`n")`n}`n"
    [System.IO.File]::WriteAllText($messagesPath, $messagesText, (New-Object System.Text.UTF8Encoding($false)))
  }

  Get-ChildItem $installDir -Recurse -File | Unblock-File
  $setupShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $installDir 'Sunshine Broadcast Setup.lnk'))
  $setupShortcut.TargetPath = Join-Path $env:windir 'System32\conhost.exe'
  $setupShortcut.Arguments = "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$windowsDir\setup.ps1`""
  $setupShortcut.IconLocation = "$env:ProgramFiles\Sunshine\sunshine.exe,0"
  $setupShortcut.Save()
  if ($commit) {
    [ordered]@{ branch = $branch; commit = $commit } | ConvertTo-Json | Set-Content (Join-Path $installDir 'version.json') -Encoding UTF8
  }
  if ($silent) { return }

  if (-not (Test-Path (Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'))) {
    Write-Host 'Downloading Sunshine...'
    $windowsArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $sunshineArch = if ($windowsArch -eq 'ARM64') { 'ARM64' } else { 'AMD64' }
    $sunshineMsi = "Sunshine-Windows-$sunshineArch-installer.msi"
    $sunshineInstaller = Get-Download "https://github.com/LizardByte/Sunshine/releases/latest/download/$sunshineMsi" $sunshineMsi
    Write-Host 'Opening the Sunshine installer...'
    $sunshineSetup = Start-Process msiexec.exe "/i `"$sunshineInstaller`"" -Wait -PassThru
    if ($sunshineSetup.ExitCode -notin 0, 3010) { throw "Sunshine install failed (code $($sunshineSetup.ExitCode))." }
  }

  Write-Host 'Opening Setup...'
  $setupShown = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', 'Local\SunshineBroadcastSetupShown')
  Start-Process conhost.exe "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$windowsDir\setup.ps1`""
  $closeWindow = $setupShown.WaitOne(60000)
  $setupShown.Dispose()
}
catch {
  Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
  if ($silent) { exit 1 }
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($closeWindow) { [Environment]::Exit(0) }
