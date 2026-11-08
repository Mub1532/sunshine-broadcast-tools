# floating end stream button for casting, can be dragged and resized
. "$PSScriptRoot\utils.ps1"

$buttonLock = New-Object System.Threading.Mutex($false, 'Local\SunshineBroadcastEndButton')
if (-not $buttonLock.WaitOne(0)) { exit }
Enable-SharpText

Import-CSharp 'end-button' @'
using System;
using System.Drawing;
using System.Windows.Forms;

public class FlatEndButton : Button {
  public FlatEndButton() { SetStyle(ControlStyles.Selectable, false); }
  protected override bool ShowFocusCues { get { return false; } }
}

public class EndButtonForm : Form {
  const int Edge = 4;
  readonly FlatEndButton button;
  Point dragStart;
  bool dragging;
  bool moved;
  public event EventHandler EndRequested;

  public EndButtonForm(string label, float fontSize) {
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    BackColor = Color.FromArgb(185, 45, 45);
    Padding = new Padding(Edge);
    MinimumSize = new Size(70, 26);

    button = new FlatEndButton {
      Text = label,
      Dock = DockStyle.Fill,
      FlatStyle = FlatStyle.Flat,
      ForeColor = Color.White,
      BackColor = Color.FromArgb(185, 45, 45),
      Font = new Font("Segoe UI", fontSize, FontStyle.Bold),
      Cursor = Cursors.SizeAll
    };
    button.FlatAppearance.BorderSize = 0;
    button.FlatAppearance.BorderColor = Color.FromArgb(185, 45, 45);
    button.FlatAppearance.MouseOverBackColor = Color.FromArgb(205, 70, 70);
    button.FlatAppearance.MouseDownBackColor = Color.FromArgb(160, 35, 35);
    button.MouseDown += (sender, args) => { if (args.Button == MouseButtons.Left) { dragging = true; moved = false; dragStart = args.Location; } };
    button.MouseMove += (sender, args) => {
      if (!dragging) return;
      int dx = args.X - dragStart.X, dy = args.Y - dragStart.Y;
      if (!moved && Math.Abs(dx) + Math.Abs(dy) < 5) return;
      moved = true;
      Location = new Point(Left + dx, Top + dy);
    };
    button.MouseUp += (sender, args) => {
      bool wasClick = dragging && !moved;
      dragging = false;
      if (wasClick && EndRequested != null) EndRequested(this, EventArgs.Empty);
    };
    Controls.Add(button);
  }

  protected override bool ShowWithoutActivation { get { return true; } }

  protected override CreateParams CreateParams {
    get {
      var parameters = base.CreateParams;
      parameters.ExStyle |= 0x80;
      return parameters;
    }
  }

  protected override void WndProc(ref Message message) {
    if (message.Msg == 0x84) {
      long position = message.LParam.ToInt64();
      var point = PointToClient(new Point((short)(position & 0xFFFF), (short)((position >> 16) & 0xFFFF)));
      bool left = point.X < Edge, right = point.X >= ClientSize.Width - Edge;
      bool top = point.Y < Edge, bottom = point.Y >= ClientSize.Height - Edge;
      int hit = top && left ? 13 : top && right ? 14 : bottom && left ? 16 : bottom && right ? 17 :
        left ? 10 : right ? 11 : top ? 12 : bottom ? 15 : 2;
      message.Result = (IntPtr)hit;
      return;
    }
    base.WndProc(ref message);
  }
}
'@ @('System.Windows.Forms', 'System.Drawing')

$closeSignal = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $overlayCloseName)

$scale = Get-Scale
$buttonWidth = [int](100 * $scale)
$buttonHeight = [int](30 * $scale)
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$endForm = New-Object EndButtonForm -ArgumentList $scriptConfig.endButton, ([float]9)
$endForm.SetBounds($workArea.Left + [int](16 * $scale), $workArea.Bottom - $buttonHeight - [int](24 * $scale), $buttonWidth, $buttonHeight)
$endForm.Opacity = 0

$endForm.Add_EndRequested({
  if ((Show-Message $messageConfig.endConfirm 'Question' 'YesNo') -eq 'Yes') {
    Start-Hidden 'end-stream.ps1' '-fromOverlay'
    $endForm.Close()
  }
})

$watchTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 300 }
$watchTimer.Add_Tick({
  if ($closeSignal.WaitOne(0)) { $endForm.Close(); return }
  if ($endForm.Opacity -lt 1) {
    $startingSignal = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting($startingName, [ref]$startingSignal)) { $startingSignal.Dispose(); return }
    $endForm.Opacity = 1
  }
})
$endForm.Add_Shown({ $watchTimer.Start() })

[System.Windows.Forms.Application]::Run($endForm)
[Environment]::Exit(0)
