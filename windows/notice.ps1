param([Parameter(Mandatory)][string]$messageKey, [string]$reason, [string]$stoppingKey)

. "$PSScriptRoot\utils.ps1"
Enable-SharpText

$noticeLock = New-Object System.Threading.Mutex($false, "Local\SunshineBroadcastNotice-$messageKey")
if (-not $noticeLock.WaitOne(0)) { exit }

if ($stoppingKey) {
  $progressForm = Show-Progress $messageConfig.$stoppingKey
  $stopProcess = Start-Process conhost.exe ((Get-HiddenCommand 'end-stream.ps1' '-fromOverlay') -replace '^conhost\.exe ', '') -PassThru
  $deadline = (Get-Date).AddSeconds(60)
  while (-not $stopProcess.HasExited -and (Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
  }
  $progressForm.Close()
}

$deviceName = if (Test-Path $clientNamePath) { (Get-Content $clientNamePath -Raw -Encoding UTF8).Trim().ToUpper() }
if (-not $deviceName) { $deviceName = $messageConfig.unknownDevice }
$message = Format-Text $messageConfig.$messageKey @{ device = $deviceName }
$message = $message.Substring(0, 1).ToUpper() + $message.Substring(1)
if ($reason) { $message += "`n`n" + (Format-Text $messageConfig.disconnectedVia @{ reason = $reason }) }
Show-Message $message 'Warning' | Out-Null
