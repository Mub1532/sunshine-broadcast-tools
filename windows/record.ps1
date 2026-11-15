# records the screen and the stream's sound to a video file. runs for as long as a broadcast is being recorded.
# libmpv does the recording (smooth, same capture the camera box uses); ffmpeg only joins the pieces at the end.
param([int]$seconds = 0)

. "$PSScriptRoot\utils.ps1"

$config = @{
  framesPerSecond = 30
  # picture quality, lower = sharper and bigger files, higher = softer and smaller. 18 to 30 is the sensible range
  quality         = 28
  soundKbps       = 128
  # stops recording if the disk gets this close to full, so it never fills the drive. the stream keeps running
  keepFreeGB      = 2
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
$scriptStarted = Get-Date

# while recording, the pieces live in a dated "_sections" folder. at the end, a single recording moves out as one file and
# the folder is removed; several pieces are joined into a "_full" file and the folder is removed only if that join worked
$sectionsFolder = Join-Path $folder "SBT_Recording_$($scriptStarted.ToString('dd-MM-yyyy_HH.mm'))_sections"

# picks the name for the next piece from the time right now
function Set-RecordingPath {
  New-Item $sectionsFolder -ItemType Directory -Force | Out-Null
  $baseName = "SBT_Recording_$((Get-Date).ToString('dd-MM-yyyy_HH.mm'))"
  $script:filePath = Join-Path $sectionsFolder "$baseName.mkv"
  for ($copy = 2; Test-Path $script:filePath; $copy++) { $script:filePath = Join-Path $sectionsFolder "${baseName}_$copy.mkv" }
}
Set-RecordingPath

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

# the laptop's graphics chip does the compressing when it can, so recording stays smooth. the processor is the fallback
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

# every finished piece this session, so they can be joined into one file at the end
$script:segments = @()

# finishes the file properly and adds the time it ended to its name
function Complete-Recording {
  [Recorder]::Stop()
  $finalPath = Join-Path $sectionsFolder "$([System.IO.Path]::GetFileNameWithoutExtension($filePath))-$((Get-Date).ToString('HH.mm')).mkv"
  try {
    Rename-Item $filePath $finalPath -ErrorAction Stop
    $script:segments += $finalPath
    Write-RecordLog "finished, saved as $finalPath"
  }
  catch {
    $script:segments += $filePath
    Write-RecordLog "finished, saved as $filePath (could not add the end time to the name)"
  }
}

# when a clean end leaves more than one piece (from pausing), ffmpeg stitches them into one "_full" file with the concat
# FILTER (it decodes and re-joins with fresh timestamps, so there's no frozen gap at the joins the way a plain copy gives).
# the graphics chip re-encodes it, fast, since the stream has ended. pieces are only deleted once the joined file is really
# there; if the join fails or a crash skips it, the pieces stay as separate playable files - nothing is ever lost.
function Finish-Recordings {
  $parts = @($script:segments | Where-Object { Test-Path $_ })

  # nothing recorded - just clear the empty folder
  if ($parts.Count -eq 0) { Remove-Item $sectionsFolder -Recurse -Force -ErrorAction SilentlyContinue; return }

  # a single recording (no pause): move it out as one file and remove the sections folder
  if ($parts.Count -eq 1) {
    Move-Item $parts[0] (Join-Path $folder (Split-Path $parts[0] -Leaf)) -Force -ErrorAction SilentlyContinue
    Remove-Item $sectionsFolder -Recurse -Force -ErrorAction SilentlyContinue
    Write-RecordLog 'one recording, moved out of the sections folder'
    return
  }

  if (-not (Test-Path $ffmpegPath)) { Write-RecordLog 'ffmpeg missing, left the pieces in the sections folder'; return }

  # ffmpeg encoder for the re-stitch - chip first, processor as fallback
  $q = $config.quality
  $joinEnc =
    if     ($graphics -match 'NVIDIA')     { "h264_nvenc -rc constqp -qp $q" }
    elseif ($graphics -match 'AMD|Radeon') { "h264_amf -rc cqp -qp_i $q -qp_p $q -qp_b $q" }
    elseif ($graphics -match 'Intel')      { "h264_qsv -global_quality $q" }
    else                                   { "libx264 -preset veryfast -crf $q" }

  $joinPath = Join-Path $folder "SBT_Recording_$($scriptStarted.ToString('dd-MM-yyyy_HH.mm'))-$((Get-Date).ToString('HH.mm'))_full.mkv"
  Remove-Item $joinPath -ErrorAction SilentlyContinue

  $inputs = ($parts | ForEach-Object { "-i `"$_`"" }) -join ' '
  $streams = (0..($parts.Count - 1) | ForEach-Object { "[$_`:v][$_`:a]" }) -join ''
  $filter = "${streams}concat=n=$($parts.Count):v=1:a=1[v][a]"
  $joinArgs = "-y -hide_banner -loglevel error $inputs -filter_complex `"$filter`" -map `"[v]`" -map `"[a]`" " +
    "-c:v $joinEnc -pix_fmt yuv420p -c:a aac -b:a $($config.soundKbps)k `"$joinPath`""

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ffmpegPath
  $psi.Arguments = $joinArgs
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $join = [System.Diagnostics.Process]::Start($psi)
  if ($join) { $join.WaitForExit() }

  $largestPart = ($parts | ForEach-Object { (Get-Item $_).Length } | Measure-Object -Maximum).Maximum
  $joinSize = if (Test-Path $joinPath) { (Get-Item $joinPath).Length } else { 0 }
  Write-RecordLog "join: largest piece $([math]::Round($largestPart / 1MB)) MB, joined $([math]::Round($joinSize / 1MB)) MB"
  # a full re-encode of every piece is always bigger than any single piece; if it isn't, the join came out short so keep the pieces
  if ($join -and $join.ExitCode -eq 0 -and $joinSize -ge $largestPart) {
    Remove-Item $sectionsFolder -Recurse -Force -ErrorAction SilentlyContinue
    Write-RecordLog "joined $($parts.Count) pieces into $joinPath, sections folder removed"
  }
  else {
    Remove-Item $joinPath -ErrorAction SilentlyContinue
    Write-RecordLog "join failed (exit $(if ($join) { $join.ExitCode } else { 'not started' })), kept the pieces in $sectionsFolder"
  }
}

$working = $null
foreach ($encoder in $encoders) {
  # first with our quality setting, then with the encoder's own defaults in case it doesn't know that setting
  foreach ($encoderOptions in $encoder[1], '') {
    if (Start-Recording $encoder[0] $encoderOptions) {
      $working = @($encoder[0], $encoderOptions)
      break
    }
  }
  if ($working) { break }
}
if (-not $working) {
  Write-RecordLog 'could not start: no way of compressing the video worked'
  exit 1
}
Write-RecordLog "started with $($working[0]), saving to $filePath"

$stopSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $recordStopName)
$pauseSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $recordPauseName)
$readySignal = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $recordReadyName)
$recordingNow = $true
$spaceChecks = 0
while (-not $stopSignal.WaitOne(200)) {
  # every ~5 seconds, stop cleanly if the disk is nearly full so it never fills up. the stream itself carries on
  if ($recordingNow -and ++$spaceChecks % 25 -eq 0 -and (Get-FreeGB $folder) -lt $config.keepFreeGB) {
    Complete-Recording
    Finish-Recordings
    Write-RecordLog 'stopped because the disk is nearly full'
    Show-Message (Format-Text $messageConfig.recordStoppedSpace @{ need = $config.keepFreeGB }) 'Warning' | Out-Null
    [Environment]::Exit(0)
  }
  # pausing finishes the current file, and resuming starts a new one, so every file is complete and plays on its own
  if ($pauseSignal.WaitOne(0)) {
    if ($recordingNow) {
      Complete-Recording
      $recordingNow = $false
      Write-RecordLog 'paused'
    }
    continue
  }
  if (-not $recordingNow) {
    Set-RecordingPath
    if (-not (Start-Recording $working[0] $working[1])) {
      Write-RecordLog 'could not resume'
      break
    }
    $recordingNow = $true
    Write-RecordLog "resumed, saving to $filePath"
    continue
  }
  [Recorder]::Check()
  if ([Recorder]::Ended) {
    Write-RecordLog 'stopped by itself before the stream ended'
    break
  }
  if ($seconds -gt 0 -and ((Get-Date) - $scriptStarted).TotalSeconds -ge $seconds) { break }
}
if ($recordingNow) { Complete-Recording }
Finish-Recordings
# a short path for the popup, eg "Videos\Sunshine Broadcast Tools" instead of the full C:\Users\... path
$shortFolder = $folder.Replace("$env:USERPROFILE\", '')
Show-Message (Format-Text $messageConfig.recordSaved @{ folder = $shortFolder }) | Out-Null
[Environment]::Exit(0)
