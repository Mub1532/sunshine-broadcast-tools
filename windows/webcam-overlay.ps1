. "$PSScriptRoot\utils.ps1"

$overlayLock = New-Object System.Threading.Mutex($false, 'Local\SunshineBroadcastOverlay')
if (-not $overlayLock.WaitOne(0)) { exit }
if (-not (Test-Path $libmpvPath)) { exit 1 }

$deviceConfig = Get-Content $deviceConfigPath -Raw | ConvertFrom-Json
$cameraName = $deviceConfig.camera
if (-not $cameraName) {
  $cameraName = Get-PnpDevice -PresentOnly -Status OK -ErrorAction SilentlyContinue |
    Where-Object Class -in 'Camera', 'Image' | Select-Object -First 1 -ExpandProperty FriendlyName
}
if (-not $cameraName) { exit 1 }

$widthRatio = 0.20
$marginLeft = 16
$marginBottom = 24

Import-CSharp 'webcam-overlay' -references System.Windows.Forms, System.Drawing -source @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class Mpv {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("libmpv-2.dll")] static extern IntPtr mpv_create();
  [DllImport("libmpv-2.dll")] static extern int mpv_initialize(IntPtr handle);
  [DllImport("libmpv-2.dll")] static extern int mpv_set_option_string(IntPtr handle, byte[] name, byte[] value);
  [DllImport("libmpv-2.dll")] static extern int mpv_command(IntPtr handle, IntPtr[] args);
  [DllImport("libmpv-2.dll")] static extern IntPtr mpv_get_property_string(IntPtr handle, byte[] name);
  [DllImport("libmpv-2.dll")] static extern void mpv_free(IntPtr data);
  [DllImport("libmpv-2.dll")] static extern IntPtr mpv_wait_event(IntPtr handle, double timeout);
  [DllImport("libmpv-2.dll")] static extern void mpv_terminate_destroy(IntPtr handle);

  const int EventShutdown = 1;
  const int EventEndFile = 7;

  static byte[] Utf8(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }

  public static void Load(string dllPath) { LoadLibrary(dllPath); }

  public static IntPtr Create(IntPtr window) {
    var handle = mpv_create();
    if (handle == IntPtr.Zero) return handle;
    SetOption(handle, "wid", window.ToInt64().ToString());
    SetOption(handle, "profile", "low-latency");
    SetOption(handle, "untimed", "yes");
    SetOption(handle, "cache", "no");
    SetOption(handle, "idle", "yes");
    SetOption(handle, "demuxer-lavf-probesize", "32");
    SetOption(handle, "demuxer-lavf-analyzeduration", "0");
    SetOption(handle, "vf", "hflip");
    SetOption(handle, "audio", "no");
    SetOption(handle, "osc", "no");
    SetOption(handle, "osd-level", "0");
    SetOption(handle, "input-default-bindings", "no");
    SetOption(handle, "input-vo-keyboard", "no");
    SetOption(handle, "input-cursor", "no");
    SetOption(handle, "cursor-autohide", "no");
    SetOption(handle, "keepaspect", "no");
    SetOption(handle, "d3d11-flip", "no");
    if (mpv_initialize(handle) < 0) { mpv_terminate_destroy(handle); return IntPtr.Zero; }
    return handle;
  }

  static void SetOption(IntPtr handle, string name, string value) {
    mpv_set_option_string(handle, Utf8(name), Utf8(value));
  }

  public static void Open(IntPtr handle, string url) {
    var parts = new[] { "loadfile", url };
    var args = new IntPtr[parts.Length + 1];
    for (int index = 0; index < parts.Length; index++) {
      var bytes = Utf8(parts[index]);
      args[index] = Marshal.AllocHGlobal(bytes.Length);
      Marshal.Copy(bytes, 0, args[index], bytes.Length);
    }
    mpv_command(handle, args);
    for (int index = 0; index < parts.Length; index++) Marshal.FreeHGlobal(args[index]);
  }

  public static double GetAspectRatio(IntPtr handle) {
    var value = mpv_get_property_string(handle, Utf8("video-params/aspect"));
    if (value == IntPtr.Zero) return 0;
    var bytes = new System.Collections.Generic.List<byte>();
    for (int offset = 0; ; offset++) {
      var current = Marshal.ReadByte(value, offset);
      if (current == 0) break;
      bytes.Add(current);
    }
    mpv_free(value);
    double ratio;
    return double.TryParse(Encoding.UTF8.GetString(bytes.ToArray()), System.Globalization.NumberStyles.Float,
      System.Globalization.CultureInfo.InvariantCulture, out ratio) ? ratio : 0;
  }

  public static void Stop(IntPtr handle) {
    var bytes = Utf8("stop");
    var args = new IntPtr[2];
    args[0] = Marshal.AllocHGlobal(bytes.Length);
    Marshal.Copy(bytes, 0, args[0], bytes.Length);
    mpv_command(handle, args);
    Marshal.FreeHGlobal(args[0]);
  }

  public static bool HasEnded(IntPtr handle) {
    while (true) {
      var mpvEvent = mpv_wait_event(handle, 0);
      int eventId = Marshal.ReadInt32(mpvEvent);
      if (eventId == 0) return false;
      if (eventId == EventShutdown || eventId == EventEndFile) return true;
    }
  }

  public static void Destroy(IntPtr handle) { if (handle != IntPtr.Zero) mpv_terminate_destroy(handle); }
}

public class OverlayButton : Form {
  public readonly Button Button = new Button();
  readonly ToolTip toolTip = new ToolTip { ShowAlways = true };

  public OverlayButton(string text, string fontName, float fontSize, Size size) {
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    Size = size;

    Button.Text = text;
    Button.Dock = DockStyle.Fill;
    Button.TabStop = false;
    Button.FlatStyle = FlatStyle.Flat;
    Button.FlatAppearance.BorderSize = 0;
    Button.ForeColor = Color.White;
    Button.Font = new Font(fontName, fontSize, fontName == "Segoe UI" ? FontStyle.Bold : FontStyle.Regular);
    Button.Padding = Padding.Empty;
    Button.TextAlign = ContentAlignment.MiddleCenter;
    Button.UseCompatibleTextRendering = true;
    Button.Cursor = Cursors.Hand;
    Controls.Add(Button);
  }

  public void SetLook(Color color, string tip) {
    BackColor = color;
    Button.BackColor = color;
    toolTip.SetToolTip(Button, tip);
  }

  protected override bool ShowWithoutActivation { get { return true; } }

  protected override CreateParams CreateParams {
    get {
      var parameters = base.CreateParams;
      parameters.ExStyle |= 0x80 | 0x08000000;
      return parameters;
    }
  }
}

public class OverlayForm : Form {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
  [DllImport("user32.dll")] static extern bool EnableWindow(IntPtr window, bool enable);

  const int ResizeBorder = 10;
  const int CornerSize = ResizeBorder + 6;
  const int MinWidth = 240;
  const int ButtonInset = 6;
  const int ButtonGap = 4;
  const string CameraGlyph = "\uE714";
  const string MicrophoneGlyph = "\uE720";
  static readonly Color Red = Color.FromArgb(185, 45, 45);
  static readonly Color Grey = Color.FromArgb(60, 60, 60);
  const uint ChildWindow = 5;

  readonly OverlayButton endButton;
  readonly OverlayButton cameraButton;
  readonly OverlayButton microphoneButton;
  readonly string[] tips;
  readonly string cameraName;
  readonly Timer mpvTimer = new Timer { Interval = 250 };
  IntPtr player = IntPtr.Zero;
  bool aspectKnown;
  bool videoDisabled;
  bool cameraOn = true;
  bool microphoneOn = true;

  public double AspectRatio = 16.0 / 9.0;
  public Func<bool> ShouldClose;
  public event EventHandler EndRequested;
  public event EventHandler VideoStarted;
  public Action<bool> MicrophoneToggled;

  public OverlayForm(string cameraName, string endLabel, string[] tips) {
    this.cameraName = cameraName;
    this.tips = tips;
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    BackColor = Color.Black;

    string iconFont = IsFontInstalled("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
    endButton = new OverlayButton(endLabel, "Segoe UI", 8.5f, new Size(92, 24));
    cameraButton = new OverlayButton(CameraGlyph, iconFont, 11f, new Size(34, 30));
    microphoneButton = new OverlayButton(MicrophoneGlyph, iconFont, 11f, new Size(34, 30));
    endButton.SetLook(Red, endLabel);
    UpdateToggleLooks();

    endButton.Button.Click += (sender, args) => { if (EndRequested != null) EndRequested(this, EventArgs.Empty); };
    cameraButton.Button.Click += (sender, args) => ToggleCamera();
    microphoneButton.Button.Click += (sender, args) => ToggleMicrophone();
    Shown += (sender, args) => StartPlayer();
    LocationChanged += (sender, args) => PlaceButtons();
    FormClosed += (sender, args) => { mpvTimer.Stop(); Mpv.Destroy(player); };
    mpvTimer.Tick += (sender, args) => CheckPlayer();
  }

  static bool IsFontInstalled(string name) {
    foreach (var family in FontFamily.Families) if (family.Name == name) return true;
    return false;
  }

  void UpdateToggleLooks() {
    cameraButton.SetLook(cameraOn ? Grey : Red, cameraOn ? tips[0] : tips[1]);
    microphoneButton.SetLook(microphoneOn ? Grey : Red, microphoneOn ? tips[2] : tips[3]);
  }

  void StartPlayer() {
    endButton.Show(this);
    cameraButton.Show(this);
    microphoneButton.Show(this);
    PlaceButtons();
    player = Mpv.Create(Handle);
    if (player == IntPtr.Zero) { Close(); return; }
    OpenCamera();
    mpvTimer.Start();
  }

  void OpenCamera() {
    Mpv.HasEnded(player);
    videoDisabled = false;
    Mpv.Open(player, "av://dshow:video=" + cameraName);
  }

  void ToggleCamera() {
    cameraOn = !cameraOn;
    if (cameraOn) OpenCamera(); else Mpv.Stop(player);
    UpdateToggleLooks();
    Invalidate();
  }

  void ToggleMicrophone() {
    microphoneOn = !microphoneOn;
    UpdateToggleLooks();
    if (MicrophoneToggled != null) MicrophoneToggled(microphoneOn);
  }

  void CheckPlayer() {
    bool ended = Mpv.HasEnded(player);
    if ((ShouldClose != null && ShouldClose()) || (ended && cameraOn)) { Close(); return; }
    if (!cameraOn) return;

    if (!videoDisabled) {
      var videoWindow = GetWindow(Handle, ChildWindow);
      if (videoWindow != IntPtr.Zero) { EnableWindow(videoWindow, false); videoDisabled = true; }
    }

    if (aspectKnown) return;
    var ratio = Mpv.GetAspectRatio(player);
    if (ratio < 1.0 || ratio > 2.5) return;
    aspectKnown = true;
    AspectRatio = ratio;
    int newHeight = (int)(Width / AspectRatio);
    SetBounds(Left, Bottom - newHeight, Width, newHeight);
    if (VideoStarted != null) VideoStarted(this, EventArgs.Empty);
  }

  protected override CreateParams CreateParams {
    get {
      var parameters = base.CreateParams;
      parameters.ExStyle |= 0x80;
      parameters.Style |= 0x02000000;
      return parameters;
    }
  }

  void PlaceButtons() {
    endButton.Location = new Point(Right - endButton.Width - ButtonInset, Top + ButtonInset);
    cameraButton.Location = new Point(Right - cameraButton.Width - ButtonInset, Bottom - cameraButton.Height - ButtonInset);
    microphoneButton.Location = new Point(cameraButton.Left - microphoneButton.Width - ButtonGap, cameraButton.Top);
  }

  protected override void OnPaintBackground(PaintEventArgs args) {
    if (player == IntPtr.Zero || !cameraOn) base.OnPaintBackground(args);
  }

  protected override void OnResize(EventArgs args) {
    base.OnResize(args);
    if (endButton != null) PlaceButtons();
  }

  int HitTest(Point point) {
    int width = ClientSize.Width, height = ClientSize.Height;
    bool left = point.X < ResizeBorder, right = point.X >= width - ResizeBorder;
    bool top = point.Y < ResizeBorder, bottom = point.Y >= height - ResizeBorder;
    bool nearLeft = point.X < CornerSize, nearRight = point.X >= width - CornerSize;
    bool nearTop = point.Y < CornerSize, nearBottom = point.Y >= height - CornerSize;

    if ((top && nearLeft) || (left && nearTop)) return 13;
    if ((top && nearRight) || (right && nearTop)) return 14;
    if ((bottom && nearLeft) || (left && nearBottom)) return 16;
    if ((bottom && nearRight) || (right && nearBottom)) return 17;
    if (left) return 10;
    if (right) return 11;
    if (top) return 12;
    if (bottom) return 15;
    return 2;
  }

  void KeepAspectRatio(ref Rect bounds, int edge) {
    int maxWidth = Screen.FromHandle(Handle).WorkingArea.Width / 2;
    bool draggingTopOrBottom = edge == 3 || edge == 6;
    int width = draggingTopOrBottom ? (int)((bounds.Bottom - bounds.Top) * AspectRatio) : bounds.Right - bounds.Left;
    width = Math.Max(MinWidth, Math.Min(maxWidth, width));
    int height = (int)(width / AspectRatio);

    if (edge == 1 || edge == 4 || edge == 7) bounds.Left = bounds.Right - width; else bounds.Right = bounds.Left + width;
    if (edge == 3 || edge == 4 || edge == 5) bounds.Top = bounds.Bottom - height; else bounds.Bottom = bounds.Top + height;
  }

  protected override void WndProc(ref Message message) {
    const int WmNcHitTest = 0x84;
    const int WmSizing = 0x214;

    if (message.Msg == WmNcHitTest) {
      long position = message.LParam.ToInt64();
      var point = PointToClient(new Point((short)(position & 0xFFFF), (short)((position >> 16) & 0xFFFF)));
      message.Result = (IntPtr)HitTest(point);
      return;
    }

    if (message.Msg == WmSizing) {
      var bounds = (Rect)Marshal.PtrToStructure(message.LParam, typeof(Rect));
      KeepAspectRatio(ref bounds, message.WParam.ToInt32());
      Marshal.StructureToPtr(bounds, message.LParam, false);
      message.Result = (IntPtr)1;
      return;
    }

    base.WndProc(ref message);
  }
}
'@

[Mpv]::Load($libmpvPath)
[Mpv]::SetProcessDPIAware() | Out-Null

$closeSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $overlayCloseName)

$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$overlayWidth = [int]($workArea.Width * $widthRatio)
$overlayHeight = [int]($overlayWidth * 9 / 16)

$buttonTips = [string[]]@($scriptConfig.cameraOff, $scriptConfig.cameraOn, $scriptConfig.micMute, $scriptConfig.micUnmute)
$overlay = New-Object OverlayForm -ArgumentList ($cameraName -replace '"', ''), $scriptConfig.endButton, $buttonTips
$overlay.SetBounds($workArea.Left + $marginLeft, $workArea.Bottom - $overlayHeight - $marginBottom, $overlayWidth, $overlayHeight)
$overlay.ShouldClose = [Func[bool]]{ $closeSignal.WaitOne(0) }
$overlay.Add_VideoStarted({
  $script:overlayReady = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $overlayReadyName)
})
$overlay.MicrophoneToggled = [Action[bool]]{
  param($microphoneOn)
  & $svclPath /SetListenToThisDevice $deviceConfig.microphone ([int]$microphoneOn)
}
$overlay.Add_EndRequested({
  if ((Show-Message $scriptConfig.endConfirm 'Question' 'YesNo') -eq 'Yes') { Stop-Stream }
})

[System.Windows.Forms.Application]::Run($overlay)
