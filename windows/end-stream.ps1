. "$PSScriptRoot\utils.ps1"

if ((Show-Message $scriptConfig.endConfirm 'Question' 'YesNo') -ne 'Yes') { exit }

Stop-Stream
Show-Message $scriptConfig.ended | Out-Null
