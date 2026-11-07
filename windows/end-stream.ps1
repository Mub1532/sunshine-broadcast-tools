. "$PSScriptRoot\utils.ps1"

if ((Show-Message $messageConfig.endConfirm 'Question' 'YesNo') -ne 'Yes') { exit }

Stop-Stream
Show-Message $messageConfig.ended | Out-Null
