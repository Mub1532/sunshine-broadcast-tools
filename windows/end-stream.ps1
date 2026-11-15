param([switch]$fromOverlay)

. "$PSScriptRoot\utils.ps1"

if ($fromOverlay) {
  Stop-Stream
  exit
}

if ((Show-Message $messageConfig.endConfirm 'Question' 'YesNo') -ne 'Yes') { exit }

# tell the recorder to stop the instant End is confirmed, so its "saving..." popup shows right away
$recordStop = $null
if ([System.Threading.EventWaitHandle]::TryOpenExisting($recordStopName, [ref]$recordStop)) { [void]$recordStop.Set() }
Stop-Stream
Show-Message $messageConfig.ended | Out-Null
