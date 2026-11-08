# installs a specific commit of the tools, run elevated from start-stream.ps1 when an update is chosen
param(
  [Parameter(Mandatory)][string]$branch,
  [Parameter(Mandatory)][string]$commit,
  [switch]$afterStream
)

. "$PSScriptRoot\utils.ps1"
Set-Location $env:TEMP

if ($afterStream) {
  $deadline = (Get-Date).AddMinutes(2)
  while ((Get-Service $serviceName).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
  while ((Get-Service $serviceName).Status -ne 'Stopped') { Start-Sleep -Seconds 15 }
  Start-Sleep -Seconds 5
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $installer = Invoke-RestMethod "https://raw.githubusercontent.com/Mub1532/sunshine-broadcast-tools/$commit/windows/install.ps1" -UseBasicParsing
  $installer = $installer.Replace("`$branch = 'main'", "`$branch = '$branch'")
  $sbtSilent = $true
  $sbtCommit = $commit
  & ([scriptblock]::Create($installer))
  exit 0
}
catch { exit 1 }
