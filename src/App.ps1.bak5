$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$cfg = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$logFile = Join-Path $root 'logs\app.log'

if (-not ('FileItem' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;

public class FileItem : INotifyPropertyChanged {
    public string Name { get; set; }
    public string FullPath { get; set; }
    public string Badge { get; set; }
    public string BadgeColor { get; set; }
    public string SizeText { get; set; }
    public string CreatedText { get; set; }
    public bool IsDir { get; set; }
    public bool IsJpg { get; set; }
    public long Size { get; set; }
    public DateTime Created { get; set; }
    private object _thumb;
    public object Thumb {
        get { return _thumb; }
        set { _thumb = value; if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs("Thumb")); }
    }
    public event PropertyChangedEventHandler PropertyChanged;
}

public class ExifSession : IDisposable {
    private Process p;
    private StringBuilder err = new StringBuilder();
    private object gate = new object();
    private StreamWriter stdin;

    public ExifSession(string exe) {
        ProcessStartInfo psi = new ProcessStartInfo(exe, "-stay_open True -@ -");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        
        p = Process.Start(psi); stdin = new StreamWriter(p.StandardInput.BaseStream, new UTF8Encoding(false));
        p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) {
            if (e.Data != null) { lock (err) { err.AppendLine(e.Data); } }
        };
        p.BeginErrorReadLine();
    }

    public string Run(string[] args) {
        lock (gate) {
            lock (err) { err.Length = 0; }
            StringBuilder cmd = new StringBuilder();
            foreach (string a in args) { cmd.Append(a); cmd.Append('\n'); }
            cmd.Append("-execute\n");
            stdin.Write(cmd.ToString());
            stdin.Flush();
            StringBuilder sb = new StringBuilder();
            string line;
            while ((line = p.StandardOutput.ReadLine()) != null) {
                if (line == "{ready}") break;
                sb.Append(line); sb.Append('\n');
            }
            System.Threading.Thread.Sleep(20);
            return sb.ToString();
        }
    }

    public string LastError { get { lock (err) { return err.ToString().Trim(); } } }

    public void Dispose() {
        try {
            stdin.Write("-stay_open\nFalse\n-execute\n");
            stdin.Flush();
            if (!p.WaitForExit(2000)) p.Kill();
        } catch { }
    }
}
"@
}

# ----- Load window -----
$xaml = Get-Content (Join-Path $root 'src\MainWindow.xaml') -Raw
$win  = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]([xml]$xaml))
$names = 'tree','list','txtPath','txtStatus','txtName','txtTitle','txtSubject','txtAuthors','txtTags','txtComments','txtRating','sysInfo','btnSave','rbDetails','rbThumbs'
foreach ($n in $names) { Set-Variable -Name $n -Value $win.FindName($n) }
$txtName.IsReadOnly = $true
$txtComments.AcceptsReturn = $false
$btnSave.IsEnabled = $false

function Write-Log($msg) { try { Add-Content $logFile ("{0:s}  {1}" -f (Get-Date), $msg) } catch { } }
$win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-Log $e.Exception.ToString()
    $txtStatus.Text = 'Error: ' + $e.Exception.Message
    $e.Handled = $true
})

# ----- ExifTool session (stays open) -----
$script:et = New-Object ExifSession -ArgumentList $cfg.ExifToolPath

# ----- Helpers -----
$colors = @{ 'BAT'='#78909C'; 'LOG'='#D9D9D9'; 'CMD'='#78909C'; 'PS1'='#78909C' }
function Format-Size([long]$b) {
    if ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { "$b B" }
}

# ----- Thumbnails (background exiftool -> cache -> timer picks up) -----
$script:thumbProc = $null
$script:thumbDir = $null
$script:thumbPending = New-Object 'System.Collections.Generic.List[FileItem]'
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)

function Get-ThumbPath($it) {
    Join-Path $script:thumbDir ([IO.Path]::GetFileNameWithoutExtension($it.Name) + '.jpg')
}
function Read-Bitmap($path) {
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 100) { return $null }
        $ms = New-Object IO.MemoryStream (, $bytes)
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = 'OnLoad'
        $bi.StreamSource = $ms
        $bi.EndInit()
        $bi.Freeze()
        $ms.Dispose()
        return $bi
    } catch { return $null }
}
function Stop-Thumbs {
    $timer.Stop()
    if ($script:thumbProc -and -not $script:thumbProc.HasExited) { try { $script:thumbProc.Kill() } catch { } }
    $script:thumbProc = $null
    $script:thumbPending = New-Object 'System.Collections.Generic.List[FileItem]'
}
function Start-Thumbs($items, $path) {
    Stop-Thumbs
    $jpgs = @($items | Where-Object { $_.IsJpg })
    if ($jpgs.Count -eq 0) { return }
    $md5 = [Security.Cryptography.MD5]::Create()
    $h = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLower()))) -replace '-', '').Substring(0, 16)
    $script:thumbDir = Join-Path $root "cache\thumbs\$h"
    New-Item -ItemType Directory -Path $script:thumbDir -Force | Out-Null
    $need = New-Object 'System.Collections.Generic.List[string]'
    foreach ($it in $jpgs) {
        $tp = Get-ThumbPath $it
        $ok = $false
        if ([IO.File]::Exists($tp)) {
            $ok = ([IO.FileInfo]$tp).Length -gt 100 -and ([IO.File]::GetLastWriteTimeUtc($tp) -ge [IO.File]::GetLastWriteTimeUtc($it.FullPath))
        }
        if (-not $ok) { $need.Add($it.FullPath) }
        $script:thumbPending.Add($it)
    }
    if ($need.Count -gt 0) {
        $argFile = Join-Path $script:thumbDir '_args.txt'
        [IO.File]::WriteAllLines($argFile, $need, (New-Object Text.UTF8Encoding($false)))
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $cfg.ExifToolPath
        $psi.Arguments = '-charset filename=utf8 -b -ThumbnailImage -w! "' + $script:thumbDir + '\%f.jpg" -@ "' + $argFile + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:thumbProc = [Diagnostics.Process]::Start($psi)
    }
    $timer.Start()
}
$timer.Add_Tick({
    try {
        $exited = ($null -eq $script:thumbProc) -or $script:thumbProc.HasExited
        $remaining = New-Object 'System.Collections.Generic.List[FileItem]'
        foreach ($it in $script:thumbPending) {
            $tp = Get-ThumbPath $it
            $bmp = $null
            if ([IO.File]::Exists($tp)) { $bmp = Read-Bitmap $tp }
            if ($bmp) { $it.Thumb = $bmp }
            elseif (-not $exited) { $remaining.Add($it) }
            elseif ([IO.File]::Exists($tp)) { try { Remove-Item $tp -Force } catch { } }
        }
        $script:thumbPending = $remaining
        if ($exited -or $remaining.Count -eq 0) { $timer.Stop() }
    } catch { }
})

# ----- View switching -----
function Apply-View {
    $ic = [System.Windows.Controls.ItemsControl]
    if ($rbThumbs.IsChecked) {
        $list.View = $null
        $list.ItemsPanel = $win.FindResource('tilePanel')
        $list.ItemTemplate = $win.FindResource('tileTemplate')
        $list.ItemContainerStyle = $win.FindResource('tileStyle')
        [System.Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Disabled)
    } else {
        $list.ClearValue($ic::ItemsPanelProperty)
        $list.ClearValue($ic::ItemTemplateProperty)
        $list.ClearValue($ic::ItemContainerStyleProperty)
        $list.View = $win.FindResource('detailsView')
        [System.Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($list, [System.Windows.Controls.ScrollBarVisibility]::Auto)
    }
}

# ----- Tree / folder loading -----
function Add-Node($items, $path, $label) {
    $n = New-Object Windows.Controls.TreeViewItem
    $n.Header = $label
    $n.Tag = $path
    $n.Items.Add('...') | Out-Null
    $n.Add_Expanded({ param($s, $e) Expand-Node $s; $e.Handled = $true })
    $items.Add($n) | Out-Null
    return $n
}
function Expand-Node($n) {
    if ($n.Items.Count -eq 1 -and $n.Items[0] -is [string]) {
        $n.Items.Clear()
        try {
            foreach ($d in ([IO.Directory]::GetDirectories($n.Tag) | Sort-Object)) {
                Add-Node $n.Items $d ([IO.Path]::GetFileName($d)) | Out-Null
            }
        } catch { }
    }
}
function Load-Folder($path) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $txtPath.Text = $path
    $items = New-Object 'System.Collections.Generic.List[FileItem]'
    $total = 0L
    try {
        $di = New-Object IO.DirectoryInfo $path
        foreach ($d in $di.EnumerateDirectories()) {
            $i = New-Object FileItem
            $i.Name = $d.Name; $i.FullPath = $d.FullName; $i.IsDir = $true
            $i.Badge = 'FOLDER'; $i.BadgeColor = '#FFA726'; $i.Created = $d.CreationTime
            $i.SizeText = ''; $i.CreatedText = $d.CreationTime.ToString('dd/MM/yyyy HH:mm')
            $items.Add($i)
        }
        foreach ($f in $di.EnumerateFiles()) {
            $ext = $f.Extension.TrimStart('.').ToUpper()
            if (-not $ext) { $ext = 'FILE' }
            if ($ext.Length -gt 9) { $ext = $ext.Substring(0, 9) }
            $i = New-Object FileItem
            $i.Name = $f.Name; $i.FullPath = $f.FullName; $i.Size = $f.Length; $i.Created = $f.CreationTime
            $i.Badge = $ext
            $i.BadgeColor = if ($colors.ContainsKey($ext)) { $colors[$ext] } else { '#3B9AF5' }
            $i.IsJpg = ($ext -eq 'JPG' -or $ext -eq 'JPEG')
            $i.SizeText = Format-Size $f.Length
            $i.CreatedText = $f.CreationTime.ToString('dd/MM/yyyy HH:mm')
            $total += $f.Length
            $items.Add($i)
        }
        $txtStatus.Text = ('{0} items  |  {1:N1} MB total  |  {2} ms' -f $items.Count, ($total / 1MB), $sw.ElapsedMilliseconds)
    } catch {
        $txtStatus.Text = "Cannot open folder: $($_.Exception.Message)"
    }
    $list.ItemsSource = $items
    Start-Thumbs $items $path
}

# ----- XMP metadata -----
$fields = @(
    @{ Tag = 'XMP-dc:Title';           Key = 'Title';       Ctl = $txtTitle;    List = $false },
    @{ Tag = 'XMP-photoshop:Headline'; Key = 'Headline';    Ctl = $txtSubject;  List = $false },
    @{ Tag = 'XMP-dc:Creator';         Key = 'Creator';     Ctl = $txtAuthors;  List = $true  },
    @{ Tag = 'XMP-dc:Subject';         Key = 'Subject';     Ctl = $txtTags;     List = $true  },
    @{ Tag = 'XMP-dc:Description';     Key = 'Description'; Ctl = $txtComments; List = $false },
    @{ Tag = 'XMP-xmp:Rating';         Key = 'Rating';      Ctl = $txtRating;   List = $false }
)
$script:loaded = @{}

function Show-Metadata {
    $jpgs = @($list.SelectedItems | Where-Object { $_.IsJpg })
    $script:loaded = @{}
    $on = ($jpgs.Count -gt 0)
    foreach ($f in $fields) {
        $f.Ctl.Text = ''
        $f.Ctl.Background = [Windows.Media.Brushes]::White
        $f.Ctl.ToolTip = $null
        $f.Ctl.IsEnabled = $on
    }
    $btnSave.IsEnabled = $on
    if (-not $on) { return }

    $cmd = @('-j', '-charset', 'filename=utf8')
    foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
    foreach ($j in $jpgs) { $cmd += $j.FullPath }
    $json = $script:et.Run([string[]]$cmd)

    $objs = @()
    if ($json.Trim()) { $parsed = ConvertFrom-Json $json; $objs += $parsed }

    foreach ($f in $fields) {
        $vals = @()
        foreach ($o in $objs) {
            $v = $o.($f.Key)
            if ($null -eq $v) { $s = '' }
            elseif ($v -is [array]) { $s = (@($v | ForEach-Object { "$_" })) -join ', ' }
            else { $s = "$v" }
            $vals += $s
        }
        $uniq = @($vals | Select-Object -Unique)
        $text = ''
        if ($uniq.Count -eq 1) { $text = $uniq[0] }
        $f.Ctl.Text = $text
        $script:loaded[$f.Key] = $text
        if ($uniq.Count -gt 1) {
            $f.Ctl.Background = [Windows.Media.Brushes]::LightYellow
            $f.Ctl.ToolTip = 'Files have different values. Leave unchanged to keep each as is, or type to set all.'
        }
    }
}

function Save-Metadata {
    $jpgs = @($list.SelectedItems | Where-Object { $_.IsJpg })
    if ($jpgs.Count -eq 0) { return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $changes = @()
    foreach ($f in $fields) {
        if ($f.Ctl.Text -ceq $script:loaded[$f.Key]) { continue }
        $new = $f.Ctl.Text.Trim()
        if ($f.Key -eq 'Rating' -and $new -ne '' -and $new -notmatch '^[0-5]$') {
            $txtStatus.Text = 'Rating must be blank or a whole number 0-5.'
            return
        }
        if ($f.List) {
            if (-not $new) { $changes += ('-' + $f.Tag + '=') }
            foreach ($i in @($new -split '\s*[,;]\s*' | Where-Object { $_ })) { $changes += ('-' + $f.Tag + '=' + $i) }
        } else {
            $changes += ('-' + $f.Tag + '=' + $new)
        }
    }
    if ($changes.Count -eq 0) { $txtStatus.Text = 'No changes to save.'; return }

    $cmd = @('-charset', 'utf8', '-charset', 'filename=utf8', '-P', '-m')
    if (-not $cfg.KeepBackups) { $cmd += '-overwrite_original' }
    $cmd += $changes
    foreach ($j in $jpgs) { $cmd += $j.FullPath }
    $out = $script:et.Run([string[]]$cmd)
    $err = $script:et.LastError
    $n = 0
    if ($out -match '(\d+) image files updated') { $n = [int]$Matches[1] }
    $msg = "Saved XMP to $n file(s) in $($sw.ElapsedMilliseconds) ms"
    if ($err) { $msg += '  |  ' + (($err -split "`n")[0]); Write-Log $err }
    $txtStatus.Text = $msg
    Show-Metadata
}

# ----- Events -----
$tree.Add_SelectedItemChanged({
    $n = $tree.SelectedItem
    if ($n -and $n.Tag) { Load-Folder $n.Tag }
})

$list.Add_SelectionChanged({
    $sel = @($list.SelectedItems)
    if ($sel.Count -eq 1) {
        $s = $sel[0]
        $txtName.Text = $s.Name
        $type = if ($s.IsDir) { 'Directory' } else { 'File' }
        $size = if ($s.IsDir) { '-' } else { Format-Size $s.Size }
        $sysInfo.Text = "Path: $($s.FullPath)`nType: $type`nCreated: $($s.Created.ToString('dd/MM/yyyy hh:mm tt'))`nSize: $size"
    } elseif ($sel.Count -gt 1) {
        $bytes = ($sel | Where-Object { -not $_.IsDir } | Measure-Object Size -Sum).Sum
        $txtName.Text = "($($sel.Count) items selected)"
        $sysInfo.Text = "Selected: $($sel.Count) items`nSize: $(Format-Size ([long]$bytes))"
    } else {
        $txtName.Text = ''
        $sysInfo.Text = ''
    }
    Show-Metadata
})

$btnSave.Add_Click({ Save-Metadata })
$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'S' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        Save-Metadata; $e.Handled = $true
    }
})
$win.Add_Closing({
    Stop-Thumbs
    $script:et.Dispose()
})

# ----- Build tree, default to Details view -----
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    if ($drv.IsReady) {
        $node = Add-Node $tree.Items $drv.Name $drv.Name
        if ($drv.Name -eq 'C:\') { $node.IsExpanded = $true }
    }
}
$rbDetails.IsChecked = $true
Apply-View
$rbDetails.Add_Checked({ Apply-View })
$rbThumbs.Add_Checked({ Apply-View })
Show-Metadata

# ===== SCRIPT4-MARKER =====
Add-Type -AssemblyName Microsoft.VisualBasic, System.Windows.Forms
foreach ($n in 'btnBack','btnFwd','btnNew','btnDelete','btnCut','btnCopy','btnPaste','btnCopyTo','btnMoveTo') {
    Set-Variable -Name $n -Value $win.FindName($n)
}

$script:hist = New-Object 'System.Collections.Generic.List[string]'
$script:histIdx = -1
$script:navigating = $false
$script:folderStatus = ''
$script:sortProp = 'Name'
$script:sortDir = 'Ascending'

function Msg($text, $buttons = 'OK', $icon = 'None') {
    return [System.Windows.MessageBox]::Show($win, $text, 'MetadataEditor', $buttons, $icon)
}

# ---------- Navigation ----------
function Update-Nav {
    $btnBack.IsEnabled = ($script:histIdx -gt 0)
    $btnFwd.IsEnabled  = ($script:histIdx -lt ($script:hist.Count - 1))
}

function Select-TreePath($path) {
    $full = [IO.Path]::GetFullPath($path)
    $drive = [IO.Path]::GetPathRoot($full)
    $node = $null
    foreach ($n in $tree.Items) { if ($n.Tag -ieq $drive) { $node = $n } }
    if (-not $node) { return }
    $cur = $drive
    $rest = $full.Substring($drive.Length).Trim('\')
    $segs = @()
    if ($rest) { $segs = $rest -split '\\' }
    foreach ($seg in $segs) {
        $node.IsExpanded = $true
        Expand-Node $node
        $cur = Join-Path $cur $seg
        $next = $null
        foreach ($c in $node.Items) {
            if ($c -is [System.Windows.Controls.TreeViewItem] -and $c.Tag -ieq $cur) { $next = $c; break }
        }
        if (-not $next) { break }
        $node = $next
    }
    $node.IsSelected = $true
    $node.BringIntoView()
}

function Go-Path($path) {
    $script:navigating = $true
    try { Select-TreePath $path } finally { $script:navigating = $false }
    Update-Nav
}
function Do-Back    { if ($script:histIdx -gt 0) { $script:histIdx--; Go-Path $script:hist[$script:histIdx] } }
function Do-Forward { if ($script:histIdx -lt ($script:hist.Count - 1)) { $script:histIdx++; Go-Path $script:hist[$script:histIdx] } }

function Apply-Sort {
    $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list.ItemsSource)
    if (-not $v) { return }
    $v.SortDescriptions.Clear()
    $v.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription -ArgumentList 'IsDir', 'Descending'))
    $v.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription -ArgumentList $script:sortProp, $script:sortDir))
}

# history + sort + status after every folder load (runs after the original handler)
$tree.Add_SelectedItemChanged({
    $n = $tree.SelectedItem
    if ($n -and $n.Tag) {
        if (-not $script:navigating) {
            while ($script:hist.Count -gt ($script:histIdx + 1)) { $script:hist.RemoveAt($script:hist.Count - 1) }
            $script:hist.Add([string]$n.Tag)
            $script:histIdx = $script:hist.Count - 1
        }
        Apply-Sort
        $script:folderStatus = $txtStatus.Text
    }
    Update-Nav
})

$btnBack.Add_Click({ Do-Back })
$btnFwd.Add_Click({ Do-Forward })
Update-Nav

# double-click a folder to open it
$list.Add_MouseDoubleClick({
    param($s, $e)
    try {
        $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($list, ($e.OriginalSource -as [System.Windows.DependencyObject]))
        if ($c -and $c.Content -and $c.Content.IsDir) { Go-Path $c.Content.FullPath }
    } catch { }
})

# click column headers to sort
$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource
    if ($h -is [System.Windows.Controls.GridViewColumnHeader] -and $h.Role -ne 'Padding') {
        $map = @{ 'Name' = 'Name'; 'Type' = 'Badge'; 'Size' = 'Size'; 'Created' = 'Created' }
        $prop = $map["$($h.Content)"]
        if ($prop) {
            if ($script:sortProp -eq $prop -and $script:sortDir -eq 'Ascending') { $script:sortDir = 'Descending' }
            else { $script:sortProp = $prop; $script:sortDir = 'Ascending' }
            Apply-Sort
        }
    }
})

# selection summary in status bar
$list.Add_SelectionChanged({
    $sel = @($list.SelectedItems)
    if ($sel.Count -gt 0) {
        $b = ($sel | Where-Object { -not $_.IsDir } | Measure-Object Size -Sum).Sum
        $txtStatus.Text = "$($sel.Count) selected ($(Format-Size ([long]$b)))   |   $($script:folderStatus)"
    } elseif ($script:folderStatus) {
        $txtStatus.Text = $script:folderStatus
    }
})

# ---------- Refresh ----------
function Refresh-TreeNode {
    $n = $tree.SelectedItem
    if (-not $n) { return }
    $n.Items.Clear()
    $n.Items.Add('...') | Out-Null
    Expand-Node $n
}
function Refresh-Folder {
    if (-not $txtPath.Text) { return }
    Load-Folder $txtPath.Text
    Apply-Sort
    $script:folderStatus = $txtStatus.Text
}
function Refresh-All { Refresh-TreeNode; Refresh-Folder }

# ---------- Input dialog ----------
function Read-Input($title, $prompt, $default) {
    $w = New-Object System.Windows.Window
    $w.Title = $title; $w.Width = 380; $w.SizeToContent = 'Height'
    $w.WindowStartupLocation = 'CenterOwner'; $w.Owner = $win; $w.ResizeMode = 'NoResize'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(14)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $prompt; $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $default; $box.Height = 28; $box.VerticalContentAlignment = 'Center'
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = 'OK'; $ok.Width = 80; $ok.IsDefault = $true; $ok.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cn = New-Object System.Windows.Controls.Button
    $cn.Content = 'Cancel'; $cn.Width = 80; $cn.IsCancel = $true
    $row.Children.Add($ok) | Out-Null; $row.Children.Add($cn) | Out-Null
    $sp.Children.Add($tb) | Out-Null; $sp.Children.Add($box) | Out-Null; $sp.Children.Add($row) | Out-Null
    $w.Content = $sp
    $res = @{ v = $null }
    $ok.Add_Click({ $res.v = $box.Text; $w.DialogResult = $true }.GetNewClosure())
    $w.Add_Loaded({ $box.Focus() | Out-Null; $box.SelectAll() }.GetNewClosure())
    if ($w.ShowDialog()) { return $res.v }
    return $null
}

# ---------- File operations ----------
function Get-SelPaths { @($list.SelectedItems | ForEach-Object { $_.FullPath }) }

function Get-UniquePath($dir, $name, $isDir) {
    $p = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $p)) { return $p }
    if ($isDir) { $base = $name; $ext = '' }
    else { $base = [IO.Path]::GetFileNameWithoutExtension($name); $ext = [IO.Path]::GetExtension($name) }
    $i = 1
    do {
        $suffix = if ($i -eq 1) { ' - Copy' } else { " - Copy ($i)" }
        $p = Join-Path $dir ($base + $suffix + $ext)
        $i++
    } while (Test-Path -LiteralPath $p)
    return $p
}

function Do-NewFolder {
    $cur = $txtPath.Text
    if (-not $cur) { return }
    $name = Read-Input 'New folder' 'Folder name:' 'New folder'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim()
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { [void](Msg 'That name contains invalid characters.' 'OK' 'Warning'); return }
    $p = Join-Path $cur $name
    if (Test-Path -LiteralPath $p) { [void](Msg 'A file or folder with that name already exists.' 'OK' 'Warning'); return }
    [void][IO.Directory]::CreateDirectory($p)
    Refresh-All
    $txtStatus.Text = "Created folder '$name'"
}

function Do-Delete {
    $sel = @($list.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $q = if ($sel.Count -eq 1) { "Move '$($sel[0].Name)' to the Recycle Bin?" } else { "Move $($sel.Count) items to the Recycle Bin?" }
    if ((Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
    Stop-Thumbs
    $errors = @(); $done = 0
    foreach ($it in $sel) {
        try {
            if ($it.IsDir) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($it.FullPath, 'OnlyErrorDialogs', 'SendToRecycleBin') }
            else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($it.FullPath, 'OnlyErrorDialogs', 'SendToRecycleBin') }
            $done++
        } catch { $errors += "$($it.Name): $($_.Exception.Message)" }
    }
    Refresh-All
    $txtStatus.Text = "Deleted $done item(s)"
    if ($errors.Count -gt 0) { [void](Msg ("Some items could not be deleted:`n`n" + ($errors -join "`n")) 'OK' 'Warning') }
}

function Set-ClipFiles($paths, $move) {
    if (-not $paths -or $paths.Count -eq 0) { return }
    $sc = New-Object System.Collections.Specialized.StringCollection
    foreach ($x in $paths) { [void]$sc.Add($x) }
    $d = New-Object System.Windows.DataObject
    $d.SetFileDropList($sc)
    $eff = if ($move) { 2 } else { 5 }
    $ms = New-Object IO.MemoryStream (, [byte[]]@($eff, 0, 0, 0))
    $d.SetData('Preferred DropEffect', $ms)
    [System.Windows.Clipboard]::SetDataObject($d, $true)
    $verb = if ($move) { 'Cut' } else { 'Copied' }
    $txtStatus.Text = "$verb $($paths.Count) item(s) to clipboard"
}

function Transfer-Items($paths, $dest, $move) {
    Stop-Thumbs
    $errors = @(); $done = 0
    foreach ($src in $paths) {
        $name = $src
        try {
            $srcTrim = $src.TrimEnd('\')
            $isDir = [IO.Directory]::Exists($srcTrim)
            $name = [IO.Path]::GetFileName($srcTrim)
            if ($isDir -and ($dest.TrimEnd('\') + '\').StartsWith($srcTrim + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Cannot copy or move a folder into itself.'
            }
            $srcDir = [IO.Path]::GetDirectoryName($srcTrim)
            if ($move -and $srcDir.TrimEnd('\') -ieq $dest.TrimEnd('\')) { continue }
            $target = Get-UniquePath $dest $name $isDir
            if ($move) { Move-Item -LiteralPath $srcTrim -Destination $target }
            else { Copy-Item -LiteralPath $srcTrim -Destination $target -Recurse }
            $done++
        } catch { $errors += "${name}: $($_.Exception.Message)" }
    }
    Refresh-All
    $verb = if ($move) { 'Moved' } else { 'Copied' }
    $txtStatus.Text = "$verb $done item(s)"
    if ($errors.Count -gt 0) { [void](Msg ("Some items failed:`n`n" + ($errors -join "`n")) 'OK' 'Warning') }
}

function Do-Paste {
    $dest = $txtPath.Text
    if (-not $dest) { return }
    if (-not [System.Windows.Clipboard]::ContainsFileDropList()) { $txtStatus.Text = 'Clipboard has no files.'; return }
    $paths = @([System.Windows.Clipboard]::GetFileDropList())
    $move = $false
    $d = [System.Windows.Clipboard]::GetDataObject()
    if ($d -and $d.GetDataPresent('Preferred DropEffect')) {
        $s = $d.GetData('Preferred DropEffect')
        if ($s -is [IO.MemoryStream]) {
            $b = $s.ToArray()
            if ($b.Length -gt 0 -and $b[0] -eq 2) { $move = $true }
        }
    }
    Transfer-Items $paths $dest $move
    if ($move) { [System.Windows.Clipboard]::Clear() }
}

function Pick-Folder($title) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $title
    $dlg.ShowNewFolderButton = $true
    if ($txtPath.Text) { $dlg.SelectedPath = $txtPath.Text }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    return $null
}
function Do-CopyTo { $ps = Get-SelPaths; if ($ps.Count -eq 0) { return }; $d = Pick-Folder 'Copy selected items to:'; if ($d) { Transfer-Items $ps $d $false } }
function Do-MoveTo { $ps = Get-SelPaths; if ($ps.Count -eq 0) { return }; $d = Pick-Folder 'Move selected items to:'; if ($d) { Transfer-Items $ps $d $true } }

$btnNew.Add_Click({ Do-NewFolder })
$btnDelete.Add_Click({ Do-Delete })
$btnCut.Add_Click({ Set-ClipFiles (Get-SelPaths) $true })
$btnCopy.Add_Click({ Set-ClipFiles (Get-SelPaths) $false })
$btnPaste.Add_Click({ Do-Paste })
$btnCopyTo.Add_Click({ Do-CopyTo })
$btnMoveTo.Add_Click({ Do-MoveTo })

# ---------- Keyboard shortcuts (ignored while typing in a text box) ----------
$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
    $m = [int][System.Windows.Input.Keyboard]::Modifiers
    $ctrl = (($m -band 2) -ne 0)
    $alt  = (($m -band 1) -ne 0)
    $k = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
    if ($alt -and $k -eq 'Left')  { Do-Back; $e.Handled = $true; return }
    if ($alt -and $k -eq 'Right') { Do-Forward; $e.Handled = $true; return }
    if ($k -eq 'F5') { Refresh-All; $e.Handled = $true; return }
    if ($ctrl -and $k -eq 'V' -and ($list.IsKeyboardFocusWithin -or $tree.IsKeyboardFocusWithin)) { Do-Paste; $e.Handled = $true; return }
    if ($list.IsKeyboardFocusWithin) {
        if ($ctrl -and $k -eq 'C') { Set-ClipFiles (Get-SelPaths) $false; $e.Handled = $true }
        elseif ($ctrl -and $k -eq 'X') { Set-ClipFiles (Get-SelPaths) $true; $e.Handled = $true }
        elseif ($k -eq 'Delete') { Do-Delete; $e.Handled = $true }
        elseif ($k -eq 'Return') {
            $one = @($list.SelectedItems)
            if ($one.Count -eq 1 -and $one[0].IsDir) { Go-Path $one[0].FullPath; $e.Handled = $true }
        }
    }
})
# ===== END SCRIPT4 =====

$win.ShowDialog() | Out-Null



