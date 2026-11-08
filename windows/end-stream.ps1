param([switch]$fromOverlay)

. "$PSScriptRoot\utils.ps1"

if ($fromOverlay) {
  Stop-Stream
  exit
}

if ((Show-Message $messageConfig.endConfirm 'Question' 'YesNo') -ne 'Yes') { exit }

Stop-Stream
Show-Message $messageConfig.ended | Out-Null
