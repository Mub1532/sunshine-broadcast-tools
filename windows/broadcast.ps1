param(
  [Parameter(Mandatory)][ValidateSet('start', 'stop', 'release', 'guard', 'cleanup')][string]$action,
  [switch]$session
)

. "$PSScriptRoot\utils.ps1"
$deviceConfig = Get-Content $deviceConfigPath -Raw | ConvertFrom-Json


# makes the selected speaker back to actual laptop one, and make the Mic on 100 so it can be heard.
function Restore-Speakers {
  & $svclPath /SetDefault $deviceConfig.speakers all
  & $svclPath /Unmute $cableId
  & $svclPath /SetVolume $cableId 100
}

function Read-NewLogLines {
  if (-not (Test-Path $sunshineLogPath)) { return @() }
  $logLength = (Get-Item $sunshineLogPath).Length
  if ($logLength -lt $script:logPosition) { $script:logPosition = 0 }
  if ($logLength -eq $script:logPosition) { return @() }
  $logStream = [System.IO.File]::Open($sunshineLogPath, 'Open', 'Read', 'ReadWrite')
  try {
    [void]$logStream.Seek($script:logPosition, 'Begin')
    $newText = (New-Object System.IO.StreamReader($logStream)).ReadToEnd()
  }
  finally { $logStream.Dispose() }
  $script:logPosition = $logLength
  $newText -split "`r?`n"
}

# stop broadcast by, stoppin the camera feed in corner etc
function Stop-Broadcast {
  Remove-Item $streamActivePath -ErrorAction SilentlyContinue
  & $svclPath /SetListenToThisDevice $deviceConfig.microphone 0
  $overlayClose = $null
  if ([System.Threading.EventWaitHandle]::TryOpenExisting($overlayCloseName, [ref]$overlayClose)) { [void]$overlayClose.Set() }
  $stopSignal = $null
  if ([System.Threading.EventWaitHandle]::TryOpenExisting($stopEventName, [ref]$stopSignal)) { [void]$stopSignal.Set() }
  Restore-Speakers
}

# the actions that happens when someone connect to the sunshine client, eg start for when they connect, stop when they disconnect, and guard is for when sunshine auto sets the default speaker to the cable etc, this makes the normal speaker the set one
switch ($action) {
  'start' {
    New-Item $streamActivePath -ItemType File -Force | Out-Null
    Set-Content $clientNamePath ([string]$env:SUNSHINE_CLIENT_NAME) -Encoding UTF8
    & $svclPath /SetPlaybackThroughDevice $deviceConfig.microphone $cableId
    & $svclPath /SetListenToThisDevice $deviceConfig.microphone 1
  }
  'stop' { Stop-Broadcast }
  'cleanup' { if (Test-Path $streamActivePath) { Stop-Broadcast } }
  'release' {
    $sessionLock = $null
    if ([System.Threading.Mutex]::TryOpenExisting($sessionLockName, [ref]$sessionLock)) { Restore-Speakers }
    else { Stop-Broadcast }
  }
  'guard' {
    $isNew = $false
    $stopSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $stopEventName, [ref]$isNew)
    if (-not $isNew) { exit }
    if ($session) { $sessionLock = New-Object System.Threading.Mutex($true, $sessionLockName) }

    Import-CSharp 'audio-guard' @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumerator { }

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints();
  [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate();
  [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
}

[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
  int GetCount();
  int GetAt();
  [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
}

[StructLayout(LayoutKind.Sequential)]
public struct PropertyKey { public Guid formatId; public int propertyId; }

[StructLayout(LayoutKind.Explicit)]
public struct PropVariant { [FieldOffset(0)] public short type; [FieldOffset(8)] public IntPtr pointer; }

public static class DefaultOutput {
  public static string GetName() {
    try {
      var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
      IMMDevice device;
      if (enumerator.GetDefaultAudioEndpoint(0, 1, out device) != 0) return "";
      IPropertyStore store;
      device.OpenPropertyStore(0, out store);
      var friendlyName = new PropertyKey { formatId = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), propertyId = 14 };
      PropVariant value;
      store.GetValue(ref friendlyName, out value);
      return value.type == 31 ? Marshal.PtrToStringUni(value.pointer) : "";
    } catch { return ""; }
  }
}
'@

    $sunshineLogPath = Join-Path $sunshineConfigDir 'sunshine.log'
    $script:logPosition = if (Test-Path $sunshineLogPath) { (Get-Item $sunshineLogPath).Length } else { 0 }

    $sleepEventTypes = 4
    $wakeEventTypes = 7, 18
    Register-WmiEvent -Class Win32_PowerManagementEvent -SourceIdentifier 'PowerChange' | Out-Null
    $wentToSleep = $false
    $hasWoken = $false

    while (-not $stopSignal.WaitOne(1000) -and (Get-Service $serviceName).Status -eq 'Running') {
      $powerEvents = @(Get-Event -SourceIdentifier 'PowerChange' -ErrorAction SilentlyContinue)
      if ($powerEvents) {
        $powerEventTypes = $powerEvents | ForEach-Object { $_.SourceEventArgs.NewEvent.EventType }
        $powerEvents | Remove-Event
        $hasWoken = [bool]($powerEventTypes | Where-Object { $_ -in $wakeEventTypes })
        if ($hasWoken -or ($powerEventTypes | Where-Object { $_ -in $sleepEventTypes })) {
          $wentToSleep = $true
          Stop-Stream
          break
        }
      }
      if ([DefaultOutput]::GetName() -match 'CABLE Input') {
        Start-Sleep -Milliseconds 500
        Restore-Speakers
      }
      $disconnectLine = (Read-NewLogLines) -match 'CLIENT DISCONNECTED|: Ping Timeout' | Select-Object -Last 1
      if ($disconnectLine) {
        $reason = if ($disconnectLine -match 'Ping Timeout') { 'Ping Timeout' } else { 'CLIENT DISCONNECTED' }
        Start-Hidden 'notice.ps1' "-messageKey disconnected -reason `"$reason`""
      }
    }

    if ($wentToSleep) {
      while (-not $hasWoken) {
        $powerEvent = Wait-Event -SourceIdentifier 'PowerChange' -Timeout 86400
        if (-not $powerEvent) { break }
        $hasWoken = $powerEvent.SourceEventArgs.NewEvent.EventType -in $wakeEventTypes
        $powerEvent | Remove-Event
      }
      if ($hasWoken) {
        if ((Get-Service $serviceName).Status -ne 'Stopped' -or (Test-Path $streamActivePath)) { Stop-Stream }
        Start-Hidden 'notice.ps1' '-messageKey sleepEnded'
      }
    }
    Unregister-Event -SourceIdentifier 'PowerChange' -ErrorAction SilentlyContinue
  }
}
