$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$repoName = 'sunshine-broadcast-tools'
$branch = 'main'
$zipUrl = "https://github.com/Mub1532/$repoName/archive/refs/heads/$branch.zip"
$svclUrl = 'https://www.nirsoft.net/utils/svcl-x64.zip'
$cableUrl = 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip'
$mpvReleaseUrl = 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest'
$installDir = Join-Path $env:ProgramData $repoName
$windowsDir = Join-Path $installDir 'windows'
$keepFiles = 'windows\deviceConfig.json', 'windows\svcl.exe', 'windows\libmpv-2.dll'

$tempDir = Join-Path $env:TEMP "$repoName-install"
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $tempDir -ItemType Directory | Out-Null

function Get-Download([string]$url, [string]$name) {
  $path = Join-Path $tempDir $name
  Invoke-WebRequest $url -OutFile $path -UseBasicParsing
  $path
}

function Test-CableInstalled {
  [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*VB-Audio Virtual Cable*')
}

try {
  Write-Host "Downloading $repoName..."
  $repoZip = Get-Download $zipUrl 'repo.zip'
  Expand-Archive $repoZip $tempDir -Force

  $keptDir = Join-Path $tempDir 'kept'
  foreach ($file in $keepFiles) {
    $existing = Join-Path $installDir $file
    if (-not (Test-Path $existing)) { continue }
    $backup = Join-Path $keptDir $file
    New-Item (Split-Path $backup) -ItemType Directory -Force | Out-Null
    Copy-Item $existing $backup
  }

  Write-Host "Installing to $installDir..."
  Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item (Join-Path $tempDir "$repoName-$branch") $installDir -Recurse
  if (Test-Path $keptDir) { Copy-Item "$keptDir\*" $installDir -Recurse -Force }

  $svclPath = Join-Path $windowsDir 'svcl.exe'
  if (-not (Test-Path $svclPath)) {
    Write-Host 'Downloading svcl...'
    $svclDir = Join-Path $tempDir 'svcl'
    Expand-Archive (Get-Download $svclUrl 'svcl.zip') $svclDir -Force
    Copy-Item (Join-Path $svclDir 'svcl.exe') $svclPath
  }

  $libmpvPath = Join-Path $windowsDir 'libmpv-2.dll'
  if (-not (Test-Path $libmpvPath)) {
    Write-Host 'Downloading libmpv...'
    $release = Invoke-RestMethod $mpvReleaseUrl -UseBasicParsing
    $asset = $release.assets | Where-Object name -match '^mpv-dev-x86_64-\d{8}-git-.+\.7z$' | Select-Object -First 1
    if (-not $asset) { throw 'Could not find the latest libmpv download.' }
    $mpvDir = Join-Path $tempDir 'mpv'
    New-Item $mpvDir -ItemType Directory | Out-Null
    tar.exe -xf (Get-Download $asset.browser_download_url 'mpv.7z') -C $mpvDir
    if ($LASTEXITCODE) { throw 'Could not extract libmpv (needs Windows 11).' }
    Copy-Item (Get-ChildItem $mpvDir -Recurse -Filter 'libmpv-2.dll' | Select-Object -First 1).FullName $libmpvPath
  }

  Get-ChildItem $installDir -Recurse -File | Unblock-File

  if (-not (Test-CableInstalled)) {
    Write-Host 'Downloading VB-CABLE...'
    $cableDir = Join-Path $tempDir 'vbcable'
    Expand-Archive (Get-Download $cableUrl 'vbcable.zip') $cableDir -Force
    Start-Process (Join-Path $cableDir 'VBCABLE_Setup_x64.exe') -WorkingDirectory $cableDir -Wait
    if (Test-CableInstalled) {
      Write-Host 'VB-CABLE installed. Restart the computer, then run Setup from:' -ForegroundColor Yellow
      Write-Host "  $windowsDir\setup.ps1" -ForegroundColor Yellow
      return
    }
  }

  Write-Host 'Opening Setup...'
  Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$windowsDir\setup.ps1`""
}
catch {
  Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
