param([Parameter(Mandatory)][string]$messageKey)

. "$PSScriptRoot\utils.ps1"

$noticeLock = New-Object System.Threading.Mutex($false, "Local\SunshineBroadcastNotice-$messageKey")
if (-not $noticeLock.WaitOne(0)) { exit }

Show-Message $messageConfig.$messageKey 'Warning' | Out-Null
