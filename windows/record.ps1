# records the screen and the stream's sound to a video file. runs for as long as a broadcast is being recorded
param([int]$seconds = 0)

. "$PSScriptRoot\utils.ps1"

$config = @{
  framesPerSecond = 30
  # picture quality, lower = sharper and bigger files, higher = softer and smaller. 18 to 30 is the sensible range
  quality         = 24
  soundKbps       = 128
}

$recordLock = New-Object System.Threading.Mutex($false, $recordLockName)
if (-not $recordLock.WaitOne(0)) { exit }

function Write-RecordLog([string]$text) {
  try {
    New-Item (Split-Path $debugLogPath) -ItemType Directory -Force | Out-Null
    Add-Content $debugLogPath "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  record.ps1: $text"
  }
  catch {}
}

if (-not (Test-Path $libmpvPath)) {
  Write-RecordLog 'could not start: libmpv is not installed'
  exit 1
}

$folder = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'Sunshine Broadcast Tools'
New-Item $folder -ItemType Directory -Force | Out-Null
$startedAt = Get-Date
$baseName = "SBT_Recording_$($startedAt.ToString('dd-MM-yyyy_HH.mm'))"
$filePath = Join-Path $folder "$baseName.mkv"
for ($copy = 2; Test-Path $filePath; $copy++) { $filePath = Join-Path $folder "${baseName}_$copy.mkv" }

Import-CSharp 'recorder' @'
using System;
using System.Runtime.InteropServices;
using System.Text;

// records the screen and the stream's sound to a file with libmpv, the same library the camera box uses
public static class Recorder {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("libmpv-2.dll")] static extern IntPtr mpv_create();
  [DllImport("libmpv-2.dll")] static extern int mpv_set_option_string(IntPtr player, byte[] name, byte[] value);
  [DllImport("libmpv-2.dll")] static extern int mpv_initialize(IntPtr player);
  [DllImport("libmpv-2.dll")] static extern int mpv_command_string(IntPtr player, byte[] command);
  [DllImport("libmpv-2.dll")] static extern IntPtr mpv_wait_event(IntPtr player, double timeout);
  [DllImport("libmpv-2.dll")] static extern void mpv_terminate_destroy(IntPtr player);

  static IntPtr player = IntPtr.Zero;
  public static bool Ended;

  static byte[] Text(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }

  // options are "name=value". returns an empty string when it started, otherwise what went wrong
  public static string Start(string library, string[] options, string source) {
    // without this windows hands over a shrunken screen on scaled displays and the recording comes out soft
    SetProcessDPIAware();
    LoadLibrary(library);
    player = mpv_create();
    if (player == IntPtr.Zero) return "libmpv could not be started";
    Ended = false;
    foreach (string option in options) {
      int split = option.IndexOf('=');
      if (mpv_set_option_string(player, Text(option.Substring(0, split)), Text(option.Substring(split + 1))) < 0) { Close(); return "libmpv refused the setting " + option; }
    }
    if (mpv_initialize(player) < 0) { Close(); return "libmpv could not be set up"; }
    if (mpv_command_string(player, Text("loadfile \"" + source + "\"")) < 0) { Close(); return "libmpv could not open the screen"; }
    return "";
  }

  // reads what libmpv has reported since last time, and notes if the recording ended by itself
  public static void Check() {
    while (player != IntPtr.Zero) {
      int kind = Marshal.ReadInt32(mpv_wait_event(player, 0));
      if (kind == 0) break;
      if (kind == 1 || kind == 7) Ended = true;
    }
  }

  // asks libmpv to finish the file properly and waits for it
  public static void Stop() {
    if (player == IntPtr.Zero) return;
    mpv_command_string(player, Text("quit"));
    DateTime limit = DateTime.UtcNow.AddSeconds(15);
    while (DateTime.UtcNow < limit && Marshal.ReadInt32(mpv_wait_event(player, 0.5)) != 1) { }
    Close();
  }

  static void Close() {
    if (player != IntPtr.Zero) mpv_terminate_destroy(player);
    player = IntPtr.Zero;
  }
}
'@

# the laptop's graphics chip does the compressing when it can, so recording doesn't slow the stream down. the processor is the fallback
$graphics = (Get-CimInstance Win32_VideoController).Name -join ', '
$quality = $config.quality
$encoders = @()
if ($graphics -match 'NVIDIA') { $encoders += , @('h264_nvenc', "rc=constqp,qp=$quality") }
if ($graphics -match 'AMD|Radeon') { $encoders += , @('h264_amf', "rc=cqp,qp_i=$quality,qp_p=$quality") }
if ($graphics -match 'Intel') { $encoders += , @('h264_qsv', "global_quality=$quality") }
$encoders += , @('libx264', "preset=veryfast,crf=$quality")

# tries one way of compressing. true when the file is really being written a few seconds later
function Start-Recording([string]$encoder, [string]$encoderOptions) {
  Remove-Item $filePath -ErrorAction SilentlyContinue
  $options = @(
    "o=$filePath"
    "ovc=$encoder"
    'oac=aac'
    "oacopts=b=$($config.soundKbps)k"
    'audio-files=av://dshow:audio=CABLE Output (VB-Audio Virtual Cable)'
    'demuxer-lavf-o=audio_buffer_size=50'
  )
  if ($encoderOptions) { $options += "ovcopts=$encoderOptions" }
  $problem = [Recorder]::Start($libmpvPath, $options, "av://lavfi:ddagrab=framerate=$($config.framesPerSecond),hwdownload,format=bgra,format=yuv420p")
  if ($problem) {
    Write-RecordLog "$encoder did not start: $problem"
    return $false
  }
  for ($wait = 0; $wait -lt 40; $wait++) {
    Start-Sleep -Milliseconds 200
    [Recorder]::Check()
    if ([Recorder]::Ended) { break }
    if ((Test-Path $filePath) -and (Get-Item $filePath).Length -gt 0) { return $true }
  }
  [Recorder]::Stop()
  Write-RecordLog "$encoder did not produce a file$(if ($encoderOptions) { " with $encoderOptions" })"
  $false
}

$recording = $false
foreach ($encoder in $encoders) {
  # first with our quality setting, then with the encoder's own defaults in case it doesn't know that setting
  if ((Start-Recording $encoder[0] $encoder[1]) -or (Start-Recording $encoder[0] '')) {
    $recording = $true
    Write-RecordLog "started with $($encoder[0]), saving to $filePath"
    break
  }
}
if (-not $recording) {
  Write-RecordLog 'could not start: no way of compressing the video worked'
  exit 1
}

$stopSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $recordStopName)
$readySignal = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $recordReadyName)
while (-not $stopSignal.WaitOne(200)) {
  [Recorder]::Check()
  if ([Recorder]::Ended) {
    Write-RecordLog 'stopped by itself before the stream ended'
    break
  }
  if ($seconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $seconds) { break }
}
[Recorder]::Stop()

# the finished file gets the time it ended added to its name
$finalPath = Join-Path $folder "$([System.IO.Path]::GetFileNameWithoutExtension($filePath))-$((Get-Date).ToString('HH.mm')).mkv"
try {
  Rename-Item $filePath $finalPath -ErrorAction Stop
  Write-RecordLog "finished, saved as $finalPath"
}
catch { Write-RecordLog "finished, saved as $filePath (could not add the end time to the name)" }
[Environment]::Exit(0)
