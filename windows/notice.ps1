param([Parameter(Mandatory)][string]$messageKey, [string]$reason)

. "$PSScriptRoot\utils.ps1"

$noticeLock = New-Object System.Threading.Mutex($false, "Local\SunshineBroadcastNotice-$messageKey")
if (-not $noticeLock.WaitOne(0)) { exit }

$deviceName = if (Test-Path $clientNamePath) { (Get-Content $clientNamePath -Raw -Encoding UTF8).Trim() }
if (-not $deviceName) { $deviceName = $messageConfig.unknownDevice }
$message = Format-Text $messageConfig.$messageKey @{ device = $deviceName }
$message = $message.Substring(0, 1).ToUpper() + $message.Substring(1)
if ($reason) { $message += "`n`n" + (Format-Text $messageConfig.disconnectedVia @{ reason = $reason }) }
Show-Message $message 'Warning' | Out-Null
