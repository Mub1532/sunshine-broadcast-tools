. "$PSScriptRoot\utils.ps1"

$noticeLock = New-Object System.Threading.Mutex($false, 'Local\SunshineBroadcastDisconnectNotice')
if (-not $noticeLock.WaitOne(0)) { exit }

Show-Message $messageConfig.disconnected 'Warning' | Out-Null
