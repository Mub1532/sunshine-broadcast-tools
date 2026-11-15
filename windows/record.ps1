# records the screen and the stream's sound to a video file. runs for as long as a broadcast is being recorded.
# uses ffmpeg (on the processor, so it never steals the graphics chip from the stream). libmpv is the fallback.
param([int]$seconds = 0)

. "$PSScriptRoot\utils.ps1"

$config = @{
  framesPerSecond = 30
  # picture quality, lower = sharper and bigger files, higher = softer and smaller. 18 to 30 is the sensible range
  quality         = 28
  # processor effort. "ultrafast" is the lightest so even a weak laptop can record while the stream uses the graphics chip
  preset          = 'ultrafast'
  soundKbps       = 128
  # stops recording if the disk gets this close to full, so it never fills the drive. the stream keeps running
  keepFreeGB      = 2
}

$audioDevice = 'CABLE Output (VB-Audio Virtual Cable)'

# the graphics chip compresses the recording (fast and smooth, same as the stream uses). the processor is the last resort.
# the stream already proves the chip can encode while streaming, so recording on it too is fine and far smoother than the cpu
$graphics = (Get-CimInstance Win32_VideoController).Name -join ', '
$q = $config.quality
$gpuVideoArgs =
  if     ($graphics -match 'NVIDIA')     { "-c:v h264_nvenc -rc constqp -qp $q" }
  elseif ($graphics -match 'AMD|Radeon') { "-c:v h264_amf -rc cqp -qp_i $q -qp_p $q -qp_b $q" }
  elseif ($graphics -match 'Intel')      { "-c:v h264_qsv -global_quality $q" }
  else                                   { '' }
$cpuVideoArgs = "-c:v libx264 -preset $($config.preset) -crf $q"
# the chip's encoder first, the processor only if there's no chip encoder or it won't start
$script:videoArgs = if ($gpuVideoArgs) { $gpuVideoArgs } else { $cpuVideoArgs }

$recordLock = New-Object System.Threading.Mutex($false, $recordLockName)
if (-not $recordLock.WaitOne(0)) { exit }

function Write-RecordLog([string]$text) {
  try {
    New-Item (Split-Path $debugLogPath) -ItemType Directory -Force | Out-Null
    Add-Content $debugLogPath "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  record.ps1: $text"
  }
  catch {}
}

if (-not (Test-Path $ffmpegPath) -and -not (Test-Path $libmpvPath)) {
  Write-RecordLog 'could not start: neither ffmpeg nor libmpv is installed'
  exit 1
}

$folder = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'Sunshine Broadcast Tools'
New-Item $folder -ItemType Directory -Force | Out-Null
$scriptStarted = Get-Date

# picks the name for the next file from the time right now
function Set-RecordingPath {
  $baseName = "SBT_Recording_$((Get-Date).ToString('dd-MM-yyyy_HH.mm'))"
  $script:filePath = Join-Path $folder "$baseName.mkv"
  for ($copy = 2; Test-Path $script:filePath; $copy++) { $script:filePath = Join-Path $folder "${baseName}_$copy.mkv" }
}
Set-RecordingPath

# every finished piece this session, so they can be joined into one file at the end
$script:segments = @()
$script:ffProc = $null
$script:libmpvReady = $false

# ---- ffmpeg engine ----

function Start-FfmpegProcess([string]$arguments, [bool]$withStdin) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ffmpegPath
  $psi.Arguments = $arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $withStdin
  return [System.Diagnostics.Process]::Start($psi)
}

# ddagrab grabs the screen off the graphics chip, then libx264 compresses it on the processor so the stream is untouched
function Start-FfmpegPiece {
  Remove-Item $filePath -ErrorAction SilentlyContinue
  $fps = $config.framesPerSecond
  $arguments = '-y -hide_banner -loglevel error -nostats ' +
    "-f lavfi -i ddagrab=framerate=$fps,hwdownload,format=bgra " +
    "-f dshow -i `"audio=$audioDevice`" " +
    "$script:videoArgs -pix_fmt yuv420p " +
    "-fps_mode cfr -r $fps " +
    "-c:a aac -b:a $($config.soundKbps)k " +
    "`"$filePath`""
  $script:ffProc = Start-FfmpegProcess $arguments $true
  if (-not $script:ffProc) { return $false }
  for ($wait = 0; $wait -lt 50; $wait++) {
    Start-Sleep -Milliseconds 200
    if ($script:ffProc.HasExited) { Write-RecordLog "ffmpeg stopped right away (code $($script:ffProc.ExitCode))"; return $false }
    if ((Test-Path $filePath) -and (Get-Item $filePath).Length -gt 0) { return $true }
  }
  Stop-FfmpegPiece
  Write-RecordLog 'ffmpeg did not start writing a file'
  return $false
}

# sends "q" so ffmpeg finishes the file properly, same as pressing q in a window
function Stop-FfmpegPiece {
  if (-not $script:ffProc) { return }
  try {
    if (-not $script:ffProc.HasExited) {
      $script:ffProc.StandardInput.Write('q')
      $script:ffProc.StandardInput.Flush()
      $script:ffProc.StandardInput.Close()
      if (-not $script:ffProc.WaitForExit(15000)) { $script:ffProc.Kill() }
    }
  }
  catch { try { $script:ffProc.Kill() } catch {} }
  $script:ffProc = $null
}

# ---- libmpv engine (fallback) ----

function Initialize-Libmpv {
  if ($script:libmpvReady) { return $true }
  if (-not (Test-Path $libmpvPath)) { return $false }
  Import-CSharp 'recorder' @'
using System;
using System.Runtime.InteropServices;
using System.Text;

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

  public static string Start(string library, string[] options, string source) {
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

  public static void Check() {
    while (player != IntPtr.Zero) {
      int kind = Marshal.ReadInt32(mpv_wait_event(player, 0));
      if (kind == 0) break;
      if (kind == 1 || kind == 7) Ended = true;
    }
  }

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
  $script:libmpvReady = $true
  return $true
}

function Start-LibmpvPiece {
  Remove-Item $filePath -ErrorAction SilentlyContinue
  $options = @(
    "o=$filePath"
    'ovc=libx264'
    "ovcopts=preset=$($config.preset),crf=$($config.quality)"
    'oac=aac'
    "oacopts=b=$($config.soundKbps)k"
    "audio-files=av://dshow:audio=$audioDevice"
    'demuxer-lavf-o=audio_buffer_size=50'
  )
  $problem = [Recorder]::Start($libmpvPath, $options, "av://lavfi:ddagrab=framerate=$($config.framesPerSecond),hwdownload,format=bgra,format=yuv420p")
  if ($problem) { Write-RecordLog "libmpv did not start: $problem"; return $false }
  for ($wait = 0; $wait -lt 50; $wait++) {
    Start-Sleep -Milliseconds 200
    [Recorder]::Check()
    if ([Recorder]::Ended) { break }
    if ((Test-Path $filePath) -and (Get-Item $filePath).Length -gt 0) { return $true }
  }
  [Recorder]::Stop()
  Write-RecordLog 'libmpv did not produce a file'
  return $false
}

# ---- engine-independent ----

function Start-Segment {
  if ($script:engine -eq 'ffmpeg') {
    if (Start-FfmpegPiece) { return $true }
    # if the graphics-chip encoder wouldn't start, drop to the processor encoder before giving up on ffmpeg
    if ($script:videoArgs -ne $cpuVideoArgs) {
      Write-RecordLog 'ffmpeg graphics-chip encoder failed, trying the processor encoder'
      $script:videoArgs = $cpuVideoArgs
      if (Start-FfmpegPiece) { return $true }
    }
    Write-RecordLog 'ffmpeg recording failed, falling back to libmpv'
    if (Initialize-Libmpv) { $script:engine = 'libmpv' } else { return $false }
  }
  return (Start-LibmpvPiece)
}

function Stop-Segment {
  if ($script:engine -eq 'ffmpeg') { Stop-FfmpegPiece } else { [Recorder]::Stop() }
}

# true when the recording stopped on its own (ffmpeg died, or libmpv reached the end)
function Test-SegmentEnded {
  if ($script:engine -eq 'ffmpeg') { return $script:ffProc.HasExited }
  [Recorder]::Check()
  return [Recorder]::Ended
}

# finishes the file properly and adds the time it ended to its name
function Complete-Recording {
  Stop-Segment
  $finalPath = Join-Path $folder "$([System.IO.Path]::GetFileNameWithoutExtension($filePath))-$((Get-Date).ToString('HH.mm')).mkv"
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

# when a clean end leaves more than one piece (from pausing), ffmpeg joins them into one "_full" file without re-encoding,
# then deletes the pieces so only the one file is left. the pieces are only deleted when the joined file came out complete
# (about the size of all the pieces together, since copying is lossless). if the join fails, or a crash skips this, the
# pieces just stay in the folder as separate playable files - nothing is ever lost.
function Join-Recordings {
  $parts = @($script:segments | Where-Object { Test-Path $_ })
  if ($parts.Count -le 1 -or -not (Test-Path $ffmpegPath)) { return }

  $listPath = Join-Path $env:TEMP "sbt-join-$PID.txt"
  ($parts | ForEach-Object { "file '$($_.Replace("'", "'\''"))'" }) -join "`n" | Set-Content $listPath -Encoding ASCII
  # "_full" so the joined file can never share a name with one of the pieces
  $joinPath = Join-Path $folder "SBT_Recording_$($scriptStarted.ToString('dd-MM-yyyy_HH.mm'))-$((Get-Date).ToString('HH.mm'))_full.mkv"
  Remove-Item $joinPath -ErrorAction SilentlyContinue

  $joinArgs = "-y -hide_banner -loglevel error -f concat -safe 0 -i `"$listPath`" -c copy `"$joinPath`""
  $join = Start-FfmpegProcess $joinArgs $false
  if ($join) { $join.WaitForExit() }
  Remove-Item $listPath -ErrorAction SilentlyContinue

  $totalParts = ($parts | ForEach-Object { (Get-Item $_).Length } | Measure-Object -Sum).Sum
  $joinSize = if (Test-Path $joinPath) { (Get-Item $joinPath).Length } else { 0 }
  if ($join -and $join.ExitCode -eq 0 -and $joinSize -ge $totalParts * 0.9) {
    foreach ($part in $parts) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
    Write-RecordLog "joined $($parts.Count) pieces into $joinPath, pieces deleted"
  }
  else {
    Remove-Item $joinPath -ErrorAction SilentlyContinue
    Write-RecordLog "join failed (exit $(if ($join) { $join.ExitCode } else { 'not started' })), kept the pieces as separate files"
  }
}

# ---- run ----

$script:engine = if (Test-Path $ffmpegPath) { 'ffmpeg' } else { 'libmpv' }
if ($script:engine -eq 'libmpv' -and -not (Initialize-Libmpv)) {
  Write-RecordLog 'could not start: no recorder available'
  exit 1
}

if (-not (Start-Segment)) {
  Write-RecordLog 'could not start: recording would not begin'
  exit 1
}
Write-RecordLog "recording with $script:engine, saving to $filePath"

$stopSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $recordStopName)
$pauseSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $recordPauseName)
$readySignal = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $recordReadyName)
$recordingNow = $true
$spaceChecks = 0
while (-not $stopSignal.WaitOne(200)) {
  # every ~5 seconds, stop cleanly if the disk is nearly full so it never fills up. the stream itself carries on
  if ($recordingNow -and ++$spaceChecks % 25 -eq 0 -and (Get-FreeGB $folder) -lt $config.keepFreeGB) {
    Complete-Recording
    Join-Recordings
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
    if (-not (Start-Segment)) {
      Write-RecordLog 'could not resume'
      break
    }
    $recordingNow = $true
    Write-RecordLog "resumed, saving to $filePath"
    continue
  }
  if (Test-SegmentEnded) {
    Write-RecordLog 'stopped by itself before the stream ended'
    break
  }
  if ($seconds -gt 0 -and ((Get-Date) - $scriptStarted).TotalSeconds -ge $seconds) { break }
}
if ($recordingNow) { Complete-Recording }
Join-Recordings
# a short path for the popup, eg "Videos\Sunshine Broadcast Tools" instead of the full C:\Users\... path
$shortFolder = $folder.Replace("$env:USERPROFILE\", '')
Show-Message (Format-Text $messageConfig.recordSaved @{ folder = $shortFolder }) | Out-Null
[Environment]::Exit(0)
