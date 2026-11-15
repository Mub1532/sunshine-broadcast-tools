# mixes the microphone with the laptop's own sound and plays it into the virtual cable, which is what the stream hears. runs for as long as a broadcast is on
. "$PSScriptRoot\utils.ps1"

# how loud each part is in what the stream hears. 100 = full, 0 = off
$config = @{
  laptopSoundPercent          = 15
  # while the microphone is muted the laptop sound fades up to this, and fades back down when it's unmuted
  laptopSoundPercentWhenMuted = 50
  microphonePercent           = 100
}

$mixLock = New-Object System.Threading.Mutex($false, $audioMixLockName)
if (-not $mixLock.WaitOne(0)) { exit }

function Write-MixLog([string]$text) {
  try {
    New-Item (Split-Path $debugLogPath) -ItemType Directory -Force | Out-Null
    Add-Content $debugLogPath "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  audio-mix.ps1: $text"
  }
  catch {}
}

# our saved device ids look like 'Realtek(R) Audio\Device\Speakers\Render', windows calls the same device 'Speakers (Realtek(R) Audio)'
function Get-WindowsName([string]$deviceId) {
  $parts = $deviceId -split '\\'
  "$($parts[2]) ($($parts[0]))"
}

$deviceConfig = Get-Content $deviceConfigPath -Raw | ConvertFrom-Json

Import-CSharp 'audio-mix' @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MixDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixDeviceEnumerator {
  [PreserveSig] int EnumAudioEndpoints(int flow, int stateMask, out IMixDeviceCollection devices);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixDeviceCollection {
  [PreserveSig] int GetCount(out uint count);
  [PreserveSig] int Item(uint index, out IMixDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixDevice {
  [PreserveSig] int Activate(ref Guid id, int context, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object result);
  [PreserveSig] int OpenPropertyStore(int access, out IMixPropertyStore store);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixPropertyStore {
  [PreserveSig] int GetCount(out uint count);
  [PreserveSig] int GetAt(uint index, out MixPropertyKey key);
  [PreserveSig] int GetValue(ref MixPropertyKey key, out MixPropVariant value);
}

[StructLayout(LayoutKind.Sequential)]
struct MixPropertyKey { public Guid FormatId; public int PropertyId; }

[StructLayout(LayoutKind.Explicit, Size = 24)]
struct MixPropVariant { [FieldOffset(0)] public short Type; [FieldOffset(8)] public IntPtr Pointer; }

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixAudioClient {
  [PreserveSig] int Initialize(int shareMode, int flags, long bufferDuration, long periodicity, IntPtr format, IntPtr session);
  [PreserveSig] int GetBufferSize(out uint frames);
  [PreserveSig] int GetStreamLatency(out long latency);
  [PreserveSig] int GetCurrentPadding(out uint padding);
  [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
  [PreserveSig] int GetMixFormat(out IntPtr format);
  [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
  [PreserveSig] int Start();
  [PreserveSig] int Stop();
  [PreserveSig] int Reset();
  [PreserveSig] int SetEventHandle(IntPtr handle);
  [PreserveSig] int GetService(ref Guid id, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixEndpointVolume {
  [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
  [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
  [PreserveSig] int GetChannelCount(out uint count);
  [PreserveSig] int SetMasterVolumeLevel(float level, IntPtr context);
  [PreserveSig] int SetMasterVolumeLevelScalar(float level, IntPtr context);
  [PreserveSig] int GetMasterVolumeLevel(out float level);
  [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
  [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, IntPtr context);
  [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, IntPtr context);
  [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
  [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
  [PreserveSig] int SetMute(int mute, IntPtr context);
  [PreserveSig] int GetMute(out int mute);
  [PreserveSig] int GetVolumeStepInfo(out uint step, out uint steps);
  [PreserveSig] int VolumeStepUp(IntPtr context);
  [PreserveSig] int VolumeStepDown(IntPtr context);
  [PreserveSig] int QueryHardwareSupport(out uint support);
}

[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixCaptureClient {
  [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong clockPosition);
  [PreserveSig] int ReleaseBuffer(uint frames);
  [PreserveSig] int GetNextPacketSize(out uint frames);
}

[ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMixRenderClient {
  [PreserveSig] int GetBuffer(uint frames, out IntPtr data);
  [PreserveSig] int ReleaseBuffer(uint frames, uint flags);
}

// one sound device opened for capture or playback, with its format worked out
class MixStream {
  public IMixAudioClient Client;
  public IMixEndpointVolume Volume;
  public int Rate, Channels, Bits, BlockAlign;
  public bool IsFloat;

  public static MixStream Open(string name, bool render, bool loopback) {
    var enumerator = (IMixDeviceEnumerator)new MixDeviceEnumerator();
    IMixDeviceCollection devices;
    Check(enumerator.EnumAudioEndpoints(render || loopback ? 0 : 1, 1, out devices), "listing sound devices");
    uint count;
    devices.GetCount(out count);
    var friendlyName = new MixPropertyKey { FormatId = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), PropertyId = 14 };
    for (uint index = 0; index < count; index++) {
      IMixDevice device;
      if (devices.Item(index, out device) < 0) continue;
      IMixPropertyStore store;
      if (device.OpenPropertyStore(0, out store) < 0) continue;
      MixPropVariant value;
      if (store.GetValue(ref friendlyName, out value) < 0 || value.Type != 31) continue;
      if (!string.Equals(Marshal.PtrToStringUni(value.Pointer), name, StringComparison.OrdinalIgnoreCase)) continue;

      Guid clientId = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
      object clientObject;
      Check(device.Activate(ref clientId, 23, IntPtr.Zero, out clientObject), "opening " + name);
      var stream = new MixStream { Client = (IMixAudioClient)clientObject };
      IntPtr format;
      Check(stream.Client.GetMixFormat(out format), "reading the format of " + name);
      int tag = Marshal.ReadInt16(format, 0) & 0xFFFF;
      stream.Channels = Marshal.ReadInt16(format, 2);
      stream.Rate = Marshal.ReadInt32(format, 4);
      stream.BlockAlign = Marshal.ReadInt16(format, 12);
      stream.Bits = Marshal.ReadInt16(format, 14);
      stream.IsFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(format, 24) == 3);
      if (!(stream.IsFloat && stream.Bits == 32) && stream.Bits != 16 && stream.Bits != 24 && stream.Bits != 32) throw new Exception(name + " uses a sound format this can't handle (" + stream.Bits + "-bit)");
      Check(stream.Client.Initialize(0, loopback ? 0x00020000 : 0, 2000000, 0, format, IntPtr.Zero), "starting " + name);
      if (loopback) {
        Guid volumeId = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        object volumeObject;
        if (device.Activate(ref volumeId, 23, IntPtr.Zero, out volumeObject) >= 0) stream.Volume = (IMixEndpointVolume)volumeObject;
      }
      return stream;
    }
    throw new Exception("could not find the sound device '" + name + "'");
  }

  public static void Check(int result, string step) {
    if (result < 0) throw new Exception(step + " failed (0x" + result.ToString("X8") + ")");
  }

  public float ReadSample(byte[] bytes, int offset) {
    if (IsFloat) return BitConverter.ToSingle(bytes, offset);
    if (Bits == 16) return BitConverter.ToInt16(bytes, offset) / 32768f;
    if (Bits == 32) return BitConverter.ToInt32(bytes, offset) / 2147483648f;
    return (bytes[offset] | (bytes[offset + 1] << 8) | ((sbyte)bytes[offset + 2] << 16)) / 8388608f;
  }

  public void WriteSample(byte[] bytes, int offset, float sample) {
    sample = Math.Max(-1f, Math.Min(1f, sample));
    if (IsFloat) { Buffer.BlockCopy(BitConverter.GetBytes(sample), 0, bytes, offset, 4); return; }
    if (Bits == 16) { Buffer.BlockCopy(BitConverter.GetBytes((short)(sample * 32767)), 0, bytes, offset, 2); return; }
    int whole = (int)(sample * (Bits == 32 ? 2147483647f : 8388607f));
    bytes[offset] = (byte)whole; bytes[offset + 1] = (byte)(whole >> 8); bytes[offset + 2] = (byte)(whole >> 16);
    if (Bits == 32) bytes[offset + 3] = (byte)(whole >> 24);
  }
}

// sound waiting to be mixed, one channel at the output's rate. if it piles up the oldest is dropped so the sound never falls behind
class MixQueue {
  readonly Queue<float> samples = new Queue<float>();
  readonly int limit, keep;
  public MixQueue(int limit, int keep) { this.limit = limit; this.keep = keep; }

  public void Add(float[] block, int count) {
    lock (samples) {
      for (int index = 0; index < count; index++) samples.Enqueue(block[index]);
      if (samples.Count > limit) while (samples.Count > keep) samples.Dequeue();
    }
  }

  public int Count { get { lock (samples) return samples.Count; } }

  // fills the block with what is waiting and silence for the rest
  public void Take(float[] block, int count) {
    lock (samples) {
      for (int index = 0; index < count; index++) block[index] = samples.Count > 0 ? samples.Dequeue() : 0f;
    }
  }
}

// mixes the microphone with the laptop's own sound and plays the result into the virtual cable, which is what the stream hears
public static class AudioMixer {
  static volatile bool running;
  static volatile string failure;
  static readonly List<Thread> threads = new List<Thread>();
  static MixQueue microphoneQueue, laptopQueue;
  static string details = "";

  public static volatile bool MicrophoneMuted;
  public static volatile float LaptopLevel = 0.15f;
  public static volatile float LaptopLevelWhenMuted = 0.5f;
  public static volatile float MicrophoneLevel = 1f;
  public static string Failure { get { return failure; } }
  public static string Details { get { return details; } }

  // returns an empty string when it started, otherwise what went wrong
  public static string Start(string speakers, string microphone, string cable) {
    // the sound devices are opened on their own thread so the capture and playback threads can all use them
    string result = null;
    var opener = new Thread(() => result = Open(speakers, microphone, cable));
    opener.SetApartmentState(ApartmentState.MTA);
    opener.Start();
    opener.Join();
    return result;
  }

  static string Open(string speakers, string microphone, string cable) {
    try {
      if (string.Equals(speakers, cable, StringComparison.OrdinalIgnoreCase)) throw new Exception("the speakers are set to the virtual cable, so its own sound would loop back into it");
      var cableStream = MixStream.Open(cable, true, false);
      var laptopStream = MixStream.Open(speakers, false, true);
      var microphoneStream = MixStream.Open(microphone, false, false);
      int rate = cableStream.Rate;
      microphoneQueue = new MixQueue(rate * 15 / 100, rate * 5 / 100);
      laptopQueue = new MixQueue(rate * 15 / 100, rate * 3 / 100);
      details = "cable " + cableStream.Rate + " Hz " + cableStream.Channels + "ch, speakers " + laptopStream.Rate + " Hz " + laptopStream.Channels + "ch, microphone " + microphoneStream.Rate + " Hz " + microphoneStream.Channels + "ch";
      failure = null;
      running = true;
      threads.Clear();
      threads.Add(new Thread(() => Guard(() => Capture(laptopStream, laptopQueue, rate, false), "laptop sound")));
      threads.Add(new Thread(() => Guard(() => Capture(microphoneStream, microphoneQueue, rate, true), "microphone")));
      threads.Add(new Thread(() => Guard(() => Play(cableStream), "virtual cable")));
      foreach (var thread in threads) { thread.IsBackground = true; thread.SetApartmentState(ApartmentState.MTA); thread.Start(); }
      return "";
    }
    catch (Exception error) { running = false; return error.Message; }
  }

  public static void Stop() {
    running = false;
    foreach (var thread in threads) thread.Join(2000);
    threads.Clear();
  }

  static void Guard(Action work, string part) {
    try { work(); }
    catch (Exception error) { failure = part + ": " + error.Message; running = false; }
  }

  // windows hands over the laptop sound already turned down by the laptop's volume. this is how much to turn it back up, so the stream
  // gets the same loudness whatever the laptop is set to. speakers with their own hardware volume aren't turned down, so they need nothing
  static float VolumeBoost(MixStream stream) {
    if (stream.Volume == null) return 1f;
    uint support;
    if (stream.Volume.QueryHardwareSupport(out support) >= 0 && (support & 1) != 0) return 1f;
    float decibels;
    if (stream.Volume.GetMasterVolumeLevel(out decibels) < 0 || decibels >= 0) return 1f;
    return (float)Math.Pow(10, Math.Min(-decibels, 60) / 20);
  }

  // reads a device and queues it as one channel at the output's rate. speakers are averaged, for a microphone the loudest channel is used
  static void Capture(MixStream stream, MixQueue queue, int outputRate, bool pickLoudest) {
    Guid captureId = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
    object captureObject;
    MixStream.Check(stream.Client.GetService(ref captureId, out captureObject), "getting the capture service");
    var capture = (IMixCaptureClient)captureObject;
    MixStream.Check(stream.Client.Start(), "starting the capture");

    var bytes = new byte[0];
    var mono = new float[0];
    var output = new float[0];
    var loudness = new double[stream.Channels];
    int sampleBytes = stream.BlockAlign / stream.Channels;
    double position = 0;
    float previous = 0;
    float boost = VolumeBoost(stream), boostNow = boost;
    int checks = 0;
    while (running) {
      Thread.Sleep(5);
      if (++checks % 40 == 0) boost = VolumeBoost(stream);
      uint packet;
      while (running && capture.GetNextPacketSize(out packet) >= 0 && packet > 0) {
        IntPtr data;
        uint frames, flags;
        ulong devicePosition, clockPosition;
        if (capture.GetBuffer(out data, out frames, out flags, out devicePosition, out clockPosition) < 0) break;
        int count = (int)frames, size = count * stream.BlockAlign;
        if (bytes.Length < size) bytes = new byte[size];
        if ((flags & 2) != 0) Array.Clear(bytes, 0, size); else Marshal.Copy(data, bytes, 0, size);
        capture.ReleaseBuffer(frames);

        if (mono.Length < count) mono = new float[count];
        int loudest = 0;
        for (int channel = 1; channel < stream.Channels; channel++) if (loudness[channel] > loudness[loudest] * 1.5) loudest = channel;
        for (int frame = 0; frame < count; frame++) {
          float sum = 0, picked = 0;
          for (int channel = 0; channel < stream.Channels; channel++) {
            float sample = stream.ReadSample(bytes, frame * stream.BlockAlign + channel * sampleBytes);
            sum += sample;
            if (channel == loudest) picked = sample;
            loudness[channel] = loudness[channel] * 0.9999 + sample * sample;
          }
          boostNow += (boost - boostNow) * 0.001f;
          mono[frame] = (pickLoudest ? picked : sum / stream.Channels) * boostNow;
        }

        int needed = (int)((long)count * outputRate / stream.Rate) + 2;
        if (output.Length < needed) output = new float[needed];
        int made = ChangeRate(mono, count, (double)stream.Rate / outputRate, ref position, ref previous, output);
        queue.Add(output, made);
      }
    }
    stream.Client.Stop();
  }

  // changes a block to the output's rate by sliding between neighbouring samples. position and previous carry over to the next block
  static int ChangeRate(float[] input, int count, double step, ref double position, ref float previous, float[] output) {
    int made = 0;
    while (position < count) {
      int index = (int)position;
      float before = index == 0 ? previous : input[index - 1];
      float part = (float)(position - index);
      output[made++] = before * (1 - part) + input[index] * part;
      position += step;
    }
    position -= count;
    if (count > 0) previous = input[count - 1];
    return made;
  }

  // every few milliseconds, mixes whatever the microphone has delivered with the laptop sound and plays it into the cable
  static void Play(MixStream stream) {
    Guid renderId = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
    object renderObject;
    MixStream.Check(stream.Client.GetService(ref renderId, out renderObject), "getting the playback service");
    var render = (IMixRenderClient)renderObject;
    uint bufferFrames;
    MixStream.Check(stream.Client.GetBufferSize(out bufferFrames), "reading the buffer size");

    var microphone = new float[0];
    var laptop = new float[0];
    var bytes = new byte[0];
    int sampleBytes = stream.BlockAlign / stream.Channels;
    // levels glide to where they should be, so muting doesn't click and the laptop sound fades over about a second and a half
    float microphoneNow = 0f, laptopNow = LaptopLevel;
    float microphoneGlide = 1f - (float)Math.Exp(-1.0 / (stream.Rate * 0.02)), laptopGlide = 1f - (float)Math.Exp(-1.0 / (stream.Rate * 0.5));
    bool started = false;
    while (running) {
      Thread.Sleep(5);
      // wait for a little sound to build up first, so playback doesn't keep running dry
      if (!started) {
        if (microphoneQueue.Count < stream.Rate / 25) continue;
        MixStream.Check(stream.Client.Start(), "starting playback");
        started = true;
      }
      uint padding;
      if (stream.Client.GetCurrentPadding(out padding) < 0) continue;
      // never let more than about 80 ms wait in the cable, so the sound stays close to the picture
      int room = Math.Min((int)(bufferFrames - padding), stream.Rate * 8 / 100 - (int)padding);
      int count = Math.Min(room, microphoneQueue.Count);
      if (count <= 0) continue;
      if (microphone.Length < count) { microphone = new float[count]; laptop = new float[count]; }
      microphoneQueue.Take(microphone, count);
      laptopQueue.Take(laptop, count);
      int size = count * stream.BlockAlign;
      if (bytes.Length < size) bytes = new byte[size];
      float microphoneLevel = MicrophoneMuted ? 0f : MicrophoneLevel, laptopLevel = MicrophoneMuted ? LaptopLevelWhenMuted : LaptopLevel;
      for (int frame = 0; frame < count; frame++) {
        microphoneNow += (microphoneLevel - microphoneNow) * microphoneGlide;
        laptopNow += (laptopLevel - laptopNow) * laptopGlide;
        float mixed = microphone[frame] * microphoneNow + laptop[frame] * laptopNow;
        for (int channel = 0; channel < stream.Channels; channel++) stream.WriteSample(bytes, frame * stream.BlockAlign + channel * sampleBytes, mixed);
      }
      IntPtr data;
      if (render.GetBuffer((uint)count, out data) < 0) continue;
      Marshal.Copy(bytes, 0, data, size);
      render.ReleaseBuffer((uint)count, 0);
    }
    if (started) stream.Client.Stop();
  }
}
'@

[AudioMixer]::LaptopLevel = $config.laptopSoundPercent / 100
[AudioMixer]::LaptopLevelWhenMuted = $config.laptopSoundPercentWhenMuted / 100
[AudioMixer]::MicrophoneLevel = $config.microphonePercent / 100
$problem = [AudioMixer]::Start((Get-WindowsName $deviceConfig.speakers), (Get-WindowsName $deviceConfig.microphone), (Get-WindowsName $cableId))
if ($problem) {
  Write-MixLog "could not start: $problem"
  exit 1
}
Write-MixLog "started ($([AudioMixer]::Details)), laptop sound $($config.laptopSoundPercent) percent ($($config.laptopSoundPercentWhenMuted) while muted), microphone $($config.microphonePercent) percent"
# the mixer sends the microphone now, so windows must not send it as well or it would be heard twice
& $svclPath /SetListenToThisDevice $deviceConfig.microphone 0

$stopSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $audioMixStopName)
$muteSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $audioMixMuteName)
$readySignal = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $audioMixReadyName)
while (-not $stopSignal.WaitOne(200)) {
  [AudioMixer]::MicrophoneMuted = $muteSignal.WaitOne(0)
  if ([AudioMixer]::Failure) {
    Write-MixLog "stopped working: $([AudioMixer]::Failure)"
    # keep the microphone going the old way so the stream isn't left silent
    if ((Test-Path $streamActivePath) -and -not $muteSignal.WaitOne(0)) { & $svclPath /SetListenToThisDevice $deviceConfig.microphone 1 }
    break
  }
}
[AudioMixer]::Stop()
[Environment]::Exit(0)
