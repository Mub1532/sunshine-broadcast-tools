$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$repoName = 'sunshine-broadcast-tools'
$branch = 'main'
$zipUrl = "https://github.com/Mub1532/$repoName/archive/refs/heads/$branch.zip"
$svclUrl = 'https://www.nirsoft.net/utils/svcl-x64.zip'
$installDir = Join-Path $env:ProgramData $repoName
$keepFiles = 'windows\deviceConfig.json', 'windows\svcl.exe'

$tempDir = Join-Path $env:TEMP "$repoName-install"
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $tempDir -ItemType Directory | Out-Null

try {
  Write-Host "Downloading $repoName..."
  $repoZip = Join-Path $tempDir 'repo.zip'
  Invoke-WebRequest $zipUrl -OutFile $repoZip -UseBasicParsing
  Expand-Archive $repoZip $tempDir -Force
  $sourceDir = Join-Path $tempDir "$repoName-$branch"

  $keptDir = Join-Path $tempDir 'kept'
  foreach ($file in $keepFiles) {
    $existing = Join-Path $installDir $file
    if (Test-Path $existing) {
      $backup = Join-Path $keptDir $file
      New-Item (Split-Path $backup) -ItemType Directory -Force | Out-Null
      Copy-Item $existing $backup
    }
  }

  Write-Host "Installing to $installDir..."
  Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item $sourceDir $installDir -Recurse
  if (Test-Path $keptDir) { Copy-Item "$keptDir\*" $installDir -Recurse -Force }

  $svclPath = Join-Path $installDir 'windows\svcl.exe'
  if (-not (Test-Path $svclPath)) {
    Write-Host 'Downloading svcl...'
    $svclZip = Join-Path $tempDir 'svcl.zip'
    Invoke-WebRequest $svclUrl -OutFile $svclZip -UseBasicParsing
    Expand-Archive $svclZip (Join-Path $tempDir 'svcl') -Force
    Copy-Item (Join-Path $tempDir 'svcl\svcl.exe') $svclPath
  }

  Get-ChildItem $installDir -Recurse -File | Unblock-File

  Write-Host 'Opening Setup...'
  Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$installDir\windows\setup.ps1`""
}
catch {
  Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}