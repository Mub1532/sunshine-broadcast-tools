# casting has no camera box, so the stream is ended from the system tray icon
. "$PSScriptRoot\utils.ps1"

$buttonLock = New-Object System.Threading.Mutex($false, 'Local\SunshineBroadcastEndButton')
if (-not $buttonLock.WaitOne(0)) { exit }

$closeSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $overlayCloseName)
$trayContext = New-Object System.Windows.Forms.ApplicationContext

$requestEnd = {
  if ((Show-Message $messageConfig.endConfirm 'Question' 'YesNo') -eq 'Yes') {
    # tell the recorder to stop the instant End is confirmed, so its "saving..." popup shows right away
    $recordStop = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting($recordStopName, [ref]$recordStop)) { [void]$recordStop.Set() }
    Start-Hidden 'end-stream.ps1' '-fromOverlay'
    $trayContext.ExitThread()
  }
}
$trayIcon = New-EndTrayIcon $requestEnd

$watchTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 300 }
$watchTimer.Add_Tick({ if ($closeSignal.WaitOne(0)) { $trayContext.ExitThread() } })
$watchTimer.Start()

[System.Windows.Forms.Application]::Run($trayContext)
$trayIcon.Dispose()
[Environment]::Exit(0)
