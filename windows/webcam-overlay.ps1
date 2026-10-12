. "$PSScriptRoot\utils.ps1"

$overlayLock = New-Object System.Threading.Mutex($false, 'Local\SunshineBroadcastOverlay')
if (-not $overlayLock.WaitOne(0)) { exit }
if (-not (Test-Path $libmpvPath)) { exit 1 }

$cameraName = (Get-Content $deviceConfigPath -Raw | ConvertFrom-Json).camera
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

public class EndButtonForm : Form {
  public readonly Button EndButton = new Button();

  public EndButtonForm(string label) {
    var red = Color.FromArgb(185, 45, 45);
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    BackColor = red;
    Size = new Size(92, 24);

    EndButton.Text = label;
    EndButton.Dock = DockStyle.Fill;
    EndButton.TabStop = false;
    EndButton.FlatStyle = FlatStyle.Flat;
    EndButton.FlatAppearance.BorderSize = 0;
    EndButton.BackColor = red;
    EndButton.ForeColor = Color.White;
    EndButton.Font = new Font("Segoe UI", 8.5f, FontStyle.Bold);
    EndButton.Cursor = Cursors.Hand;
    Controls.Add(EndButton);
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
  const uint ChildWindow = 5;

  readonly EndButtonForm endButtonForm;
  readonly string cameraName;
  readonly Timer mpvTimer = new Timer { Interval = 250 };
  IntPtr player = IntPtr.Zero;
  bool aspectKnown;
  bool videoDisabled;

  public double AspectRatio = 16.0 / 9.0;
  public Func<bool> ShouldClose;
  public event EventHandler EndRequested;
  public event EventHandler VideoStarted;

  public OverlayForm(string cameraName, string endLabel) {
    this.cameraName = cameraName;
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    BackColor = Color.Black;

    endButtonForm = new EndButtonForm(endLabel);
    endButtonForm.EndButton.Click += (sender, args) => { if (EndRequested != null) EndRequested(this, EventArgs.Empty); };
    Shown += (sender, args) => StartPlayer();
    LocationChanged += (sender, args) => PlaceEndButton();
    FormClosed += (sender, args) => { mpvTimer.Stop(); Mpv.Destroy(player); };
    mpvTimer.Tick += (sender, args) => CheckPlayer();
  }

  void StartPlayer() {
    endButtonForm.Show(this);
    PlaceEndButton();
    player = Mpv.Create(Handle);
    if (player == IntPtr.Zero) { Close(); return; }
    Mpv.Open(player, "av://dshow:video=" + cameraName);
    mpvTimer.Start();
  }

  void CheckPlayer() {
    if ((ShouldClose != null && ShouldClose()) || Mpv.HasEnded(player)) { Close(); return; }

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

  void PlaceEndButton() {
    endButtonForm.Location = new Point(Right - endButtonForm.Width - ButtonInset, Top + ButtonInset);
  }

  protected override void OnPaintBackground(PaintEventArgs args) {
    if (player == IntPtr.Zero) base.OnPaintBackground(args);
  }

  protected override void OnResize(EventArgs args) {
    base.OnResize(args);
    if (endButtonForm != null) PlaceEndButton();
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

$overlay = New-Object OverlayForm -ArgumentList ($cameraName -replace '"', ''), $scriptConfig.endButton
$overlay.SetBounds($workArea.Left + $marginLeft, $workArea.Bottom - $overlayHeight - $marginBottom, $overlayWidth, $overlayHeight)
$overlay.ShouldClose = [Func[bool]]{ $closeSignal.WaitOne(0) }
$overlay.Add_VideoStarted({
  $script:overlayReady = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $overlayReadyName)
})
$overlay.Add_EndRequested({
  if ((Show-Message $scriptConfig.endConfirm 'Question' 'YesNo') -eq 'Yes') { Stop-Stream }
})

[System.Windows.Forms.Application]::Run($overlay)
