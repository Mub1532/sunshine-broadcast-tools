# installs a specific commit of the tools, run elevated from start-stream.ps1 when an update is chosen
param(
  [Parameter(Mandatory)][string]$branch,
  [Parameter(Mandatory)][string]$commit
)

. "$PSScriptRoot\utils.ps1"
Set-Location $env:TEMP

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
