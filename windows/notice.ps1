param([Parameter(Mandatory)][string]$messageKey, [string]$reason)

. "$PSScriptRoot\utils.ps1"

$noticeLock = New-Object System.Threading.Mutex($false, "Local\SunshineBroadcastNotice-$messageKey")
if (-not $noticeLock.WaitOne(0)) { exit }

$message = $messageConfig.$messageKey
if ($reason) { $message += "`n`n" + (Format-Text $messageConfig.disconnectedVia @{ reason = $reason }) }
Show-Message $message 'Warning' | Out-Null
