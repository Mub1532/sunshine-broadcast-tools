param([string]$applyFrom, [switch]$renewLauncher, [switch]$repair)

. "$PSScriptRoot\utils.ps1"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  $launcherPath = Join-Path $appDir 'Sunshine Broadcast Tools.exe'
  try {
    if (Test-Path $launcherPath) { Start-Process $launcherPath 'setup.ps1' }
    else { Start-Process conhost.exe "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs }
  }
  catch {}
  exit
}

function Write-Utf8File([string]$path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Update-SunshineConf([string]$mode, [string]$audioSink, $options) {
  $wanted = [ordered]@{}
  if ($options.disableInput) { $wanted.keyboard = 'disabled'; $wanted.mouse = 'disabled'; $wanted.controller = 'disabled' }
  if ($options.vigemDriver) { $wanted.gamepad_driver = 'vigembus' }
  if ($options.disableSteamAudio) { $wanted.install_steam_audio_drivers = 'disabled' }
  $confPath = Join-Path $sunshineConfigDir 'sunshine.conf'
  $keptLines = @()
  if (Test-Path $confPath) {
    Copy-Item $confPath "$confPath.bak" -Force
    foreach ($line in Get-Content $confPath) {
      if ($line -match '^\s*(audio_sink|virtual_sink|external_audio)\s*=') { continue }
      if ($line -match '^\s*(\w+)\s*=' -and $wanted.Contains($Matches[1])) { continue }
      if ($line -match '^\s*global_prep_cmd\s*=\s*(.+)$') {
        $otherCommands = @(($Matches[1] | ConvertFrom-Json) | Where-Object { $_.do -notmatch '(stream|broadcast)\.ps1' })
        if ($otherCommands.Count) { $keptLines += 'global_prep_cmd = ' + (ConvertTo-Json -InputObject $otherCommands -Compress -Depth 3) }
        continue
      }
      $keptLines += $line
    }
  }
  if ($mode -eq 'broadcast') {
    $keptLines += "audio_sink = $audioSink"
    $keptLines += "virtual_sink = $audioSink"
    $keptLines += "external_audio = enabled"
  }
  foreach ($setting in $wanted.GetEnumerator()) { $keptLines += "$($setting.Key) = $($setting.Value)" }
  Write-Utf8File $confPath (($keptLines -join "`r`n") + "`r`n")
}

function Update-SunshineApps([string]$mode, [bool]$removeOthers) {
  $appsPath = Join-Path $sunshineConfigDir 'apps.json'
  $apps = [pscustomobject]@{ env = [pscustomobject]@{}; apps = @() }
  if (Test-Path $appsPath) {
    Copy-Item $appsPath "$appsPath.bak" -Force
    $apps = Get-Content $appsPath -Raw | ConvertFrom-Json
  }

  $broadcastApp = [pscustomobject][ordered]@{
    'name'       = $scriptConfig.appName
    'image-path' = Join-Path $repoDir 'images\desktop-broadcast.png'
    'prep-cmd'   = @([pscustomobject][ordered]@{
        do       = "`"$runnerPath`" broadcast.ps1 start"
        undo     = Get-HiddenCommand 'broadcast.ps1' 'release'
        elevated = $false
      })
    'detached'   = @((Get-HiddenCommand 'broadcast.ps1' 'guard'), (Get-HiddenCommand 'webcam-overlay.ps1'))
  }
  $desktopApp = [pscustomobject][ordered]@{
    'name'       = 'Desktop'
    'image-path' = 'desktop.png'
    'prep-cmd'   = $broadcastApp.'prep-cmd'
    'detached'   = @(Get-HiddenCommand 'broadcast.ps1' 'guard')
  }
  $modeApp = if ($mode -eq 'casting') { $desktopApp } else { $broadcastApp }
  $otherApps = @($apps.apps | Where-Object { -not $removeOthers -and $_.name -notin $scriptConfig.appName, $modeApp.name })
  $otherApps = @($otherApps | ForEach-Object {
      if ($_.name -eq 'Desktop') { [pscustomobject][ordered]@{ 'name' = 'Desktop'; 'image-path' = 'desktop.png' } } else { $_ }
    })
  $apps.apps = $otherApps + $modeApp
  Write-Utf8File $appsPath (ConvertTo-Json $apps -Depth 6)
}

function Install-Runner {
  $buildDir = Join-Path $env:TEMP 'sunshine-broadcast-runner'
  New-Item $buildDir -ItemType Directory -Force | Out-Null
  $sourcePath = Join-Path $buildDir 'runner.cs'
  Write-Utf8File $sourcePath @'
using System;
using System.Diagnostics;
using System.IO;

static class Runner {
  static int Main(string[] args) {
    if (args.Length == 0) return 1;
    string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, args[0]);
    string extra = string.Join(" ", args, 1, args.Length - 1);
    var process = Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + extra) {
      UseShellExecute = false,
      CreateNoWindow = true
    });
    process.WaitForExit();
    return process.ExitCode;
  }
}
'@
  $compiler = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  try {
    $compilerOutput = & $compiler /nologo /target:winexe "/out:$runnerPath" $sourcePath 2>&1
    if ($LASTEXITCODE) { throw "Could not build the hidden runner: $($compilerOutput -join ' ')" }
  }
  finally { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-SunshineService {
  if (Get-Service $serviceName -ErrorAction SilentlyContinue) { return }
  $installScript = Join-Path $env:ProgramFiles 'Sunshine\scripts\install-service.bat'
  if (Test-Path $installScript) { Start-Process cmd.exe "/c `"$installScript`"" -WindowStyle Hidden -Wait }
  if (-not (Get-Service $serviceName -ErrorAction SilentlyContinue)) { throw 'The Sunshine service is missing. Reinstall Sunshine as administrator.' }
}

function Get-ExcludedPortRanges([string]$protocol) {
  foreach ($line in (netsh int ipv4 show excludedportrange protocol=$protocol)) {
    if ($line -match '^\s*(\d+)\s+(\d+)\s*(\*)?\s*$') {
      [pscustomobject]@{ Start = [int]$Matches[1]; End = [int]$Matches[2]; Ours = [bool]$Matches[3] }
    }
  }
}

function Test-PortsFree([int]$basePort) {
  $first = $basePort - 5
  $last = $basePort + 21
  foreach ($protocol in 'tcp', 'udp') {
    foreach ($range in (Get-ExcludedPortRanges $protocol)) {
      if ($range.Ours -and $range.Start -eq $first -and $range.End -eq $last) { continue }
      if ($range.Start -le $last -and $range.End -ge $first) { return $false }
    }
  }
  $listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -ge $first -and $_.LocalPort -le $last -and $_.OwningProcess -notin @(Get-Process sunshine -ErrorAction SilentlyContinue).Id }
  -not $listening
}

function Set-SunshinePorts {
  $confPath = Join-Path $sunshineConfigDir 'sunshine.conf'
  $basePort = 47989
  if (Test-Path $confPath) {
    $portLine = Select-String -Path $confPath -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -Last 1
    if ($portLine) { $basePort = [int]$portLine.Matches[0].Groups[1].Value }
  }
  if (Test-PortsFree $basePort) { return }

  $newPort = 48089..48989 | Where-Object { $_ % 100 -eq 89 } | Where-Object { Test-PortsFree $_ } | Select-Object -First 1
  if (-not $newPort) { throw 'No free ports found for Sunshine.' }
  $lines = @(if (Test-Path $confPath) { Get-Content $confPath | Where-Object { $_ -notmatch '^\s*port\s*=' } })
  Write-Utf8File $confPath ((($lines + "port = $newPort") -join "`r`n") + "`r`n")

  net stop winnat 2>&1 | Out-Null
  try {
    foreach ($protocol in 'tcp', 'udp') {
      netsh int ipv4 add excludedportrange protocol=$protocol startport=$($newPort - 5) numberofports=27 store=persistent | Out-Null
    }
  }
  finally { net start winnat 2>&1 | Out-Null }
}

function Add-FirewallRules {
  $sunshinePath = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'
  Get-NetFirewallRule -DisplayName 'Sunshine Broadcast' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName 'Sunshine Broadcast' -Direction Inbound -Program $sunshinePath -Action Allow -Profile Any | Out-Null
}

function Set-DefaultCredentials {
  $statePath = Join-Path $sunshineConfigDir 'sunshine_state.json'
  if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($state.username) { return }
  }
  & (Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe') --creds admin admin | Out-Null
}

function Grant-ServiceControl {
  $securityDescriptor = (sc.exe sdshow $serviceName | Where-Object { $_ }) -join ''
  $userAccess = '(A;;RPWPLC;;;IU)'
  if ($securityDescriptor -and -not $securityDescriptor.Contains($userAccess)) {
    sc.exe sdset $serviceName ($securityDescriptor -replace '^D:', "D:$userAccess") | Out-Null
  }
  sc.exe config $serviceName start= demand | Out-Null
}

$sunshineIconPath = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'

function Install-Launcher {
  $launcherPath = Join-Path $appDir 'Sunshine Broadcast Tools.exe'
  if ((Test-Path $launcherPath) -and (Get-AuthenticodeSignature $launcherPath).Status -eq 'Valid' -and (Get-Item $launcherPath).VersionInfo.FileVersion -eq $launcherVersion) { return $launcherPath }

  $buildDir = Join-Path $env:TEMP 'sunshine-broadcast-launcher'
  New-Item $buildDir -ItemType Directory -Force | Out-Null
  $sourcePath = Join-Path $buildDir 'launcher.cs'
  $manifestPath = Join-Path $buildDir 'launcher.manifest'
  Write-Utf8File $sourcePath @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Sunshine Broadcast Tools")]
[assembly: AssemblyProduct("Sunshine Broadcast Tools")]
[assembly: AssemblyCompany("Mubashar Khan")]
[assembly: AssemblyFileVersion("2.0.1.0")]

static class Launcher {
  [STAThread]
  static void Main(string[] args) {
    if (args.Length == 0) return;
    if (args[0] == "--tray") { RunTray(args); return; }
    string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, args[0]);
    string extra = string.Join(" ", args, 1, args.Length - 1);
    StartHidden(script, extra);
  }

  static void StartHidden(string script, string extra) {
    Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + extra) {
      UseShellExecute = false,
      CreateNoWindow = true
    });
  }

  static void RunTray(string[] args) {
    string label = args.Length > 1 ? args[1] : "End Stream";
    string question = args.Length > 2 ? args[2] : "End the stream?";
    string title = args.Length > 3 ? args[3] : "Sunshine Broadcast";
    bool created;
    var closeSignal = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, @"Local\SunshineBroadcastOverlayClose", out created);

    Application.EnableVisualStyles();
    var menu = new ContextMenuStrip();
    var tray = new NotifyIcon { Text = title, Icon = RecordIcon(), ContextMenuStrip = menu, Visible = true };
    menu.Items.Add(label, null, (sender, e) => {
      using (var owner = new Form { TopMost = true, ShowInTaskbar = false, Opacity = 0, Size = new Size(1, 1), StartPosition = FormStartPosition.CenterScreen }) {
        owner.Show();
        owner.Activate();
        if (MessageBox.Show(owner, question, title, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
      }
      StartHidden(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "end-stream.ps1"), "-fromOverlay");
      Application.Exit();
    });
    tray.MouseUp += (sender, e) => {
      if (e.Button == MouseButtons.Left) {
        typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(tray, null);
      }
    };

    int ticks = 0;
    var timer = new System.Windows.Forms.Timer { Interval = 300 };
    timer.Tick += (sender, e) => {
      if (closeSignal.WaitOne(0)) { Application.Exit(); return; }
      if (ticks++ < 40 && Promote()) { tray.Visible = false; tray.Visible = true; }
    };
    timer.Start();
    Application.Run();
    tray.Visible = false;
    tray.Dispose();
  }

  static bool Promote() {
    bool changed = false;
    try {
      using (var root = Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings")) {
        if (root == null) return false;
        foreach (var name in root.GetSubKeyNames()) {
          using (var key = root.OpenSubKey(name, true)) {
            if (key == null) continue;
            var path = key.GetValue("ExecutablePath") as string;
            if (path == null || !path.EndsWith(@"\Sunshine Broadcast Tools.exe", StringComparison.OrdinalIgnoreCase)) continue;
            var promoted = key.GetValue("IsPromoted");
            if (promoted is int && (int)promoted == 1) continue;
            key.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
            changed = true;
          }
        }
      }
    }
    catch { }
    return changed;
  }

  static Icon RecordIcon() {
    var bitmap = new Bitmap(32, 32);
    using (var graphics = Graphics.FromImage(bitmap)) {
      graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
      graphics.FillEllipse(Brushes.White, 3, 3, 26, 26);
      using (var red = new SolidBrush(Color.FromArgb(220, 40, 40))) graphics.FillEllipse(red, 6, 6, 20, 20);
    }
    return Icon.FromHandle(bitmap.GetHicon());
  }
}
'@
  Write-Utf8File $manifestPath @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false" /></requestedPrivileges></security>
  </trustInfo>
</assembly>
'@
  $iconPath = Join-Path $buildDir 'launcher.ico'
  Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class IconBuilder {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern uint PrivateExtractIcons(string file, int index, int width, int height, IntPtr[] icons, uint[] ids, uint count, uint flags);
  [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);

  public static void Save(string exePath, string icoPath) {
    int[] sizes = { 256, 64, 48, 32, 24, 16 };
    var images = new byte[sizes.Length][];
    for (int i = 0; i < sizes.Length; i++) {
      var handles = new IntPtr[1];
      PrivateExtractIcons(exePath, 0, sizes[i], sizes[i], handles, null, 1, 0);
      using (var bitmap = Icon.FromHandle(handles[0]).ToBitmap())
      using (var png = new MemoryStream()) {
        bitmap.Save(png, ImageFormat.Png);
        images[i] = png.ToArray();
      }
      DestroyIcon(handles[0]);
    }
    using (var writer = new BinaryWriter(File.Create(icoPath))) {
      writer.Write((short)0); writer.Write((short)1); writer.Write((short)sizes.Length);
      int offset = 6 + 16 * sizes.Length;
      for (int i = 0; i < sizes.Length; i++) {
        writer.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i])); writer.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
        writer.Write((byte)0); writer.Write((byte)0); writer.Write((short)1); writer.Write((short)32);
        writer.Write(images[i].Length); writer.Write(offset);
        offset += images[i].Length;
      }
      foreach (var image in images) writer.Write(image);
    }
  }
}
'@
  [IconBuilder]::Save($sunshineIconPath, $iconPath)
  $compiler = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  $compilerOutput = & $compiler /nologo /target:winexe "/out:$launcherPath" "/win32manifest:$manifestPath" "/win32icon:$iconPath" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $sourcePath 2>&1
  if ($LASTEXITCODE) { throw "Could not build the launcher: $($compilerOutput -join ' ')" }

  foreach ($store in 'Root', 'TrustedPublisher') {
    Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object Subject -eq 'CN=Mubashar Khan' | Remove-Item
  }
  $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Mubashar Khan' -FriendlyName 'Mubashar Khan Sunshine Broadcast Tools Certificate' `
    -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter (Get-Date).AddYears(30)
  try {
    $publicPath = Join-Path $buildDir 'publisher.cer'
    Export-Certificate -Cert $certificate -FilePath $publicPath | Out-Null
    foreach ($store in 'Root', 'TrustedPublisher') { Import-Certificate -FilePath $publicPath -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null }
    $signature = Set-AuthenticodeSignature $launcherPath $certificate -HashAlgorithm SHA256
    if ($signature.Status -ne 'Valid') { throw "Could not sign the launcher: $($signature.StatusMessage)" }
  }
  finally {
    Remove-Item "Cert:\LocalMachine\My\$($certificate.Thumbprint)" -DeleteKey
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $launcherPath
}

function New-LauncherShortcut([string]$name, [string]$script, [string]$tip, [string]$icon) {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut((Join-Path (Join-Path $env:PUBLIC 'Desktop') "$name.lnk"))
  $shortcut.TargetPath = Install-Launcher
  $shortcut.Arguments = $script
  $shortcut.WorkingDirectory = $appDir
  $shortcut.Description = $tip
  $shortcut.IconLocation = $icon
  $shortcut.Save()
}

function New-DesktopShortcut([string]$name, [string]$script, [string]$tip, [string]$icon, [string]$folder = (Join-Path $env:PUBLIC 'Desktop'), [string]$arguments = '') {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut((Join-Path $folder "$name.lnk"))
  $shortcut.TargetPath = Join-Path $env:windir 'System32\conhost.exe'
  $shortcut.Arguments = (Get-HiddenCommand $script $arguments) -replace '^conhost\.exe ', ''
  $shortcut.Description = $tip
  $shortcut.IconLocation = $icon
  $shortcut.Save()
}

if ($renewLauncher) {
  Start-Sleep -Seconds 2
  Remove-Item (Join-Path $appDir 'Sunshine Broadcast Tools.exe') -Force -ErrorAction SilentlyContinue
  try { Install-Launcher | Out-Null; exit 0 } catch { exit 1 }
}

function New-RepairRequest {
  $saved = Get-Content $deviceConfigPath -Raw | ConvertFrom-Json
  $repairMode = if ($saved.mode -eq 'casting') { 'casting' } else { 'broadcast' }
  $sink = ''
  if ($repairMode -eq 'broadcast') {
    $csvPath = Join-Path $env:TEMP 'sunshine-broadcast-repair.csv'
    Start-Process $svclPath "/scomma `"$csvPath`" /Columns `"Name,Type,Direction,Device Name`"" -Wait -WindowStyle Hidden
    $cableDevice = Import-Csv $csvPath -ErrorAction SilentlyContinue |
      Where-Object { $_.Type -eq 'Device' -and $_.Direction -eq 'Render' -and $_.Name -eq 'CABLE Input' -and $_.'Device Name' -match 'VB-Audio' } | Select-Object -First 1
    Remove-Item $csvPath -ErrorAction SilentlyContinue
    if ($cableDevice) { $sink = "$($cableDevice.Name) ($($cableDevice.'Device Name'))" }
  }
  [pscustomobject]@{ mode = $repairMode; audioSink = $sink; options = $saved.options }
}

if ($applyFrom -or $repair) {
  try {
    $request = if ($repair) { New-RepairRequest } else { Get-Content $applyFrom -Raw | ConvertFrom-Json }
    $failures = @()
    $steps = [ordered]@{
      'Service'   = { Install-SunshineService; Grant-ServiceControl }
      'Firewall'  = { Add-FirewallRules }
      'Login'     = { if ($request.options.defaultLogin) { Set-DefaultCredentials } }
      'Ports'     = { Set-SunshinePorts }
      'Config'    = { Update-SunshineConf $request.mode $request.audioSink $request.options }
      'Apps'      = { Install-Runner; Update-SunshineApps $request.mode ([bool]$request.options.removeOtherApps) }
      'Shortcuts' = {
        New-LauncherShortcut $scriptConfig.startShortcut 'start-stream.ps1' $scriptConfig.startShortcutTip "$sunshineIconPath,0"
        $startupFolder = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
        New-DesktopShortcut 'Sunshine Broadcast Cleanup' 'broadcast.ps1' 'Restore audio if a stream was left running' "$env:windir\System32\shell32.dll,27" $startupFolder 'cleanup'
      }
    }
    foreach ($step in $steps.GetEnumerator()) {
      try { & $step.Value }
      catch { $failures += "$($step.Key): $($_.Exception.Message)" }
    }
    if ($failures) { throw ($failures -join "`n") }
    if ($repair) { exit 0 }

    if ((Get-Service $serviceName).Status -eq 'Running') {
      Restart-Service $serviceName -Force
      exit 3
    }
    exit 0
  }
  catch {
    if ($applyFrom) { Set-Content "$applyFrom.err" $_.Exception.Message }
    exit 1
  }
}

$setupShown = $null
if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\SunshineBroadcastSetupShown', [ref]$setupShown)) { [void]$setupShown.Set() }
$restoreScript = Join-Path $env:ProgramData 'sunshine-broadcast-tools-backup\restore.ps1'
$menuChoices = @($scriptConfig.broadcastSetupButton, $scriptConfig.castingSetupButton)
if (Test-Path $restoreScript) { $menuChoices += $scriptConfig.undoButton }
$menuChoice = Show-Choice $scriptConfig.setupMenuText $menuChoices
if ($menuChoice -eq 2) {
  Start-Process conhost.exe "--headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$restoreScript`""
  exit
}
if ($menuChoice -lt 0) { exit }
$mode = if ($menuChoice -eq 1) { 'casting' } else { 'broadcast' }

function Switch-ModeConfig([string]$fromMode, [string]$toMode) {
  $modeFiles = @{ 'sunshine.conf' = $sunshineConfigDir; 'apps.json' = $sunshineConfigDir; 'deviceConfig.json' = $appDir }
  $fromDir = Join-Path $repoDir "$fromMode-config-backup"
  New-Item $fromDir -ItemType Directory -Force | Out-Null
  foreach ($file in $modeFiles.GetEnumerator()) {
    $source = Join-Path $file.Value $file.Key
    if (Test-Path $source) { Copy-Item $source $fromDir -Force }
  }
  $toDir = Join-Path $repoDir "$toMode-config-backup"
  if (Test-Path $toDir) {
    foreach ($file in $modeFiles.GetEnumerator()) {
      $saved = Join-Path $toDir $file.Key
      if (Test-Path $saved) { Copy-Item $saved $file.Value -Force }
    }
  }
}

$previousConfig = if (Test-Path $deviceConfigPath) { Get-Content $deviceConfigPath -Raw | ConvertFrom-Json } else { $null }
$previousMode = if ($previousConfig.mode) { $previousConfig.mode } elseif ($previousConfig.speakers) { 'broadcast' } else { '' }
if ($previousMode -and $previousMode -ne $mode) {
  try { Switch-ModeConfig $previousMode $mode }
  catch { Show-Message (Format-Text $messageConfig.saveFailed @{ error = $_.Exception.Message }) 'Error' | Out-Null; exit 1 }
}

function Test-CableInstalled {
  [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*VB-Audio Virtual Cable*')
}

function Get-LibmpvUrl {
  try {
    $release = Invoke-RestMethod 'https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest' -UseBasicParsing
    $url = ($release.assets | Where-Object name -match '^mpv-dev-x86_64-\d{8}-git-.+\.7z$' | Select-Object -First 1).browser_download_url
    if ($url) { return $url }
  }
  catch {}
  $latestPage = Invoke-WebRequest 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/latest' -UseBasicParsing
  $tag = ($latestPage.BaseResponse.ResponseUri.AbsoluteUri -split '/tag/')[-1]
  $assetsPage = Invoke-WebRequest "https://github.com/shinchiro/mpv-winbuild-cmake/releases/expanded_assets/$tag" -UseBasicParsing
  if ($assetsPage.Content -match 'href="(/shinchiro/mpv-winbuild-cmake/releases/download/[^"]*/mpv-dev-x86_64-\d{8}-git-[^"/]+\.7z)"') {
    return "https://github.com$($Matches[1])"
  }
  throw 'Could not find the latest libmpv download.'
}

function Install-BroadcastComponents {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $downloadDir = Join-Path $env:TEMP 'sunshine-broadcast-components'
  Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item $downloadDir -ItemType Directory | Out-Null
  try {
    if (-not (Test-Path $svclPath)) {
      Invoke-WebRequest 'https://www.nirsoft.net/utils/svcl-x64.zip' -OutFile "$downloadDir\svcl.zip" -UseBasicParsing
      Expand-Archive "$downloadDir\svcl.zip" "$downloadDir\svcl" -Force
      Copy-Item "$downloadDir\svcl\svcl.exe" $svclPath
    }
    if (-not (Test-Path $libmpvPath)) {
      Invoke-WebRequest (Get-LibmpvUrl) -OutFile "$downloadDir\mpv.7z" -UseBasicParsing
      New-Item "$downloadDir\mpv" -ItemType Directory | Out-Null
      tar.exe -xf "$downloadDir\mpv.7z" -C "$downloadDir\mpv"
      if ($LASTEXITCODE) { throw 'Could not extract libmpv (needs Windows 11).' }
      Copy-Item (Get-ChildItem "$downloadDir\mpv" -Recurse -Filter 'libmpv-2.dll' | Select-Object -First 1).FullName $libmpvPath
    }
    Unblock-File $svclPath, $libmpvPath
    if (-not (Test-CableInstalled)) {
      Invoke-WebRequest 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip' -OutFile "$downloadDir\vbcable.zip" -UseBasicParsing
      Expand-Archive "$downloadDir\vbcable.zip" "$downloadDir\vbcable" -Force
      Start-Process "$downloadDir\vbcable\VBCABLE_Setup_x64.exe" -WorkingDirectory "$downloadDir\vbcable" -Wait
      if (Test-CableInstalled) { return 'restart' }
      throw 'VB-CABLE was not installed.'
    }
    'ready'
  }
  finally { Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($mode -eq 'broadcast' -and (-not (Test-Path $svclPath) -or -not (Test-Path $libmpvPath) -or -not (Test-CableInstalled))) {
  if ((Show-Choice $messageConfig.componentsNeeded @($messageConfig.componentsInstall, $messageConfig.componentsCancel)) -ne 0) { exit }
  $progressForm = Show-Progress $messageConfig.componentsInstalling
  $progressForm.TopMost = $false
  try { $componentsResult = Install-BroadcastComponents }
  catch {
    $progressForm.Close()
    Show-Message (Format-Text $messageConfig.componentsFailed @{ error = $_.Exception.Message }) 'Error' | Out-Null
    exit 1
  }
  $progressForm.Close()
  if ($componentsResult -eq 'restart') {
    Show-Message $messageConfig.componentsRestart | Out-Null
    exit
  }
}

$audioSink = ''
if ($mode -eq 'broadcast') {
  $deviceCsv = Join-Path $env:TEMP 'sunshine-broadcast-devices.csv'
  Start-Process $svclPath "/scomma `"$deviceCsv`" /Columns `"Name,Type,Direction,Device Name,Default,Command-Line Friendly ID`"" -Wait -WindowStyle Hidden
  $audioDevices = @(Import-Csv $deviceCsv -ErrorAction SilentlyContinue | Where-Object Type -eq 'Device')
  Remove-Item $deviceCsv -ErrorAction SilentlyContinue
  if (-not $audioDevices) {
    Show-Message $messageConfig.devicesUnreadable 'Error' | Out-Null
    exit 1
  }

  $physicalDevices = $audioDevices | Where-Object { "$($_.Name) $($_.'Device Name')" -notmatch 'VB-Audio|Steam Streaming' }
  $speakers = @($physicalDevices | Where-Object Direction -eq 'Render')
  $microphones = @($physicalDevices | Where-Object Direction -eq 'Capture')
  $cameras = @(Get-PnpDevice -PresentOnly -Status OK -ErrorAction SilentlyContinue |
    Where-Object Class -in 'Camera', 'Image' | Select-Object -ExpandProperty FriendlyName)

  $cable = $audioDevices | Where-Object { $_.Direction -eq 'Render' -and $_.Name -eq 'CABLE Input' -and $_.'Device Name' -match 'VB-Audio' } |
    Select-Object -First 1
  $audioSink = if ($cable) { "$($cable.Name) ($($cable.'Device Name'))" } else { '' }

  $savedDevices = if (Test-Path $deviceConfigPath) { Get-Content $deviceConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
  if ($speakers) {
    $defaultSpeakers = if ($savedDevices.speakers -in $speakers.'Command-Line Friendly ID') { $savedDevices.speakers } else { $speakers[0].'Command-Line Friendly ID' }
    & $svclPath /SetDefault $defaultSpeakers all
  }
  if ($microphones -and $savedDevices.microphone -in $microphones.'Command-Line Friendly ID') {
    & $svclPath /SetDefault $savedDevices.microphone all
  }
}

$savedConfig = if (Test-Path $deviceConfigPath) { Get-Content $deviceConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$setupPath = $PSCommandPath

function Get-SavedIndex($devices, [string]$savedId) {
  for ($index = 0; $index -lt $devices.Count; $index++) {
    if ($devices[$index].'Command-Line Friendly ID' -eq $savedId) { return $index }
  }
  0
}

$setupForm = New-Object System.Windows.Forms.Form -Property @{
  Text            = if ($mode -eq 'casting') { $scriptConfig.castingSetupTitle } else { $scriptConfig.setupTitle }
  StartPosition   = 'CenterScreen'
  FormBorderStyle = 'FixedDialog'
  MaximizeBox     = $false
  MinimizeBox     = $false
  Font            = New-Object System.Drawing.Font('Segoe UI', 10)
}
$script:nextTop = 16

function Add-Row($control, [int]$rowHeight, [int]$left = 20, [int]$width = 460) {
  $control.SetBounds($left, $script:nextTop, $width, $control.Height)
  $setupForm.Controls.Add($control)
  $script:nextTop += $rowHeight
  $control
}

function Add-Label([string]$caption) {
  Add-Row (New-Object System.Windows.Forms.Label -Property @{ Text = $caption; Height = 22 }) 24 | Out-Null
}

function Add-DropDown([string[]]$items, [int]$selectedIndex) {
  $dropDown = Add-Row (New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList' }) 40
  if ($items) {
    $dropDown.Items.AddRange([object[]]$items)
    $dropDown.SelectedIndex = [Math]::Min($selectedIndex, $items.Count - 1)
  }
  $dropDown
}

function Get-DeviceLabel($device) { "$($device.Name) ($($device.'Device Name'))" }

if ($mode -eq 'casting') {
  Add-Row (New-Object System.Windows.Forms.Label -Property @{ Text = $scriptConfig.castingDescription; Height = 40 }) 48 | Out-Null
}
else {
  Add-Label $scriptConfig.speakersLabel
  $speakerList = Add-DropDown ($speakers | ForEach-Object { Get-DeviceLabel $_ }) (Get-SavedIndex $speakers $savedConfig.speakers)
  Add-Label $scriptConfig.microphoneLabel
  $microphoneList = Add-DropDown ($microphones | ForEach-Object { Get-DeviceLabel $_ }) (Get-SavedIndex $microphones $savedConfig.microphone)
  Add-Label $scriptConfig.cameraLabel
  $cameraList = Add-DropDown $cameras ([Math]::Max(0, [Array]::IndexOf($cameras, [string]$savedConfig.camera)))

  Add-Label $scriptConfig.audioSinkLabel
  Add-Row (New-Object System.Windows.Forms.TextBox -Property @{ Text = $audioSink; ReadOnly = $true }) 0 20 370 | Out-Null
  $copyButton = Add-Row (New-Object System.Windows.Forms.Button -Property @{ Text = $scriptConfig.copyButton }) 44 400 80
  $copyButton.Enabled = [bool]$audioSink
  $copyButton.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($audioSink) })
}

$optionBoxes = [ordered]@{}
foreach ($option in 'defaultLogin', 'removeOtherApps', 'disableInput', 'vigemDriver', 'disableSteamAudio') {
  $checked = [bool]$savedConfig.options.$option
  $optionBoxes[$option] = Add-Row (New-Object System.Windows.Forms.CheckBox -Property @{ Text = $scriptConfig."$($option)Option"; Checked = $checked; AutoSize = $true }) 26
}
$script:nextTop += 10

$warnings = @()
if ($mode -eq 'broadcast' -and -not $cable) { $warnings += $messageConfig.cableMissing }
if ($mode -eq 'broadcast' -and -not (Test-Path $libmpvPath)) { $warnings += $messageConfig.mpvMissing }
if ($warnings) {
  Add-Row (New-Object System.Windows.Forms.Label -Property @{ Text = $warnings -join "`n"; ForeColor = 'Firebrick'; Height = 44 }) 50 | Out-Null
}

function Get-Options {
  $options = [ordered]@{}
  foreach ($box in $optionBoxes.GetEnumerator()) { $options[$box.Key] = $box.Value.Checked }
  $options
}

function Set-DefaultDevices {
  if ($mode -ne 'broadcast' -or $speakerList.SelectedIndex -lt 0 -or $microphoneList.SelectedIndex -lt 0) { return }
  & $svclPath /SetDefault $speakers[$speakerList.SelectedIndex].'Command-Line Friendly ID' all
  & $svclPath /SetDefault $microphones[$microphoneList.SelectedIndex].'Command-Line Friendly ID' all
}

function Save-Config {
  if ($mode -eq 'casting') {
    try {
      [ordered]@{
        mode       = 'casting'
        speakers   = $savedConfig.speakers
        microphone = $savedConfig.microphone
        camera     = $savedConfig.camera
        options    = Get-Options
      } | ConvertTo-Json | Set-Content $deviceConfigPath -Encoding UTF8
      return $true
    }
    catch {
      Show-Message (Format-Text $messageConfig.saveFailed @{ error = $_.Exception.Message }) 'Error' | Out-Null
      return $false
    }
  }
  if ($speakerList.SelectedIndex -lt 0 -or $microphoneList.SelectedIndex -lt 0) {
    Show-Message $messageConfig.selectDevices 'Warning' | Out-Null
    return $false
  }
  try {
    [ordered]@{
      mode       = 'broadcast'
      speakers   = $speakers[$speakerList.SelectedIndex].'Command-Line Friendly ID'
      microphone = $microphones[$microphoneList.SelectedIndex].'Command-Line Friendly ID'
      camera     = [string]$cameraList.SelectedItem
      options    = Get-Options
    } | ConvertTo-Json | Set-Content $deviceConfigPath -Encoding UTF8
    Set-DefaultDevices
    $true
  }
  catch {
    Show-Message (Format-Text $messageConfig.saveFailed @{ error = $_.Exception.Message }) 'Error' | Out-Null
    $false
  }
}

function Invoke-Apply {
  if (-not (Save-Config)) { return }
  $requestPath = Join-Path $env:TEMP 'sunshine-broadcast-apply.json'
  $errorPath = "$requestPath.err"
  Remove-Item $errorPath -ErrorAction SilentlyContinue
  @{ mode = $mode; audioSink = $audioSink; options = Get-Options } | ConvertTo-Json | Set-Content $requestPath

  try {
    $applyProcess = Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$setupPath`" -applyFrom `"$requestPath`"" `
      -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    Start-Sleep -Seconds 3
    Set-DefaultDevices
    switch ($applyProcess.ExitCode) {
      0 { Show-Message "$($messageConfig.applied)`n`n$($scriptConfig.messagesNote)" | Out-Null; $setupForm.Close() }
      3 { Show-Message "$($messageConfig.applied)`n`n$($messageConfig.restarted)`n`n$($scriptConfig.messagesNote)" | Out-Null; $setupForm.Close() }
      default {
        $details = if (Test-Path $errorPath) { Get-Content $errorPath -Raw } else { '' }
        Show-Message (Format-Text $messageConfig.applyFailed @{ error = $details }) 'Error' | Out-Null
      }
    }
  }
  catch {
    Show-Message $messageConfig.adminRequired 'Warning' | Out-Null
  }
  Remove-Item $requestPath, $errorPath -ErrorAction SilentlyContinue
}

$applyButton = Add-Row (New-Object System.Windows.Forms.Button -Property @{ Text = $scriptConfig.applyButton; Height = 34 }) 50 300 180
$applyButton.Add_Click({
  if ($mode -eq 'casting' -or $audioSink) { Invoke-Apply }
  elseif (Save-Config) { Show-Message "$($messageConfig.saved)`n`n$($scriptConfig.messagesNote)" | Out-Null; $setupForm.Close() }
})

$formWidth = [Math]::Max(500, ($optionBoxes.Values | ForEach-Object { $_.Right } | Measure-Object -Maximum).Maximum + 20)
$setupForm.ClientSize = New-Object System.Drawing.Size($formWidth, $script:nextTop)
$setupForm.Add_Shown({
  Show-OnTop $setupForm
  $setupForm.TopMost = $false
  $setupShown = $null
  if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\SunshineBroadcastSetupShown', [ref]$setupShown)) { [void]$setupShown.Set() }
})
[void]$setupForm.ShowDialog()
