. "$PSScriptRoot\utils.ps1"

$overlayLock = New-Object System.Threading.Mutex($false, 'Local\SunshineBroadcastOverlay')
if (-not $overlayLock.WaitOne(0)) { exit }

$vlcPath = Get-VlcPath
if (-not $vlcPath) { exit 1 }

$cameraName = (Get-Content $deviceConfigPath -Raw | ConvertFrom-Json).camera
if (-not $cameraName) {
  $cameraName = Get-PnpDevice -PresentOnly -Status OK -ErrorAction SilentlyContinue |
    Where-Object Class -in 'Camera', 'Image' | Select-Object -First 1 -ExpandProperty FriendlyName
}
if (-not $cameraName) { exit 1 }

$widthRatio = 0.20
$marginLeft = 16
$marginBottom = 24

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class VlcWindow {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }

  delegate bool EnumWindowsCallback(IntPtr window, IntPtr data);

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr data);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
  [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr child, IntPtr parent);
  [DllImport("user32.dll")] static extern bool EnableWindow(IntPtr window, bool enable);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int x, int y, int width, int height, bool repaint);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLong(IntPtr window, int index, IntPtr value);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int maxLength);

  const int GwlStyle = -16;
  const int WsChild = 0x40000000;
  const int WsVisible = 0x10000000;

  static bool IsMainWindow(IntPtr window) {
    var title = new StringBuilder(256);
    GetWindowText(window, title, title.Capacity);
    return title.ToString().IndexOf("media player", StringComparison.OrdinalIgnoreCase) >= 0;
  }

  static bool BelongsTo(IntPtr window, int processId) {
    uint ownerId;
    GetWindowThreadProcessId(window, out ownerId);
    return ownerId == (uint)processId;
  }

  public static IntPtr FindVideoWindow(int processId) {
    var found = IntPtr.Zero;
    EnumWindows((window, data) => {
      if (BelongsTo(window, processId) && IsWindowVisible(window) && !IsMainWindow(window)) { found = window; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static void HideMainWindow(int processId) {
    EnumWindows((window, data) => {
      if (BelongsTo(window, processId) && IsMainWindow(window)) ShowWindow(window, 0);
      return true;
    }, IntPtr.Zero);
  }

  public static void Embed(IntPtr child, IntPtr parent) {
    SetWindowLong(child, GwlStyle, new IntPtr(WsChild | WsVisible));
    SetParent(child, parent);
    EnableWindow(child, false);
  }
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
  const int ResizeBorder = 10;
  const int CornerSize = ResizeBorder + 6;
  const int MinWidth = 240;
  const int ButtonInset = 6;

  readonly EndButtonForm endButtonForm;
  readonly int vlcProcessId;
  IntPtr videoWindow = IntPtr.Zero;

  public double AspectRatio = 16.0 / 9.0;
  public event EventHandler EndRequested;

  public OverlayForm(int vlcProcessId, string endLabel) {
    this.vlcProcessId = vlcProcessId;
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    BackColor = Color.Black;

    endButtonForm = new EndButtonForm(endLabel);
    endButtonForm.EndButton.Click += (sender, args) => { if (EndRequested != null) EndRequested(this, EventArgs.Empty); };
    Shown += (sender, args) => { endButtonForm.Show(this); PlaceEndButton(); };
    LocationChanged += (sender, args) => PlaceEndButton();

    var vlcWatcher = new Timer { Interval = 1000 };
    vlcWatcher.Tick += (sender, args) => {
      try { if (Process.GetProcessById(vlcProcessId).HasExited) Close(); } catch { Close(); }
    };
    vlcWatcher.Start();
  }

  public void AttachVideo(IntPtr window) {
    videoWindow = window;
    VlcWindow.Embed(window, Handle);
    FitVideo();
  }

  protected override CreateParams CreateParams {
    get {
      var parameters = base.CreateParams;
      parameters.ExStyle |= 0x80;
      return parameters;
    }
  }

  void PlaceEndButton() {
    endButtonForm.Location = new Point(Right - endButtonForm.Width - ButtonInset, Top + ButtonInset);
  }

  void FitVideo() {
    if (videoWindow != IntPtr.Zero) {
      VlcWindow.MoveWindow(videoWindow, 0, 0, Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height), true);
    }
    PlaceEndButton();
  }

  protected override void OnResize(EventArgs args) {
    base.OnResize(args);
    FitVideo();
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

  void KeepAspectRatio(ref VlcWindow.Rect bounds, int edge) {
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
      var bounds = (VlcWindow.Rect)Marshal.PtrToStructure(message.LParam, typeof(VlcWindow.Rect));
      KeepAspectRatio(ref bounds, message.WParam.ToInt32());
      Marshal.StructureToPtr(bounds, message.LParam, false);
      message.Result = (IntPtr)1;
      return;
    }

    base.WndProc(ref message);
  }
}
'@

[VlcWindow]::SetProcessDPIAware() | Out-Null

$vlcArguments = @(
  'dshow://', "`":dshow-vdev=$cameraName`"", ':dshow-adev=none', ':live-caching=0',
  '--qt-start-minimized', '--no-embedded-video', '--no-video-deco', '--no-video-title-show',
  '--no-qt-video-autoresize', '--no-mouse-events', '--video-filter=transform', '--transform-type=hflip'
) -join ' '
$vlcProcess = Start-Process $vlcPath $vlcArguments -WorkingDirectory (Split-Path $vlcPath) -PassThru

$videoWindow = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 75 -and $videoWindow -eq [IntPtr]::Zero; $attempt++) {
  Start-Sleep -Milliseconds 200
  $videoWindow = [VlcWindow]::FindVideoWindow($vlcProcess.Id)
}
if ($videoWindow -eq [IntPtr]::Zero) { exit 1 }

$aspectRatio = 16.0 / 9.0
$lastWidth = 0
$stableCount = 0
for ($attempt = 0; $attempt -lt 25 -and $stableCount -lt 2; $attempt++) {
  Start-Sleep -Milliseconds 200
  $videoBounds = New-Object VlcWindow+Rect
  [VlcWindow]::GetWindowRect($videoWindow, [ref]$videoBounds) | Out-Null
  $videoWidth = $videoBounds.Right - $videoBounds.Left
  $videoHeight = $videoBounds.Bottom - $videoBounds.Top
  if ($videoWidth -le 100 -or $videoHeight -le 50) { continue }

  if ($videoWidth -eq $lastWidth) { $stableCount++ } else { $stableCount = 0; $lastWidth = $videoWidth }
  $measuredRatio = $videoWidth / $videoHeight
  if ($measuredRatio -ge 1.0 -and $measuredRatio -le 2.5) { $aspectRatio = $measuredRatio }
}

[VlcWindow]::HideMainWindow($vlcProcess.Id)

$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$overlayWidth = [int]($workArea.Width * $widthRatio)
$overlayHeight = [int]($overlayWidth / $aspectRatio)

$overlay = New-Object OverlayForm -ArgumentList $vlcProcess.Id, $scriptConfig.endButton
$overlay.AspectRatio = $aspectRatio
$overlay.SetBounds($workArea.Left + $marginLeft, $workArea.Bottom - $overlayHeight - $marginBottom, $overlayWidth, $overlayHeight)
$overlay.Add_Shown({
  $overlay.AttachVideo($videoWindow)
  $script:overlayReady = New-Object System.Threading.EventWaitHandle($true, 'ManualReset', $overlayReadyName)
})
$overlay.Add_EndRequested({
  if ((Show-Message $scriptConfig.endConfirm 'Question' 'YesNo') -eq 'Yes') { Stop-Stream }
})

[System.Windows.Forms.Application]::Run($overlay)
