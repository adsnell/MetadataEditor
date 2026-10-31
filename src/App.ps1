$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$cfg = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
# PORTABLE-MARKER
foreach ($d in 'cache', 'cache\thumbs', 'logs') { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
$bundledEt = Join-Path $root 'exiftool\exiftool.exe'
if (Test-Path $bundledEt) { $cfg.ExifToolPath = $bundledEt }
elseif (-not [IO.Path]::IsPathRooted([string]$cfg.ExifToolPath)) { $cfg.ExifToolPath = Join-Path $root ([string]$cfg.ExifToolPath) }
if (-not (Test-Path $cfg.ExifToolPath)) {
    [void][System.Windows.MessageBox]::Show("ExifTool was not found:`n$($cfg.ExifToolPath)`n`nPut exiftool.exe (with its exiftool_files folder) in the 'exiftool' folder next to this app.", 'MetadataEditor')
    exit 0
}
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
    public string FolderText { get; set; }
    public bool IsCloud { get; set; }
    private string _titleText, _subjectText, _authorText, _tagsText;
    public string TitleText { get { return _titleText; } set { _titleText = value; Notify("TitleText"); } }
    public string SubjectText { get { return _subjectText; } set { _subjectText = value; Notify("SubjectText"); } }
    public string AuthorText { get { return _authorText; } set { _authorText = value; Notify("AuthorText"); } }
    public string TagsText { get { return _tagsText; } set { _tagsText = value; Notify("TagsText"); } }
    private string _ratingText;
    public string RatingText { get { return _ratingText; } set { _ratingText = value; Notify("RatingText"); } }
    private string _cameraText;
    public string CameraText { get { return _cameraText; } set { _cameraText = value; Notify("CameraText"); } }
    private string _commentText;
    public string CommentText { get { return _commentText; } set { _commentText = value; Notify("CommentText"); } }
    private string _takenText;
    public string TakenText { get { return _takenText; } set { _takenText = value; Notify("TakenText"); } }
    private string _copyrightText;
    public string CopyrightText { get { return _copyrightText; } set { _copyrightText = value; Notify("CopyrightText"); } }
    private void Notify(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
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
    Stop-ShellThumbs
    $timer.Stop()
    if ($script:thumbProc -and -not $script:thumbProc.HasExited) { try { $script:thumbProc.Kill() } catch { } }
    $script:thumbProc = $null
    $script:thumbPending = New-Object 'System.Collections.Generic.List[FileItem]'
}
function Start-Thumbs($items, $path) {
    Stop-Thumbs
    $jpgs = @($items | Where-Object { $_.IsJpg -and -not $_.IsCloud -and ((Get-NeededPx) -le 160) })
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
            $i.SizeText = Format-Size $f.Length; $i.IsCloud = ((([int]$f.Attributes) -band 0x441000) -ne 0)
            $i.CreatedText = $f.CreationTime.ToString('dd/MM/yyyy HH:mm')
            $total += $f.Length
            $items.Add($i)
        }
        $txtStatus.Text = ('{0} items  |  {1:N1} MB total  |  {2} ms' -f $items.Count, ($total / 1MB), $sw.ElapsedMilliseconds)
    } catch {
        $txtStatus.Text = "Cannot open folder: $($_.Exception.Message)"
    }
    $list.ItemsSource = $items
    Start-Thumbs $items $path; After-FolderLoad $items
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

# ----- XMP support by file type -----
$script:xmpEmbedded = @('jpg','jpeg','jpe','tif','tiff','png','dng','psd','webp','heic','heif','avif','gif','jp2','j2k','pdf','mp4','m4v','mov','ai','eps','indd','xmp')
$script:xmpSidecar  = @('raf','cr2','cr3','crw','nef','nrw','arw','sr2','srf','orf','rw2','pef','srw','x3f','3fr','erf','kdc','mrw','raw','dcr','iiq','rwl','gpr')
$script:emptyXmp = '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>' + "`n" +
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>' + "`n" +
    '<?xpacket end="w"?>'

function Get-XmpMode($it) {
    if ($it.IsDir) { return $null }
    $x = [IO.Path]::GetExtension($it.Name).TrimStart('.').ToLower()
    if ($script:xmpEmbedded -contains $x) { return 'embedded' }
    if ($script:xmpSidecar -contains $x) { return 'sidecar' }
    return $null
}
function Get-MetaTarget($it) {
    if ((Get-XmpMode $it) -eq 'sidecar') { return [IO.Path]::ChangeExtension($it.FullPath, 'xmp') }
    return $it.FullPath
}
function Get-Targets($sel) {
    return @($sel | ForEach-Object { Get-MetaTarget $_ } | Sort-Object -Unique)
}

function Show-Metadata {
    $all = @($list.SelectedItems)
    $sel = @($all | Where-Object { Get-XmpMode $_ })
    $script:loaded = @{}
    $on = ($sel.Count -gt 0)
    foreach ($f in $fields) {
        $f.Ctl.Text = ''
        $f.Ctl.Background = [Windows.Media.Brushes]::White
        $f.Ctl.ToolTip = $null
        $f.Ctl.IsEnabled = $on
    }
    $btnSave.IsEnabled = $on

    # note in the system info box
    $files = @($all | Where-Object { -not $_.IsDir })
    if ($files.Count -gt 0) {
        $nEmb  = @($sel | Where-Object { (Get-XmpMode $_) -eq 'embedded' }).Count
        $nSide = @($sel | Where-Object { (Get-XmpMode $_) -eq 'sidecar' }).Count
        $nNo   = $files.Count - $sel.Count
        $parts = @()
        if ($nEmb  -gt 0) { $parts += "$nEmb embedded" }
        if ($nSide -gt 0) { $parts += "$nSide in .xmp sidecar" }
        if ($nNo   -gt 0) { $parts += "$nNo not supported" }
        $sysInfo.Text = $sysInfo.Text + "`nXMP: " + ($parts -join ', ')
    }
    if (-not $on) { return }

    $readPaths = @()
    $missing = 0
    foreach ($tp in (Get-Targets $sel)) {
        if ([IO.File]::Exists($tp)) { $readPaths += $tp } else { $missing++ }
    }
    $objs = @()
    if ($readPaths.Count -gt 0) {
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        $cmd += $readPaths
        $json = $script:et.Run([string[]]$cmd)
        if ($json.Trim()) { $parsed = ConvertFrom-Json $json; $objs += $parsed }
    }
    for ($i = 0; $i -lt $missing; $i++) { $objs += [pscustomobject]@{} }

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
    $all = @($list.SelectedItems | Where-Object { -not $_.IsDir })
    $sel = @($all | Where-Object { Get-XmpMode $_ })
    if ($sel.Count -eq 0) { return }
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
    if ($changes.Count -eq 0) {
        $txtStatus.Text = 'No changes to save.'
        # (popup removed - status bar only)
        return
    }

    # create any missing sidecars
    $created = 0
    foreach ($it in $sel) {
        if ((Get-XmpMode $it) -eq 'sidecar') {
            $tp = Get-MetaTarget $it
            if (-not [IO.File]::Exists($tp)) {
                [IO.File]::WriteAllText($tp, $script:emptyXmp, (New-Object Text.UTF8Encoding($false)))
                $created++
            }
        }
    }

    $cmd = @('-charset', 'utf8', '-charset', 'filename=utf8', '-P', '-m')
    if (-not $cfg.KeepBackups) { $cmd += '-overwrite_original' }
    $cmd += $changes
    $cmd += (Get-Targets $sel)
    $out = $script:et.Run([string[]]$cmd)
    $err = $script:et.LastError
    $n = 0
    if ($out -match '(\d+) image files updated') { $n = [int]$Matches[1] }
    $msg = "Saved " + (Get-ChangedNames $changes) + " to $n file(s) in $($sw.ElapsedMilliseconds) ms"
    if ($created -gt 0) { $msg += " ($created new sidecar file(s))" }
    $skipped = $all.Count - $sel.Count
    if ($skipped -gt 0) { $msg += "  |  $skipped unsupported file(s) skipped" }
    if ($err) { $msg += '  |  ' + (($err -split "`n")[0]); Write-Log $err }
    $txtStatus.Text = $msg; $script:metaReady = $false; Update-SavedCols
    Write-Log ("SAVE cmd: " + ($cmd -join " | "))
    Write-Log ("SAVE out: " + $out)
    # (popup removed - result is shown in the status bar)
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

# ===== SCRIPT6-MARKER =====
$txtSearch = $win.FindName('txtSearch')
if (-not ('ShellThumb' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ShellThumb {
    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE { public int cx; public int cy; }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory {
        [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [In] ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr h);

    public static IntPtr Get(string path, int size, out bool isIcon) {
        isIcon = false;
        try {
            Guid iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
            IShellItemImageFactory f;
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out f);
            SIZE s; s.cx = size; s.cy = size;
            IntPtr h;
            string ext = Path.GetExtension(path).ToLowerInvariant(); if (" .pdf .doc .docx .dot .dotx .docm .rtf .odt .xls .xlsx .xlsm .xlsb .xlt .xltx .ods .csv .tsv .ppt .pptx .pptm .pps .ppsx .potx .odp .txt .log .md .ini .xml .json .zip .7z .rar ".IndexOf(" " + ext + " ", StringComparison.Ordinal) >= 0) { Marshal.ReleaseComObject(f); return IntPtr.Zero; } int hr = f.GetImage(s, 8, out h);
            if (hr != 0) { isIcon = true; hr = f.GetImage(s, 4, out h); }
            Marshal.ReleaseComObject(f);
            if (hr == 0) return h;
            return IntPtr.Zero;
        } catch { return IntPtr.Zero; }
    }

    public static void Delete(IntPtr h) { if (h != IntPtr.Zero) DeleteObject(h); }
}

public class ThumbResult { public string FilePath; public IntPtr H; public bool IsIcon; }

public class ShellThumbWorker {
    private ConcurrentQueue<ThumbResult> results = new ConcurrentQueue<ThumbResult>();
    public volatile bool Done;
    private volatile bool stop;
    private Thread th;

    public void Start(string[] paths, int size) {
        th = new Thread(delegate() {
            foreach (string p in paths) {
                if (stop) break;
                bool icon;
                IntPtr h = ShellThumb.Get(p, size, out icon);
                if (h != IntPtr.Zero) {
                    ThumbResult r = new ThumbResult();
                    r.FilePath = p; r.H = h; r.IsIcon = icon;
                    results.Enqueue(r);
                }
            }
            Done = true;
        });
        th.SetApartmentState(ApartmentState.STA);
        th.IsBackground = true;
        th.Start();
    }

    public object[] Take() {
        ThumbResult r;
        if (results.TryDequeue(out r)) return new object[] { r.FilePath, r.H, r.IsIcon };
        return null;
    }

    public bool IsEmpty { get { return results.IsEmpty; } }
    public void Stop() { stop = true; }
    public void Drain() {
        ThumbResult r;
        while (results.TryDequeue(out r)) ShellThumb.Delete(r.H);
    }
}

public class DeepWalker {
    public volatile bool Done;
    public volatile int Count;
    private volatile bool stop;
    private string[] files = new string[0];
    public Dictionary<string, string> Meta = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    private Thread th;

    public void Start(string root, int max) {
        th = new Thread(delegate() {
            List<string> all = new List<string>();
            Stack<string> dirs = new Stack<string>();
            dirs.Push(root);
            while (dirs.Count > 0 && !stop) {
                string d = dirs.Pop();
                try { foreach (string f in Directory.EnumerateFiles(d)) { all.Add(f); } } catch { }
                Count = all.Count;
                if (all.Count >= max) break;
                try {
                    foreach (string sd in Directory.EnumerateDirectories(d)) {
                        try { if ((File.GetAttributes(sd) & FileAttributes.ReparsePoint) != 0) continue; } catch { continue; }
                        dirs.Push(sd);
                    }
                } catch { }
            }
            files = all.ToArray();
            Done = true;
        });
        th.IsBackground = true;
        th.Start();
    }

    public int FileCount { get { return files.Length; } }
    public void Stop() { stop = true; }

    public string[] Filter(string[] terms, int max) {
        List<string> res = new List<string>();
        foreach (string f in files) {
            string name = Path.GetFileName(f).ToLowerInvariant();
            string m;
            Meta.TryGetValue(f, out m);
            bool ok = true;
            foreach (string t in terms) {
                if (!(name.Contains(t) || (m != null && m.Contains(t)))) { ok = false; break; }
            }
            if (ok) { res.Add(f); if (res.Count >= max) break; }
        }
        return res.ToArray();
    }
}

public class AsyncExif {
    private Process p;
    private StringBuilder sb = new StringBuilder();
    private object gate = new object();
    public volatile bool Done;

    public void Start(string exe, string argFile) {
        ProcessStartInfo psi = new ProcessStartInfo(exe, "-@ \"" + argFile + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        p = Process.Start(psi);
        p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) {
            if (e.Data == null) { Done = true; }
            else { lock (gate) { sb.Append(e.Data); sb.Append('\n'); } }
        };
        p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
    }

    public string Output { get { lock (gate) { return sb.ToString(); } } }
    public void Kill() { try { if (p != null && !p.HasExited) p.Kill(); } catch { } }
}
"@
}

# ---------- Shell thumbnails / icons for every non-JPG file ----------
$script:shellWorker = $null
$script:shellMap = @{}
$shellTimer = New-Object System.Windows.Threading.DispatcherTimer
$shellTimer.Interval = [TimeSpan]::FromMilliseconds(120)

function Stop-ShellThumbs {
    $shellTimer.Stop()
    if ($script:shellWorker) {
        $script:shellWorker.Stop()
        $script:shellWorker.Drain()
        $script:shellWorker = $null
    }
    $script:shellMap = @{}
}

function Start-ShellThumbs($items, $includeJpg = $false) {
    Stop-ShellThumbs
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($it in $items) {
        if ($it.IsDir) { continue }
        if ($it.IsJpg -and -not $includeJpg) { continue }
        if ($it.Thumb) { continue }
        $paths.Add($it.FullPath)
        $script:shellMap[$it.FullPath] = $it
    }
    if ($paths.Count -eq 0) { return }
    $w = New-Object ShellThumbWorker
    $script:shellWorker = $w
    $w.Start($paths.ToArray(), 160)
    $shellTimer.Start()
}

function New-IconTile($icon) {
    $size = 160
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $bg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(238, 242, 247))
    $dc.DrawRectangle($bg, $null, [System.Windows.Rect]::new(0, 0, $size, $size))
    $w = $size * 0.7
    $dc.DrawImage($icon, [System.Windows.Rect]::new(($size - $w) / 2, ($size - $w) / 2, $w, $w))
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    return $rtb
}

$shellTimer.Add_Tick({
    try {
        $w = $script:shellWorker
        if (-not $w) { $shellTimer.Stop(); return }
        while ($null -ne ($r = $w.Take())) {
            try {
                $path = [string]$r[0]
                $bmp = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap($r[1], [IntPtr]::Zero, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                $bmp.Freeze()
                [ShellThumb]::Delete($r[1])
                if ([bool]$r[2]) { $bmp = New-IconTile $bmp }
                $it = $script:shellMap[$path]
                if ($it) { $it.Thumb = $bmp }
            } catch { }
        }
        if ($w.Done -and $w.IsEmpty) { $shellTimer.Stop() }
    } catch { }
})

# ---------- Search state ----------
$script:searchTerms = @()
$script:metaText = @{}
$script:metaReady = $false
$script:folderItems = $null
$script:deepActive = $false
$script:deepReady = $false
$script:deepWalker = $null
$script:deepExif = $null
$script:deepRoot = ''
$txtSearch.ToolTip = 'Search file names and XMP (Title, Subject, Authors, Tags, Comments). Esc clears.'

# Subfolders tick-box
$chkSub = New-Object System.Windows.Controls.CheckBox
$chkSub.Content = 'Subfolders'
$chkSub.FontSize = 12
$chkSub.VerticalAlignment = 'Center'
$chkSub.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
$chkSub.ToolTip = 'Search this folder and everything below it'
[System.Windows.Controls.DockPanel]::SetDock($chkSub, [System.Windows.Controls.Dock]::Right)
$txtSearch.Parent.Children.Add($chkSub) | Out-Null

function Set-FolderCol($show) {
    $gv = $win.FindResource('detailsView')
    if ($gv.Columns.Count -ge 5) { $gv.Columns[4].Width = $(if ($show) { 340 } else { 0 }) }
}

# ---------- Current-folder search ----------
function Build-MetaIndex {
    $script:metaText = @{}
    $byKey = @{}
    foreach ($it in @($list.ItemsSource)) {
        if ($it.IsDir -or -not (Get-XmpMode $it)) { continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $byKey[$tp.ToLowerInvariant()] = @{ Item = $it; Path = $tp } }
    }
    $all = @($byKey.Values | ForEach-Object { $_.Path })
    for ($i = 0; $i -lt $all.Count; $i += 150) {
        $chunk = @($all[$i..([Math]::Min($i + 149, $all.Count - 1))])
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        $cmd += $chunk
        $json = $script:et.Run([string[]]$cmd)
        if (-not $json.Trim()) { continue }
        $objs = @()
        $objs += (ConvertFrom-Json $json)
        foreach ($o in $objs) {
            $key = (("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()
            $entry = $byKey[$key]
            if (-not $entry) { continue }
            $parts = @()
            foreach ($f in $fields) {
                $v = $o.($f.Key)
                if ($null -eq $v) { continue }
                if ($v -is [array]) { $parts += (@($v | ForEach-Object { "$_" }) -join ' ') } else { $parts += "$v" }
            }
            $script:metaText[$entry.Item.FullPath] = ($parts -join ' ').ToLowerInvariant()
        }
    }
    $script:metaReady = $true
}

$script:searchPredicate = [System.Predicate[object]]{
    param($o)
    $name = $o.Name.ToLowerInvariant()
    $meta = $script:metaText[$o.FullPath]
    foreach ($term in $script:searchTerms) {
        if (-not ($name.Contains($term) -or ($meta -and $meta.Contains($term)))) { return $false }
    }
    return $true
}

# ---------- Subfolder search ----------
function New-ItemFromPath($path, $sroot) {
    try {
        $f = New-Object IO.FileInfo $path
        $ext = $f.Extension.TrimStart('.').ToUpper()
        if (-not $ext) { $ext = 'FILE' }
        if ($ext.Length -gt 9) { $ext = $ext.Substring(0, 9) }
        $i = New-Object FileItem
        $i.Name = $f.Name; $i.FullPath = $f.FullName; $i.Size = $f.Length; $i.Created = $f.CreationTime
        $i.Badge = $ext
        $i.BadgeColor = if ($colors.ContainsKey($ext)) { $colors[$ext] } else { '#3B9AF5' }
        $i.IsJpg = ($ext -eq 'JPG' -or $ext -eq 'JPEG')
        $i.SizeText = Format-Size $f.Length; $i.IsCloud = ((([int]$f.Attributes) -band 0x441000) -ne 0)
        $i.CreatedText = $f.CreationTime.ToString('dd/MM/yyyy HH:mm')
        $d = $f.DirectoryName
        $i.FolderText = if ($d.Length -gt $sroot.Length) { $d.Substring($sroot.Length).TrimStart('\') } else { '.' }
        return $i
    } catch { return $null }
}

function Import-DeepMeta($w, $json) {
    if (-not $json -or -not $json.Trim()) { return }
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $objs = $js.DeserializeObject($json)
    foreach ($o in $objs) {
        $sf = ([string]$o['SourceFile']) -replace '/', '\'
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $fields) {
            if ($o.ContainsKey($f.Key)) {
                $v = $o[$f.Key]
                if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { foreach ($e in $v) { $parts.Add([string]$e) } }
                else { $parts.Add([string]$v) }
            }
        }
        if ($parts.Count -gt 0) { $w.Meta[$sf] = ($parts -join ' ').ToLowerInvariant() }
    }
}

function Show-DeepResults {
    $w = $script:deepWalker
    if (-not $w -or $script:searchTerms.Count -eq 0) { return }
    $paths = $w.Filter([string[]]$script:searchTerms, 2000)
    $items = New-Object 'System.Collections.Generic.List[FileItem]'
    foreach ($pth in $paths) {
        $i = New-ItemFromPath $pth $script:deepRoot
        if ($i) { $items.Add($i) }
    }
    $script:deepActive = $true
    $list.ItemsSource = $items
    Set-FolderCol $true
    Apply-Sort
    Start-ShellThumbs $items $true
    $more = ''
    if ($paths.Count -ge 2000) { $more = ' (first 2000 shown)' }
    $txtStatus.Text = "$($items.Count) match(es) in subfolders$more for '$($txtSearch.Text.Trim())'   |   $($w.FileCount) files searched"
}

function Stop-Deep {
    $deepTimer.Stop()
    if ($script:deepReady) { return }
    if ($script:deepWalker) { $script:deepWalker.Stop() }
    if ($script:deepExif) { $script:deepExif.Kill() }
    $script:deepWalker = $null
    $script:deepExif = $null
}

function Start-Deep {
    $sroot = $txtPath.Text
    if (-not $sroot -or -not [IO.Directory]::Exists($sroot)) { return }
    if ([IO.Path]::GetPathRoot($sroot).TrimEnd('\') -ieq $sroot.TrimEnd('\')) {
        $txtStatus.Text = 'Subfolder search needs a folder, not a whole drive.'
        return
    }
    $script:deepRoot = $sroot
    $script:deepReady = $false
    $w = New-Object DeepWalker
    $script:deepWalker = $w
    $w.Start($sroot, 100000)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in '-r', '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
    foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
    foreach ($ext in $script:xmpEmbedded) { $lines.Add('-ext'); $lines.Add($ext) }
    $lines.Add($sroot)
    $argFile = Join-Path $root 'cache\_deep_args.txt'
    [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
    $x = New-Object AsyncExif
    $script:deepExif = $x
    $x.Start($cfg.ExifToolPath, $argFile)

    $txtStatus.Text = 'Searching subfolders...'
    $deepTimer.Start()
}

$deepTimer = New-Object System.Windows.Threading.DispatcherTimer
$deepTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$deepTimer.Add_Tick({
    try {
        $w = $script:deepWalker
        $x = $script:deepExif
        if (-not $w) { $deepTimer.Stop(); return }
        if (-not $w.Done -or ($x -and -not $x.Done)) {
            $txtStatus.Text = "Searching subfolders... $($w.Count) files scanned"
            return
        }
        $deepTimer.Stop()
        if ($x) { Import-DeepMeta $w $x.Output }
        $script:deepReady = $true
        $script:metaReady = $true
        Show-DeepResults
    } catch {
        $deepTimer.Stop()
        $txtStatus.Text = 'Subfolder search error: ' + $_.Exception.Message
        Write-Log $_.Exception.ToString()
    }
})

function Restore-Folder {
    if (-not $script:deepActive) { return }
    $script:deepActive = $false
    Set-FolderCol $false
    if ($script:folderItems) {
        $v0 = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:folderItems)
        if ($v0) { $v0.Filter = $null }
        $list.ItemsSource = $script:folderItems
        Apply-Sort
        Start-ShellThumbs $script:folderItems
    }
}

function Apply-Search {
    $q = $txtSearch.Text.Trim().ToLowerInvariant()
    if (-not $q) {
        $script:searchTerms = @()
        Stop-Deep
        Restore-Folder
        $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list.ItemsSource)
        if ($v) { $v.Filter = $null; $v.Refresh() }
        if ($script:folderStatus) { $txtStatus.Text = $script:folderStatus }
        return
    }
    $script:searchTerms = @($q -split '\s+' | Where-Object { $_ })

    if ($chkSub.IsChecked) {
        if (-not $script:metaReady -and $script:deepReady) {
            $script:deepReady = $false; $script:deepWalker = $null; $script:deepExif = $null
        }
        if ($script:deepReady) { Show-DeepResults; return }
        if ($script:deepWalker) { $deepTimer.Start(); return }
        Start-Deep
        return
    }

    Stop-Deep
    Restore-Folder
    $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list.ItemsSource)
    if (-not $v) { return }
    if (-not $script:metaReady) {
        $txtStatus.Text = 'Indexing XMP metadata...'
        $win.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        Build-MetaIndex
    }
    $v.Filter = $script:searchPredicate
    $v.Refresh()
    $cnt = 0
    foreach ($x in $v) { $cnt++ }
    $txtStatus.Text = "$cnt match(es) for '$($txtSearch.Text.Trim())'   |   $($script:folderStatus)"
}

function Reset-Search {
    $script:metaReady = $false
    $script:metaText = @{}
    $script:searchTerms = @()
    $script:deepReady = $false
    Stop-Deep
    $script:deepWalker = $null
    $script:deepExif = $null
    $script:deepActive = $false
    Set-FolderCol $false
    if ($txtSearch.Text) { $txtSearch.Text = '' }
}

function After-FolderLoad($items) {
    $script:folderItems = $items
    Start-ShellThumbs $items
    Reset-Search
}

$searchTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$searchTimer.Add_Tick({ $searchTimer.Stop(); Apply-Search })
$txtSearch.Add_TextChanged({ $searchTimer.Stop(); $searchTimer.Start() })
$chkSub.Add_Click({ $searchTimer.Stop(); Apply-Search })
$txtSearch.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $txtSearch.Text = ''; $list.Focus() | Out-Null; $e.Handled = $true }
    elseif ($e.Key -eq 'Return') { $searchTimer.Stop(); Apply-Search; $e.Handled = $true }
})
$win.Add_PreviewKeyDown({
    param($s, $e)
    $m = [int][System.Windows.Input.Keyboard]::Modifiers
    if ($e.Key -eq 'F' -and (($m -band 2) -ne 0)) { $txtSearch.Focus() | Out-Null; $txtSearch.SelectAll(); $e.Handled = $true }
})
# ===== END SCRIPT6 =====

# ===== SCRIPT8-MARKER =====
$txtCopyright = $win.FindName('txtCopyright')
$settingsFile = Join-Path $root 'settings.json'

# ---------- Copyright field (before Rating) ----------
if (-not ($fields | Where-Object { $_.Key -eq 'Rights' })) {
    $newFields = @()
    foreach ($f in $fields) {
        if ($f.Key -eq 'Rating') { $newFields += @{ Tag = 'XMP-dc:Rights'; Key = 'Rights'; Ctl = $txtCopyright; List = $false } }
        $newFields += $f
    }
    $fields = $newFields
}

if (-not ('DeepWalker2' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

public class DeepWalker2 {
    public volatile bool Done;
    public volatile int Count;
    private volatile bool stop;
    private string[] files = new string[0];
    private string[] readable = new string[0];
    public Dictionary<string, string> Meta = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    private Thread th;

    public void Start(string root, int max, string[] exts) {
        th = new Thread(delegate() {
            Dictionary<string, bool> ext = new Dictionary<string, bool>();
            foreach (string e in exts) ext[e.ToLowerInvariant()] = true;
            List<string> all = new List<string>();
            List<string> read = new List<string>();
            Stack<string> dirs = new Stack<string>();
            dirs.Push(root);
            while (dirs.Count > 0 && !stop) {
                string d = dirs.Pop();
                DirectoryInfo di = new DirectoryInfo(d);
                try {
                    foreach (FileInfo fi in di.EnumerateFiles()) {
                        all.Add(fi.FullName);
                        int a = (int)fi.Attributes;
                        bool cloud = (a & 0x441000) != 0;
                        if (!cloud && ext.ContainsKey(fi.Extension.TrimStart('.').ToLowerInvariant())) read.Add(fi.FullName);
                    }
                } catch { }
                Count = all.Count;
                if (all.Count >= max) break;
                try {
                    foreach (DirectoryInfo sd in di.EnumerateDirectories()) {
                        int sa = (int)sd.Attributes;
                        bool reparse = (sa & 0x400) != 0;
                        bool cloudDir = (sa & 0x440000) != 0;
                        if (reparse && !cloudDir) continue;
                        dirs.Push(sd.FullName);
                    }
                } catch { }
            }
            files = all.ToArray();
            readable = read.ToArray();
            Done = true;
        });
        th.IsBackground = true;
        th.Start();
    }

    public int FileCount { get { return files.Length; } }
    public string[] Readable { get { return readable; } }
    public void Stop() { stop = true; }

    public string[] Filter(string[] terms, int max) {
        List<string> res = new List<string>();
        foreach (string f in files) {
            string name = Path.GetFileName(f).ToLowerInvariant();
            string m;
            Meta.TryGetValue(f, out m);
            bool ok = true;
            foreach (string t in terms) {
                if (!(name.Contains(t) || (m != null && m.Contains(t)))) { ok = false; break; }
            }
            if (ok) { res.Add(f); if (res.Count >= max) break; }
        }
        return res.ToArray();
    }
}
"@
}

# ---------- Field helpers + Details columns ----------
function Get-FieldText($o, $key) {
    $v = $null
    if ($o -is [System.Collections.IDictionary]) { if ($o.ContainsKey($key)) { $v = $o[$key] } }
    else { $v = $o.$key }
    if ($null -eq $v) { return '' }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return ((@($v | ForEach-Object { "$_" })) -join ', ') }
    return "$v"
}
function Get-AllText($o) {
    $parts = @()
    foreach ($f in $fields) { $s = Get-FieldText $o $f.Key; if ($s) { $parts += $s } }
    return (($parts -join ' ').ToLowerInvariant())
}
function Set-ItemCols($it, $o) {
    $it.TitleText   = Get-FieldText $o 'Title'
    $it.SubjectText = Get-FieldText $o 'Headline'
    $it.AuthorText  = Get-FieldText $o 'Creator'
    $it.TagsText    = Get-FieldText $o 'Subject'
}
function Set-FolderCol($show) {
    $gv = $win.FindResource('detailsView')
    foreach ($c in $gv.Columns) { if ("$($c.Header)" -eq 'Folder') { $c.Width = $(if ($show) { 340 } else { 0 }) } }
}

# sort by the metadata columns
$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource
    if ($h -is [System.Windows.Controls.GridViewColumnHeader] -and $h.Role -ne 'Padding') {
        $map2 = @{ 'Title' = 'TitleText'; 'Subject' = 'SubjectText'; 'Author' = 'AuthorText'; 'Tags' = 'TagsText' }
        $prop = $map2["$($h.Content)"]
        if ($prop) {
            if ($script:sortProp -eq $prop -and $script:sortDir -eq 'Ascending') { $script:sortDir = 'Descending' }
            else { $script:sortProp = $prop; $script:sortDir = 'Ascending' }
            Apply-Sort
        }
    }
})

# ---------- Background metadata for the Details columns (current folder) ----------
$script:colExif = $null
$script:colMap = @{}
$colTimer = New-Object System.Windows.Threading.DispatcherTimer
$colTimer.Interval = [TimeSpan]::FromMilliseconds(250)

function Stop-ColMeta {
    $colTimer.Stop()
    if ($script:colExif) { $script:colExif.Kill() }
    $script:colExif = $null
}

function Start-ColMeta($items) {
    Stop-ColMeta
    $map = @{}
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
    foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
    foreach ($it in $items) {
        if ($it.IsDir -or $it.IsCloud -or -not (Get-XmpMode $it)) { continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $lines.Add($tp) }
    }
    if ($map.Count -eq 0) { return }
    $argFile = Join-Path $root 'cache\_cols_args.txt'
    [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
    $script:colMap = $map
    $x = New-Object AsyncExif
    $script:colExif = $x
    $x.Start($cfg.ExifToolPath, $argFile)
    $colTimer.Start()
}

$colTimer.Add_Tick({
    try {
        $x = $script:colExif
        if (-not $x) { $colTimer.Stop(); return }
        if (-not $x.Done) { return }
        $colTimer.Stop()
        $json = $x.Output
        $map = $script:colMap
        $script:colExif = $null
        if ($json -and $json.Trim()) {
            Add-Type -AssemblyName System.Web.Extensions
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $js.MaxJsonLength = [int]::MaxValue
            $objs = $js.DeserializeObject($json)
            foreach ($o in $objs) {
                $key = (([string]$o['SourceFile']) -replace '/', '\').ToLowerInvariant()
                $it = $map[$key]
                if (-not $it) { continue }
                Set-ItemCols $it $o
                $script:metaText[$it.FullPath] = (Get-AllText $o)
            }
            $script:metaReady = $true
        }
    } catch { Write-Log $_.Exception.ToString() }
})

function Update-SavedCols {
    try {
        $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir -and (Get-XmpMode $_) })
        if ($sel.Count -eq 0) { return }
        $map = @{}
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        foreach ($it in $sel) {
            $tp = Get-MetaTarget $it
            if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $cmd += $tp }
        }
        if ($map.Count -eq 0) { return }
        $json = $script:et.Run([string[]]$cmd)
        if (-not $json.Trim()) { return }
        $objs = @()
        $objs += (ConvertFrom-Json $json)
        foreach ($o in $objs) {
            $key = (("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()
            $it = $map[$key]
            if ($it) { Set-ItemCols $it $o }
        }
    } catch { Write-Log $_.Exception.ToString() }
}

# ---------- Redefined: shell thumbnails skip cloud-only files ----------
function Start-ShellThumbs($items, $includeJpg = $false) {
    Stop-ShellThumbs
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($it in $items) {
        if ($it.IsDir -or $it.IsCloud) { continue }
        if ($it.IsJpg -and -not $includeJpg) { continue }
        if ($it.Thumb) { continue }
        $paths.Add($it.FullPath)
        $script:shellMap[$it.FullPath] = $it
    }
    if ($paths.Count -eq 0) { return }
    $w = New-Object ShellThumbWorker
    $script:shellWorker = $w
    $w.Start($paths.ToArray(), 160)
    $shellTimer.Start()
}

function After-FolderLoad($items) {
    $script:folderItems = $items
    Start-ShellThumbs $items
    Reset-Search
    Start-ColMeta $items
}

# ---------- Redefined: subfolder search (cloud-safe, fills columns) ----------
function New-ItemFromPath($path, $sroot) {
    try {
        $f = New-Object IO.FileInfo $path
        $ext = $f.Extension.TrimStart('.').ToUpper()
        if (-not $ext) { $ext = 'FILE' }
        if ($ext.Length -gt 9) { $ext = $ext.Substring(0, 9) }
        $i = New-Object FileItem
        $i.Name = $f.Name; $i.FullPath = $f.FullName; $i.Size = $f.Length; $i.Created = $f.CreationTime
        $i.Badge = $ext
        $i.BadgeColor = if ($colors.ContainsKey($ext)) { $colors[$ext] } else { '#3B9AF5' }
        $i.IsJpg = ($ext -eq 'JPG' -or $ext -eq 'JPEG')
        $i.IsCloud = ((([int]$f.Attributes) -band 0x441000) -ne 0)
        $i.SizeText = Format-Size $f.Length
        $i.CreatedText = $f.CreationTime.ToString('dd/MM/yyyy HH:mm')
        $d = $f.DirectoryName
        $i.FolderText = if ($d.Length -gt $sroot.Length) { $d.Substring($sroot.Length).TrimStart('\') } else { '.' }
        return $i
    } catch { return $null }
}

$script:deepFields = @{}
$script:deepExifStarted = $false

function Import-DeepMeta($w, $json) {
    if (-not $json -or -not $json.Trim()) { return }
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $objs = $js.DeserializeObject($json)
    foreach ($o in $objs) {
        $sf = ([string]$o['SourceFile']) -replace '/', '\'
        $txt = Get-AllText $o
        if ($txt) { $w.Meta[$sf] = $txt }
        $script:deepFields[$sf.ToLowerInvariant()] = $o
    }
}

function Show-DeepResults {
    $w = $script:deepWalker
    if (-not $w -or $script:searchTerms.Count -eq 0) { return }
    $paths = $w.Filter([string[]]$script:searchTerms, 2000)
    $items = New-Object 'System.Collections.Generic.List[FileItem]'
    foreach ($pth in $paths) {
        $i = New-ItemFromPath $pth $script:deepRoot
        if ($i) {
            $o = $script:deepFields[$pth.ToLowerInvariant()]
            if ($o) { Set-ItemCols $i $o }
            $items.Add($i)
        }
    }
    $script:deepActive = $true
    $list.ItemsSource = $items
    Set-FolderCol $true
    Apply-Sort
    Start-ShellThumbs $items $true
    $more = ''
    if ($paths.Count -ge 2000) { $more = ' (first 2000 shown)' }
    $txtStatus.Text = "$($items.Count) match(es) in subfolders$more for '$($txtSearch.Text.Trim())'   |   $($w.FileCount) files searched"
}

function Start-Deep {
    $sroot = $txtPath.Text
    if (-not $sroot -or -not [IO.Directory]::Exists($sroot)) { return }
    if ([IO.Path]::GetPathRoot($sroot).TrimEnd('\') -ieq $sroot.TrimEnd('\')) {
        $txtStatus.Text = 'Subfolder search needs a folder, not a whole drive.'
        return
    }
    $script:deepRoot = $sroot
    $script:deepReady = $false
    $script:deepExifStarted = $false
    $script:deepExif = $null
    $script:deepFields = @{}
    $w = New-Object DeepWalker2
    $script:deepWalker = $w
    $w.Start($sroot, 100000, [string[]]$script:xmpEmbedded)
    $txtStatus.Text = 'Searching subfolders...'
    $deepTimer.Start()
}

$deepTimer = New-Object System.Windows.Threading.DispatcherTimer
$deepTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$deepTimer.Add_Tick({
    try {
        $w = $script:deepWalker
        if (-not $w) { $deepTimer.Stop(); return }
        if (-not $w.Done) { $txtStatus.Text = "Searching subfolders... $($w.Count) files scanned"; return }
        if (-not $script:deepExifStarted) {
            $script:deepExifStarted = $true
            $rd = @($w.Readable)
            if ($rd.Count -gt 0) {
                $lines = New-Object 'System.Collections.Generic.List[string]'
                foreach ($a in '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
                foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
                foreach ($r in $rd) { $lines.Add($r) }
                $argFile = Join-Path $root 'cache\_deep_args.txt'
                [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
                $x0 = New-Object AsyncExif
                $script:deepExif = $x0
                $x0.Start($cfg.ExifToolPath, $argFile)
                return
            }
        }
        $x = $script:deepExif
        if ($x -and -not $x.Done) { $txtStatus.Text = "Reading XMP from $(@($w.Readable).Count) files..."; return }
        $deepTimer.Stop()
        if ($x) { Import-DeepMeta $w $x.Output }
        $script:deepReady = $true
        $script:metaReady = $true
        Show-DeepResults
    } catch {
        $deepTimer.Stop()
        $txtStatus.Text = 'Subfolder search error: ' + $_.Exception.Message
        Write-Log $_.Exception.ToString()
    }
})

# ---------- Open / rename / copy path / show in Explorer ----------
$script:execExt = @('exe', 'bat', 'cmd', 'ps1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'msi', 'com', 'scr', 'lnk', 'reg', 'jar')

function Open-Items($items) {
    $items = @($items)
    if ($items.Count -eq 1 -and $items[0].IsDir) { Go-Path $items[0].FullPath; return }
    $files = @($items | Where-Object { -not $_.IsDir })
    if ($files.Count -eq 0) { return }
    if ($files.Count -gt 5) {
        if ((Msg "Open $($files.Count) files?" 'YesNo' 'Question') -ne 'Yes') { return }
    }
    foreach ($f in $files) {
        $ext = [IO.Path]::GetExtension($f.Name).TrimStart('.').ToLower()
        if ($script:execExt -contains $ext) {
            if ((Msg "Run '$($f.Name)'?" 'YesNo' 'Warning') -ne 'Yes') { continue }
        }
        try { Start-Process -FilePath $f.FullPath -WorkingDirectory ([IO.Path]::GetDirectoryName($f.FullPath)) }
        catch { $txtStatus.Text = "Cannot open $($f.Name): $($_.Exception.Message)" }
    }
}

function Do-ShowInExplorer {
    $sel = @($list.SelectedItems)
    if ($sel.Count -eq 0) {
        if ($txtPath.Text) { Start-Process explorer.exe -ArgumentList ('"' + $txtPath.Text + '"') }
        return
    }
    Start-Process explorer.exe -ArgumentList ('/select,"' + $sel[0].FullPath + '"')
}

function Do-CopyPath {
    $paths = @($list.SelectedItems | ForEach-Object { $_.FullPath })
    if ($paths.Count -eq 0) { return }
    [System.Windows.Clipboard]::SetText(($paths -join "`r`n"))
    $txtStatus.Text = "Copied $($paths.Count) path(s) to clipboard"
}

function Do-Rename {
    $sel = @($list.SelectedItems)
    if ($sel.Count -ne 1) { $txtStatus.Text = 'Select one item to rename.'; return }
    $it = $sel[0]
    $new = Read-Input 'Rename' 'New name:' $it.Name
    if ([string]::IsNullOrWhiteSpace($new)) { return }
    $new = $new.Trim()
    if ($new -ceq $it.Name) { return }
    if ($new.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { [void](Msg 'That name contains invalid characters.' 'OK' 'Warning'); return }
    $target = Join-Path ([IO.Path]::GetDirectoryName($it.FullPath)) $new
    if ((Test-Path -LiteralPath $target) -and ($new -ine $it.Name)) { [void](Msg 'A file or folder with that name already exists.' 'OK' 'Warning'); return }
    Stop-Thumbs
    Stop-ColMeta
    try { Rename-Item -LiteralPath $it.FullPath -NewName $new -ErrorAction Stop }
    catch { [void](Msg ("Rename failed: " + $_.Exception.Message) 'OK' 'Warning') }
    if ($script:deepActive) { $script:metaReady = $false; Apply-Search } else { Refresh-All }
    $txtStatus.Text = "Renamed to '$new'"
}

# double-click a file to open it
$list.Add_MouseDoubleClick({
    param($s, $e)
    try {
        $dep = $e.OriginalSource -as [System.Windows.DependencyObject]
        if (-not $dep) { return }
        $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($list, $dep)
        if ($c -and $c.Content -and -not $c.Content.IsDir) { Open-Items @($c.Content) }
    } catch { }
})

# right-click selects the item under the pointer
$list.Add_PreviewMouseRightButtonDown({
    param($s, $e)
    try {
        $dep = $e.OriginalSource -as [System.Windows.DependencyObject]
        if (-not $dep) { return }
        $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($list, $dep)
        if ($c -and -not $c.IsSelected) { $list.SelectedItems.Clear(); $c.IsSelected = $true }
    } catch { }
})

# context menu
$cm = New-Object System.Windows.Controls.ContextMenu
$menuDefs = @(
    @{ H = 'Open';              A = { Open-Items @($list.SelectedItems) } },
    @{ H = 'Show in Explorer';  A = { Do-ShowInExplorer } },
    @{ H = 'Copy path';         A = { Do-CopyPath } },
    @{ H = 'Rename          F2'; A = { Do-Rename } },
    @{ H = '-' },
    @{ H = 'Cut';               A = { Set-ClipFiles (Get-SelPaths) $true } },
    @{ H = 'Copy';              A = { Set-ClipFiles (Get-SelPaths) $false } },
    @{ H = 'Paste';             A = { Do-Paste } },
    @{ H = 'Delete';            A = { Do-Delete } }
)
foreach ($d in $menuDefs) {
    if ($d.H -eq '-') { [void]$cm.Items.Add((New-Object System.Windows.Controls.Separator)); continue }
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $d.H
    $mi.Add_Click($d.A)
    [void]$cm.Items.Add($mi)
}
$list.ContextMenu = $cm

# Enter opens files, F2 renames
$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
    if (-not $list.IsKeyboardFocusWithin) { return }
    if ($e.Key -eq 'F2') { Do-Rename; $e.Handled = $true }
    elseif ($e.Key -eq 'Return') {
        $sel = @($list.SelectedItems)
        if ($sel.Count -gt 0) { Open-Items $sel; $e.Handled = $true }
    }
})

# ---------- OneDrive in the left panel ----------
$od = @()
foreach ($v in $env:OneDriveConsumer, $env:OneDriveCommercial, $env:OneDrive) {
    if ($v -and [IO.Directory]::Exists($v) -and ($od -notcontains $v)) { $od += $v }
}
if ($od.Count -eq 0 -and $env:USERPROFILE) {
    $fb = Join-Path $env:USERPROFILE 'OneDrive'
    if ([IO.Directory]::Exists($fb)) { $od += $fb }
}
$pos = 0
foreach ($v in $od) {
    $n = Add-Node $tree.Items $v ([IO.Path]::GetFileName($v.TrimEnd('\')))
    $tree.Items.Remove($n)
    $tree.Items.Insert($pos, $n)
    $pos++
}

# ---------- Remember window size/position and last folder ----------
$st = $null
if ([IO.File]::Exists($settingsFile)) { try { $st = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch { } }
$script:lastFolder = $null
if ($st) {
    try {
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
        $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
        $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($st.Width -ge 700 -and $st.Height -ge 400 -and $st.Left -ge ($vl - 50) -and $st.Top -ge ($vt - 50) -and ($st.Left + 200) -le ($vl + $vw) -and ($st.Top + 100) -le ($vt + $vh)) {
            $win.WindowStartupLocation = 'Manual'
            $win.Left = [double]$st.Left; $win.Top = [double]$st.Top
            $win.Width = [double]$st.Width; $win.Height = [double]$st.Height
        }
        if ($st.Maximized) { $win.WindowState = 'Maximized' }
        if ($st.LastFolder) { $script:lastFolder = [string]$st.LastFolder }
    } catch { }
}
$win.Add_ContentRendered({
    if ($script:lastFolder -and [IO.Directory]::Exists($script:lastFolder)) {
        try { Select-TreePath $script:lastFolder } catch { }
    }
    $script:lastFolder = $null
})
$win.Add_Closing({
    try {
        if ($win.WindowState -eq 'Normal') { $b = [System.Windows.Rect]::new($win.Left, $win.Top, $win.Width, $win.Height) } else { $b = $win.RestoreBounds }
        $o = [ordered]@{ Left = $b.Left; Top = $b.Top; Width = $b.Width; Height = $b.Height; Maximized = ($win.WindowState -eq 'Maximized'); LastFolder = $txtPath.Text }
        $o | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
    } catch { }
    try { Stop-ColMeta; $script:deepReady = $false; Stop-Deep } catch { }
})

Show-Metadata
# ===== END SCRIPT8 =====
# ===== SCRIPT9-MARKER =====
$script:tileSize = 100
$script:loadedPx = 160
$script:shellPx = 160
$st9 = $null
if ([IO.File]::Exists($settingsFile)) { try { $st9 = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch { } }
if ($st9 -and $st9.TileSize) { try { $script:tileSize = [Math]::Max(70, [Math]::Min(300, [int]$st9.TileSize)) } catch { } }

function Get-NeededPx {
    $px = [int]([Math]::Ceiling($script:tileSize * 1.5 / 32) * 32)
    return [Math]::Max(160, [Math]::Min(512, $px))
}

# ---------- Tile templates generated for the chosen size ----------
function Set-TileResources {
    $S = [int]$script:tileSize
    $fs = [Math]::Max(13, [Math]::Min(22, [int](14 + $S / 50)))
    $map = @{
        '@@S@@'  = "$S"
        '@@BW@@' = "$($S + 52)"
        '@@BH@@' = "$($S + 78)"
        '@@TW@@' = "$($S + 36)"
        '@@FS@@' = "$fs"
        '@@MH@@' = "$([int]($fs * 2.9))"
        '@@BF@@' = "$([Math]::Max(10, [int](12 * $S / 100)))"
    }
    $tpl = @"
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <StackPanel Margin="8,6" HorizontalAlignment="Center">
    <Grid Width="@@S@@" Height="@@S@@">
      <Border CornerRadius="8" Background="{Binding BadgeColor}">
        <TextBlock Text="{Binding Badge}" Foreground="White" FontWeight="Bold" FontSize="@@BF@@"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <Image Source="{Binding Thumb}" Stretch="UniformToFill"/>
    </Grid>
    <TextBlock Text="{Binding Name}" ToolTip="{Binding FullPath}" Width="@@TW@@" TextAlignment="Center"
               TextTrimming="CharacterEllipsis" Margin="0,6,0,0" FontSize="@@FS@@" TextWrapping="Wrap" MaxHeight="@@MH@@"/>
  </StackPanel>
</DataTemplate>
"@
    $sty = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ListViewItem">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ListViewItem">
        <Border x:Name="bd" Width="@@BW@@" Height="@@BH@@" Margin="1" BorderThickness="1" BorderBrush="Transparent" Background="Transparent">
          <ContentPresenter/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E6F0FB"/><Setter TargetName="bd" Property="BorderBrush" Value="#B8D4F0"/></Trigger>
          <Trigger Property="IsSelected" Value="True">
            <Setter TargetName="bd" Property="Background" Value="#C9E2FB"/>
            <Setter TargetName="bd" Property="BorderBrush" Value="#1F6FD0"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
"@
    foreach ($k in @($map.Keys)) { $tpl = $tpl.Replace($k, $map[$k]); $sty = $sty.Replace($k, $map[$k]) }
    $win.Resources['tileTemplate'] = [Windows.Markup.XamlReader]::Parse($tpl)
    $win.Resources['tileStyle'] = [Windows.Markup.XamlReader]::Parse($sty)
}

# ---------- Redefined: shell thumbnails at a requested pixel size ----------
function Start-ShellThumbs($items, $includeJpg = $false, $force = $false, $px = 0) {
    Stop-ShellThumbs
    if ($px -le 0) { $px = Get-NeededPx }
    $script:shellPx = $px
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($it in $items) {
        if ($it.IsDir -or $it.IsCloud) { continue }
        if ($it.IsJpg -and -not $includeJpg) { continue }
        if ($it.Thumb -and -not $force) { continue }
        $paths.Add($it.FullPath)
        $script:shellMap[$it.FullPath] = $it
    }
    if ($paths.Count -eq 0) { return }
    $w = New-Object ShellThumbWorker
    $script:shellWorker = $w
    $w.Start($paths.ToArray(), [int]$px)
    $shellTimer.Start()
}

function New-IconTile($icon) {
    $size = [int]$script:shellPx
    if ($size -lt 64) { $size = 160 }
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $bg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(238, 242, 247))
    $dc.DrawRectangle($bg, $null, [System.Windows.Rect]::new(0, 0, $size, $size))
    $w = $size * 0.7
    $dc.DrawImage($icon, [System.Windows.Rect]::new(($size - $w) / 2, ($size - $w) / 2, $w, $w))
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    return $rtb
}

function After-FolderLoad($items) {
    $script:folderItems = $items
    $px = Get-NeededPx
    $script:loadedPx = $px
    Start-ShellThumbs $items ($px -gt 160) $false $px
    Reset-Search
    Start-ColMeta $items
}

function Upgrade-Thumbs {
    $px = Get-NeededPx
    if ($px -le $script:loadedPx) { return }
    $script:loadedPx = $px
    $items = @($list.ItemsSource)
    if ($items.Count -eq 0) { return }
    Start-ShellThumbs $items $true $true $px
}

function Apply-TileSize {
    Set-TileResources
    if ($rbThumbs.IsChecked) { Apply-View }
    Upgrade-Thumbs
}

# ---------- Slider + Ctrl/wheel ----------
$sizeSlider = New-Object System.Windows.Controls.Slider
$sizeSlider.Minimum = 70
$sizeSlider.Maximum = 300
$sizeSlider.Value = $script:tileSize
$sizeSlider.Width = 120
$sizeSlider.VerticalAlignment = 'Center'
$sizeSlider.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
$sizeSlider.IsMoveToPointEnabled = $true
$sizeSlider.ToolTip = 'Thumbnail size (Ctrl + mouse wheel also works)'
$dpTop = $rbThumbs.Parent
$dpTop.Children.Insert($dpTop.Children.IndexOf($rbThumbs) + 1, $sizeSlider)
if ($rbThumbs.IsChecked) { $sizeSlider.Visibility = 'Visible' } else { $sizeSlider.Visibility = 'Collapsed' }
$rbThumbs.Add_Checked({ $sizeSlider.Visibility = 'Visible' })
$rbThumbs.Add_Unchecked({ $sizeSlider.Visibility = 'Collapsed' })

$sizeTimer = New-Object System.Windows.Threading.DispatcherTimer
$sizeTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$sizeTimer.Add_Tick({ $sizeTimer.Stop(); Apply-TileSize })
$sizeSlider.Add_ValueChanged({
    $script:tileSize = [int]$sizeSlider.Value
    $sizeTimer.Stop()
    $sizeTimer.Start()
})

$list.Add_PreviewMouseWheel({
    param($s, $e)
    $m = [int][System.Windows.Input.Keyboard]::Modifiers
    if ((($m -band 2) -ne 0) -and $rbThumbs.IsChecked) {
        $v = $sizeSlider.Value + ([Math]::Sign($e.Delta) * 15)
        $sizeSlider.Value = [Math]::Max(70, [Math]::Min(300, $v))
        $e.Handled = $true
    }
})

# remember the size
$win.Add_Closing({
    try {
        if ([IO.File]::Exists($settingsFile)) {
            $o = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ($o.PSObject.Properties['TileSize']) { $o.TileSize = [int]$script:tileSize }
            else { $o | Add-Member -NotePropertyName TileSize -NotePropertyValue ([int]$script:tileSize) }
            $o | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
        }
    } catch { }
})

Set-TileResources
# ===== END SCRIPT9 =====
# ===== SCRIPT11-MARKER =====
$btnHelp      = $win.FindName('btnHelp')
$btnTagAdd    = $win.FindName('btnTagAdd')
$btnTagRemove = $win.FindName('btnTagRemove')
$btnCrUse     = $win.FindName('btnCrUse')
$btnCrSet     = $win.FindName('btnCrSet')
$script:crPreset = ''
$script:metaClip = @()

function Set-Setting($name, $value) {
    try {
        $o = $null
        if ([IO.File]::Exists($settingsFile)) { $o = Get-Content $settingsFile -Raw | ConvertFrom-Json }
        if (-not $o) { $o = [pscustomobject]@{} }
        if ($o.PSObject.Properties[$name]) { $o.$name = $value } else { $o | Add-Member -NotePropertyName $name -NotePropertyValue $value }
        $o | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
    } catch { }
}

function Get-ChangedNames($changes) {
    $map = @{ Title = 'Title'; Headline = 'Subject'; Creator = 'Authors'; Subject = 'Tags'; Description = 'Comments'; Rights = 'Copyright'; Rating = 'Rating' }
    $names = @()
    foreach ($c in @($changes)) {
        $t = ([string]$c).TrimStart('-')
        if ($t -match '^[^:=+]*:([A-Za-z]+)') { $k = $Matches[1]; if ($map.ContainsKey($k)) { $names += $map[$k] } }
    }
    $names = @($names | Select-Object -Unique)
    if ($names.Count -eq 0) { return 'XMP' }
    return ($names -join ', ')
}

function Get-SelXmp { @($list.SelectedItems | Where-Object { -not $_.IsDir -and (Get-XmpMode $_) }) }

# ---------- Generic XMP write (rating, tags, paste metadata) - result goes to the status bar ----------
function Invoke-XmpWrite($sel, $changes, $label) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($it in $sel) {
        if ((Get-XmpMode $it) -eq 'sidecar') {
            $tp = Get-MetaTarget $it
            if (-not [IO.File]::Exists($tp)) { [IO.File]::WriteAllText($tp, $script:emptyXmp, (New-Object Text.UTF8Encoding($false))) }
        }
    }
    $cmd = @('-charset', 'utf8', '-charset', 'filename=utf8', '-P', '-m')
    if (-not $cfg.KeepBackups) { $cmd += '-overwrite_original' }
    $cmd += $changes
    $cmd += (Get-Targets $sel)
    $out = $script:et.Run([string[]]$cmd)
    $err = $script:et.LastError
    $n = 0
    if ($out -match '(\d+) image files updated') { $n = [int]$Matches[1] }
    $msg = "$label $n file(s) in $($sw.ElapsedMilliseconds) ms"
    if ($n -eq 0 -and -not $err) { $msg += '  |  nothing changed' }
    if ($err) { $msg += '  |  ' + (($err -split "`n")[0]); Write-Log $err }
    Write-Log ('XMPWRITE cmd: ' + ($cmd -join ' | '))
    $script:metaReady = $false
    Update-SavedCols
    Show-Metadata
    $txtStatus.Text = $msg
}

# ---------- Rating keys 1-5 (0 clears) ----------
function Set-Rating([int]$n) {
    $sel = @(Get-SelXmp)
    if ($sel.Count -eq 0) { $txtStatus.Text = 'Select one or more files first.'; return }
    if ($n -eq 0) { $ch = @('-XMP-xmp:Rating='); $what = 'Cleared rating on' }
    else { $ch = @("-XMP-xmp:Rating=$n"); $what = "Set rating to $n on" }
    Invoke-XmpWrite $sel $ch $what
}

# ---------- Bulk add / remove tags ----------
function Do-TagEdit([string]$mode) {
    $sel = @(Get-SelXmp)
    if ($sel.Count -eq 0) { $txtStatus.Text = 'Select one or more files first.'; return }
    if ($mode -eq 'add') { $ttl = 'Add tags'; $prm = "Tags to ADD to $($sel.Count) file(s) (separate with commas):" }
    else { $ttl = 'Remove tags'; $prm = "Tags to REMOVE from $($sel.Count) file(s) (separate with commas):" }
    $txt = Read-Input $ttl $prm ''
    if ([string]::IsNullOrWhiteSpace($txt)) { return }
    $tags = @($txt -split '\s*[,;]\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($tags.Count -eq 0) { return }
    $op = if ($mode -eq 'add') { '+=' } else { '-=' }
    $ch = @()
    foreach ($t in $tags) { $ch += ('-XMP-dc:Subject' + $op + $t) }
    $tagText = $tags -join ', '
    $label = if ($mode -eq 'add') { "Added tag(s) $tagText to" } else { "Removed tag(s) $tagText from" }
    Invoke-XmpWrite $sel $ch $label
}

# ---------- Copyright preset ----------
function Do-CrSet {
    $v = Read-Input 'Copyright preset' 'Copyright text to use as your preset:' $script:crPreset
    if ($null -eq $v) { return }
    $script:crPreset = ([string]$v).Trim()
    Set-Setting 'CopyrightPreset' $script:crPreset
    $txtStatus.Text = "Copyright preset saved: $($script:crPreset)"
}
function Do-CrUse {
    if (-not $script:crPreset) { Do-CrSet; if (-not $script:crPreset) { return } }
    if (-not $txtCopyright.IsEnabled) { $txtStatus.Text = 'Select a file that supports XMP first.'; return }
    $txtCopyright.Text = $script:crPreset
    $txtStatus.Text = 'Copyright preset inserted - press Save (Ctrl+S) to write it to the selected file(s).'
}

# ---------- Copy metadata from one file, paste to others ----------
function Do-MetaCopy {
    $sel = @(Get-SelXmp)
    if ($sel.Count -ne 1) { $txtStatus.Text = 'Select exactly one file to copy metadata from.'; return }
    $tp = Get-MetaTarget $sel[0]
    if (-not [IO.File]::Exists($tp)) { $txtStatus.Text = 'That file has no XMP metadata yet.'; return }
    $cmd = @('-j', '-charset', 'filename=utf8')
    foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
    $cmd += $tp
    $json = $script:et.Run([string[]]$cmd)
    if (-not $json.Trim()) { $txtStatus.Text = 'Could not read metadata.'; return }
    $o = @(ConvertFrom-Json $json)[0]
    $clip = @()
    $keys = @()
    foreach ($f in $fields) {
        $v = $o.($f.Key)
        if ($null -eq $v -or "$v" -eq '') { continue }
        if ($v -is [array]) { $its = @($v | ForEach-Object { ("$_" -replace '[\r\n]+', ' ') }) } else { $its = @(("$v" -replace '[\r\n]+', ' ')) }
        $clip += @{ Tag = $f.Tag; Items = $its }
        $keys += ('-' + $f.Tag)
    }
    $script:metaClip = $clip
    if ($clip.Count -eq 0) { $txtStatus.Text = "No metadata found on $($sel[0].Name) to copy."; return }
    $txtStatus.Text = "Copied metadata from $($sel[0].Name): " + (Get-ChangedNames $keys) + '  (right-click other files > Paste metadata)'
}
function Do-MetaPaste {
    if ($script:metaClip.Count -eq 0) { $txtStatus.Text = 'Nothing copied yet. Right-click a file > Copy metadata first.'; return }
    $sel = @(Get-SelXmp)
    if ($sel.Count -eq 0) { $txtStatus.Text = 'Select one or more files to paste metadata onto.'; return }
    $ch = @()
    foreach ($c in $script:metaClip) { foreach ($i in $c.Items) { $ch += ('-' + $c.Tag + '=' + $i) } }
    Invoke-XmpWrite $sel $ch ('Pasted ' + (Get-ChangedNames $ch) + ' to')
}

# ---------- Rating column in Details ----------
function Set-ItemCols($it, $o) {
    $it.TitleText   = Get-FieldText $o 'Title'
    $it.SubjectText = Get-FieldText $o 'Headline'
    $it.AuthorText  = Get-FieldText $o 'Creator'
    $it.TagsText    = Get-FieldText $o 'Subject'
    $r = 0
    [void][int]::TryParse((Get-FieldText $o 'Rating'), [ref]$r)
    if ($r -gt 0) { $it.RatingText = ([string][char]0x2605) * [Math]::Min(5, $r) } else { $it.RatingText = '' }
}
$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource
    if ($h -is [System.Windows.Controls.GridViewColumnHeader] -and $h.Role -ne 'Padding' -and "$($h.Content)" -eq 'Rating') {
        if ($script:sortProp -eq 'RatingText' -and $script:sortDir -eq 'Ascending') { $script:sortDir = 'Descending' }
        else { $script:sortProp = 'RatingText'; $script:sortDir = 'Ascending' }
        Apply-Sort
    }
})

# ---------- Help ----------
$script:helpText = (@(
'METADATAEDITOR - QUICK HELP',
'',
'EDITING METADATA',
'Select one or more files, edit the fields on the right, then press SAVE METADATA or Ctrl+S.',
'A yellow field means the selected files have different values. Leave it alone to keep each file as it is, or type to set them all.',
'Only XMP is written. The status bar at the bottom tells you what was done - there are no popups.',
'',
'RATINGS',
'Click a file (or several) and press 1-5 to set the rating at once. Press 0 to clear it.',
'Details view has a Rating column (click the header to sort).',
'',
'TAGS',
'+ Add tags / - Remove tags (under the Tags box) add or remove tags on ALL selected files, keeping each file''s other tags.',
'Tag names must match exactly when removing.',
'',
'COPYRIGHT',
'Set preset... stores your copyright text. Insert preset puts it in the Copyright box - then Save.',
'',
'COPY METADATA BETWEEN FILES',
'Right-click a file > Copy metadata. Select other files > right-click > Paste metadata.',
'Only fields that have a value are copied, and they replace the same fields on the target files.',
'',
'VIEWS AND SEARCH',
'Details or Thumbnails - your choice is remembered. Thumbnail size: slider or Ctrl + mouse wheel.',
'Search box (top right) looks in file names and XMP. Tick Subfolders to search below the current folder.',
'',
'FILES',
'Double-click or Enter opens a file. F2 renames. Delete sends to the Recycle Bin. F5 refreshes.',
'Alt+Left / Alt+Right go back and forward. Ctrl+C / Ctrl+X / Ctrl+V copy, cut and paste files.',
'Online-only OneDrive files are skipped for previews so nothing is downloaded.',
'',
'Press F1 any time to open this help. Esc closes it.'
) -join "`n")

function Show-Help {
    $w = New-Object System.Windows.Window
    $w.Title = 'MetadataEditor - Help'
    $w.Width = 640; $w.Height = 700
    $w.Owner = $win; $w.WindowStartupLocation = 'CenterOwner'
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $script:helpText
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize = 14
    $tb.Margin = [System.Windows.Thickness]::new(18)
    $sv.Content = $tb
    $w.Content = $sv
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    [void]$w.ShowDialog()
}

# ---------- Wiring ----------
$btnHelp.Add_Click({ Show-Help })
$btnTagAdd.Add_Click({ Do-TagEdit 'add' })
$btnTagRemove.Add_Click({ Do-TagEdit 'remove' })
$btnCrUse.Add_Click({ Do-CrUse })
$btnCrSet.Add_Click({ Do-CrSet })

function New-MenuItem($header, $action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    $mi.Add_Click($action)
    return $mi
}
$cm.Items.Insert(4, (New-Object System.Windows.Controls.Separator))
$cm.Items.Insert(5, (New-MenuItem 'Copy metadata' { Do-MetaCopy }))
$cm.Items.Insert(6, (New-MenuItem 'Paste metadata' { Do-MetaPaste }))

function Update-ActionButtons {
    $on = (@(Get-SelXmp).Count -gt 0)
    foreach ($b in @($btnTagAdd, $btnTagRemove, $btnCrUse)) { $b.IsEnabled = $on }
}
$list.Add_SelectionChanged({ Update-ActionButtons })
Update-ActionButtons

$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'F1') { Show-Help; $e.Handled = $true; return }
    if ($e.OriginalSource -is [System.Windows.Controls.TextBox]) { return }
    if (-not $list.IsKeyboardFocusWithin) { return }
    if ([int][System.Windows.Input.Keyboard]::Modifiers -ne 0) { return }
    if ("$($e.Key)" -match '^(D|NumPad)([0-5])$') { Set-Rating ([int]$Matches[2]); $e.Handled = $true }
})

# ---------- Remember view + copyright preset ----------
$st11 = $null
if ([IO.File]::Exists($settingsFile)) { try { $st11 = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch { } }
if ($st11) {
    if ($st11.CopyrightPreset) { $script:crPreset = [string]$st11.CopyrightPreset }
    if ($st11.ViewMode -eq 'Thumbnails') { $rbThumbs.IsChecked = $true }
}
$win.Add_Closing({
    try {
        $vm = 'Details'
        if ($rbThumbs.IsChecked) { $vm = 'Thumbnails' }
        Set-Setting 'ViewMode' $vm
        Set-Setting 'CopyrightPreset' $script:crPreset
    } catch { }
})
# ===== END SCRIPT11 =====
# ===== SCRIPT12-MARKER =====
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ---------- m4a: embedded XMP ----------
$script:xmpEmbedded += 'm4a'

# ---------- Office files: native document properties (docProps/core.xml) ----------
$script:officeExt = @('docx', 'xlsx', 'pptx', 'docm', 'xlsm', 'pptm', 'dotx', 'xltx', 'potx')
$script:nsDc = 'http://purl.org/dc/elements/1.1/'
$script:nsCp = 'http://schemas.openxmlformats.org/package/2006/metadata/core-properties'
$script:officeMap = @{ Title = @('dc', 'title'); Headline = @('dc', 'subject'); Creator = @('dc', 'creator'); Subject = @('cp', 'keywords'); Description = @('dc', 'description') }

function Get-XmpMode($it) {
    if ($it.IsDir) { return $null }
    $x = [IO.Path]::GetExtension($it.Name).TrimStart('.').ToLowerInvariant()
    if ($script:xmpEmbedded -contains $x) { return 'embedded' }
    if ($script:xmpSidecar -contains $x) { return 'sidecar' }
    if ($script:officeExt -contains $x) { return 'office' }
    return $null
}

function Get-SelXmp {
    @($list.SelectedItems | Where-Object {
        if ($_.IsDir) { return $false }
        $m = Get-XmpMode $_
        return ($m -eq 'embedded' -or $m -eq 'sidecar')
    })
}

function Read-OfficeProps([string]$path) {
    $r = @{}
    $fs = $null; $za = $null
    try {
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read)
        $e = $za.GetEntry('docProps/core.xml')
        if ($e) {
            $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $sr.Dispose()
            $doc = New-Object Xml.XmlDocument
            $doc.LoadXml($txt)
            foreach ($n in $doc.DocumentElement.ChildNodes) {
                switch ($n.LocalName) {
                    'title'       { $r['Title'] = $n.InnerText }
                    'subject'     { $r['Headline'] = $n.InnerText }
                    'creator'     { $r['Creator'] = $n.InnerText }
                    'description' { $r['Description'] = $n.InnerText }
                    'keywords'    { $r['Subject'] = ((@($n.InnerText -split '\s*[;,]\s*' | Where-Object { $_ })) -join ', ') }
                }
            }
        }
    }
    catch { Write-Log ('Office read failed: ' + $path + ' ' + $_.Exception.Message) }
    finally {
        if ($za) { $za.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
    return $r
}

function Write-OfficeProps([string]$path, [hashtable]$vals) {
    $lw = [IO.File]::GetLastWriteTime($path)
    $fs = $null; $za = $null
    try {
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Update)
        $e = $za.GetEntry('docProps/core.xml')
        if (-not $e) { throw 'This file has no core properties part (docProps/core.xml).' }
        $s = $e.Open()
        $sr = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8, $true, 1024, $true)
        $txt = $sr.ReadToEnd()
        $sr.Dispose()
        $doc = New-Object Xml.XmlDocument
        $doc.PreserveWhitespace = $true
        $doc.LoadXml($txt)
        $root = $doc.DocumentElement
        foreach ($k in @($vals.Keys)) {
            $m = $script:officeMap[$k]
            if (-not $m) { continue }
            if ($m[0] -eq 'dc') { $ns = $script:nsDc } else { $ns = $script:nsCp }
            $val = [string]$vals[$k]
            $node = $null
            foreach ($c in $root.ChildNodes) {
                if ($c.LocalName -eq $m[1] -and $c.NamespaceURI -eq $ns) { $node = $c; break }
            }
            if ($val -eq '') {
                if ($node) { [void]$root.RemoveChild($node) }
            } else {
                if (-not $node) { $node = $doc.CreateElement($m[0], $m[1], $ns); [void]$root.AppendChild($node) }
                $node.InnerText = $val
            }
        }
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($doc.OuterXml)
        $s.Position = 0
        $s.SetLength(0)
        $s.Write($bytes, 0, $bytes.Length)
        $s.Dispose()
    }
    finally {
        if ($za) { $za.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
    [IO.File]::SetLastWriteTime($path, $lw)
}

# ---------- Metadata panel (XMP files + Office files) ----------
function Show-Metadata {
    $all = @($list.SelectedItems)
    $sel = @($all | Where-Object { Get-XmpMode $_ })
    $script:loaded = @{}
    $on = ($sel.Count -gt 0)
    foreach ($f in $fields) {
        $f.Ctl.Text = ''
        $f.Ctl.Background = [Windows.Media.Brushes]::White
        $f.Ctl.ToolTip = $null
        $f.Ctl.IsEnabled = $on
    }
    $btnSave.IsEnabled = $on
    $xsel = @($sel | Where-Object { (Get-XmpMode $_) -ne 'office' })
    $osel = @($sel | Where-Object { (Get-XmpMode $_) -eq 'office' })
    if ($on -and $xsel.Count -eq 0) {
        foreach ($f in $fields) {
            if ($f.Key -eq 'Rights' -or $f.Key -eq 'Rating') { $f.Ctl.IsEnabled = $false; $f.Ctl.ToolTip = 'Not stored in Office files' }
        }
    }
    $files = @($all | Where-Object { -not $_.IsDir })
    if ($files.Count -gt 0) {
        $nEmb  = @($sel | Where-Object { (Get-XmpMode $_) -eq 'embedded' }).Count
        $nSide = @($sel | Where-Object { (Get-XmpMode $_) -eq 'sidecar' }).Count
        $nOff  = $osel.Count
        $nNo   = $files.Count - $sel.Count
        $parts = @()
        if ($nEmb -gt 0)  { $parts += "$nEmb embedded" }
        if ($nSide -gt 0) { $parts += "$nSide in .xmp sidecar" }
        if ($nOff -gt 0)  { $parts += "$nOff Office properties" }
        if ($nNo -gt 0)   { $parts += "$nNo not supported" }
        $sysInfo.Text = ($sysInfo.Text -replace '\r?\nXMP:[^\r\n]*', '')
        $sysInfo.Text = $sysInfo.Text + "`nXMP: " + ($parts -join ', ')
    }
    if (-not $on) { return }

    $readPaths = @(); $missing = 0
    foreach ($tp in (Get-Targets $xsel)) {
        if ([IO.File]::Exists($tp)) { $readPaths += $tp } else { $missing++ }
    }
    $objs = @()
    if ($readPaths.Count -gt 0) {
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        $cmd += $readPaths
        $json = $script:et.Run([string[]]$cmd)
        if ($json.Trim()) { $objs += (ConvertFrom-Json $json) }
    }
    for ($i = 0; $i -lt $missing; $i++) { $objs += [pscustomobject]@{} }
    $oobjs = @()
    foreach ($it in $osel) { $oobjs += , (Read-OfficeProps $it.FullPath) }

    foreach ($f in $fields) {
        $src = @($objs)
        if ($f.Key -ne 'Rights' -and $f.Key -ne 'Rating') { $src = @($objs) + @($oobjs) }
        $vals = @()
        foreach ($o in $src) {
            $v = $o.($f.Key)
            if ($null -eq $v) { $vals += ''; continue }
            if ($v -is [array]) { $vals += (@($v | ForEach-Object { "$_" }) -join ', ') } else { $vals += "$v" }
        }
        $uniq = @($vals | Select-Object -Unique)
        if ($uniq.Count -le 1) {
            $text = ''
            if ($uniq.Count -eq 1) { $text = [string]$uniq[0] }
            $f.Ctl.Text = $text
            $script:loaded[$f.Key] = $text
        } else {
            $f.Ctl.Text = ''
            $script:loaded[$f.Key] = ''
            $f.Ctl.Background = [Windows.Media.Brushes]::LightYellow
            $f.Ctl.ToolTip = 'Selected files have different values. Leave empty to keep each, or type to set all.'
        }
    }
}

function Save-Metadata {
    $all = @($list.SelectedItems | Where-Object { -not $_.IsDir })
    $sel = @($all | Where-Object { Get-XmpMode $_ })
    if ($sel.Count -eq 0) { return }
    $xsel = @($sel | Where-Object { (Get-XmpMode $_) -ne 'office' })
    $osel = @($sel | Where-Object { (Get-XmpMode $_) -eq 'office' })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $changes = @(); $ochg = @{}; $tags = @()
    foreach ($f in $fields) {
        if ($f.Ctl.Text -ceq $script:loaded[$f.Key]) { continue }
        $new = $f.Ctl.Text.Trim()
        if ($f.Key -eq 'Rating' -and $new -ne '' -and $new -notmatch '^[0-5]$') {
            $txtStatus.Text = 'Rating must be a number from 0 to 5 (or empty).'
            return
        }
        $tags += ('-' + $f.Tag)
        if ($xsel.Count -gt 0) {
            if ($f.List) {
                if (-not $new) { $changes += ('-' + $f.Tag + '=') }
                foreach ($i in @($new -split '\s*[,;]\s*' | Where-Object { $_ })) { $changes += ('-' + $f.Tag + '=' + $i) }
            } else {
                $changes += ('-' + $f.Tag + '=' + $new)
            }
        }
        if ($f.Key -ne 'Rights' -and $f.Key -ne 'Rating') {
            if ($f.Key -eq 'Subject') { $ochg[$f.Key] = ((@($new -split '\s*[,;]\s*' | Where-Object { $_ })) -join '; ') }
            else { $ochg[$f.Key] = $new }
        }
    }
    if ($tags.Count -eq 0) { $txtStatus.Text = 'No changes to save.'; return }

    # XMP files (ExifTool)
    $n = 0; $err = ''
    if ($changes.Count -gt 0 -and $xsel.Count -gt 0) {
        foreach ($it in $xsel) {
            if ((Get-XmpMode $it) -eq 'sidecar') {
                $tp = Get-MetaTarget $it
                if (-not [IO.File]::Exists($tp)) { [IO.File]::WriteAllText($tp, $script:emptyXmp, (New-Object Text.UTF8Encoding($false))) }
            }
        }
        $cmd = @('-charset', 'utf8', '-charset', 'filename=utf8', '-P', '-m')
        if (-not $cfg.KeepBackups) { $cmd += '-overwrite_original' }
        $cmd += $changes
        $cmd += (Get-Targets $xsel)
        $out = $script:et.Run([string[]]$cmd)
        $err = $script:et.LastError
        if ($out -match '(\d+) image files updated') { $n = [int]$Matches[1] }
        Write-Log ('SAVE cmd: ' + ($cmd -join ' | '))
    }

    # Office files (native properties)
    $no = 0; $oerrs = @()
    if ($ochg.Count -gt 0) {
        foreach ($it in $osel) {
            try {
                if ($cfg.KeepBackups) {
                    $bk = $it.FullPath + '_original'
                    if (-not [IO.File]::Exists($bk)) { [IO.File]::Copy($it.FullPath, $bk) }
                }
                Write-OfficeProps $it.FullPath $ochg
                $no++
            } catch { $oerrs += ($it.Name + ': ' + $_.Exception.Message) }
        }
    }

    $msg = 'Saved ' + (Get-ChangedNames $tags) + " to $($n + $no) file(s) in $($sw.ElapsedMilliseconds) ms"
    if ($err) { $msg += '  |  ' + (($err -split "`n")[0]); Write-Log $err }
    if ($oerrs.Count -gt 0) { $msg += '  |  ' + $oerrs[0]; Write-Log ($oerrs -join "`n") }
    $script:metaReady = $false
    Update-SavedCols
    Show-Metadata
    $txtStatus.Text = $msg
}

# ---------- Details columns for Office files (read in small batches so the UI stays smooth) ----------
$script:offQueue = New-Object 'System.Collections.Generic.Queue[object]'
$offTimer = New-Object System.Windows.Threading.DispatcherTimer
$offTimer.Interval = [TimeSpan]::FromMilliseconds(30)
$offTimer.Add_Tick({
    try {
        $k = 0
        while ($k -lt 12 -and $script:offQueue.Count -gt 0) {
            $it = $script:offQueue.Dequeue()
            $k++
            $o = Read-OfficeProps $it.FullPath
            Set-ItemCols $it $o
            $script:metaText[$it.FullPath] = (Get-AllText $o)
        }
        if ($script:offQueue.Count -eq 0) { $offTimer.Stop() }
    } catch { $offTimer.Stop(); Write-Log $_.Exception.ToString() }
})

function Stop-ColMeta {
    $colTimer.Stop()
    if ($script:colExif) { $script:colExif.Kill() }
    $script:colExif = $null
    $offTimer.Stop()
    $script:offQueue.Clear()
}

function Start-ColMeta($items) {
    Stop-ColMeta
    $map = @{}
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
    foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
    foreach ($it in $items) {
        if ($it.IsDir -or $it.IsCloud) { continue }
        $mode = Get-XmpMode $it
        if (-not $mode) { continue }
        if ($mode -eq 'office') { $script:offQueue.Enqueue($it); continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $lines.Add($tp) }
    }
    if ($script:offQueue.Count -gt 0) { $offTimer.Start() }
    if ($map.Count -eq 0) { return }
    $argFile = Join-Path $root 'cache\_cols_args.txt'
    [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
    $script:colMap = $map
    $x = New-Object AsyncExif
    $script:colExif = $x
    $x.Start($cfg.ExifToolPath, $argFile)
    $colTimer.Start()
}

function Update-SavedCols {
    try {
        $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir -and (Get-XmpMode $_) })
        if ($sel.Count -eq 0) { return }
        foreach ($it in @($sel | Where-Object { (Get-XmpMode $_) -eq 'office' })) {
            Set-ItemCols $it (Read-OfficeProps $it.FullPath)
        }
        $map = @{}
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        foreach ($it in @($sel | Where-Object { (Get-XmpMode $_) -ne 'office' })) {
            $tp = Get-MetaTarget $it
            if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $cmd += $tp }
        }
        if ($map.Count -eq 0) { return }
        $json = $script:et.Run([string[]]$cmd)
        if (-not $json.Trim()) { return }
        $objs = @()
        $objs += (ConvertFrom-Json $json)
        foreach ($o in $objs) {
            $key = (("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()
            $it = $map[$key]
            if ($it) { Set-ItemCols $it $o }
        }
    } catch { Write-Log $_.Exception.ToString() }
}

# ---------- Search index (current folder) now includes Office properties ----------
function Build-MetaIndex {
    $script:metaText = @{}
    $byKey = @{}
    $oitems = @()
    foreach ($it in @($list.ItemsSource)) {
        if ($it.IsDir) { continue }
        $mode = Get-XmpMode $it
        if (-not $mode) { continue }
        if ($mode -eq 'office') { if (-not $it.IsCloud) { $oitems += $it }; continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $byKey[$tp.ToLowerInvariant()] = @{ Item = $it; Path = $tp } }
    }
    $all = @($byKey.Values | ForEach-Object { $_.Path })
    for ($i = 0; $i -lt $all.Count; $i += 150) {
        $chunk = @($all[$i..([Math]::Min($i + 149, $all.Count - 1))])
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        $cmd += $chunk
        $json = $script:et.Run([string[]]$cmd)
        if (-not $json.Trim()) { continue }
        $objs = @()
        $objs += (ConvertFrom-Json $json)
        foreach ($o in $objs) {
            $key = (("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()
            $entry = $byKey[$key]
            if (-not $entry) { continue }
            $parts = @()
            foreach ($f in $fields) {
                $v = $o.($f.Key)
                if ($null -eq $v) { continue }
                if ($v -is [array]) { $parts += (@($v | ForEach-Object { "$_" }) -join ' ') } else { $parts += "$v" }
            }
            $script:metaText[$entry.Item.FullPath] = ($parts -join ' ').ToLowerInvariant()
        }
    }
    foreach ($it in $oitems) {
        $script:metaText[$it.FullPath] = (Get-AllText (Read-OfficeProps $it.FullPath))
    }
    $script:metaReady = $true
}

# ---------- Help text ----------
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`nOFFICE FILES (docx, xlsx, pptx and similar)`nTitle, Subject, Authors, Tags and Comments are saved as native Office properties, so Word and Windows Explorer show them. Copyright and Rating are not stored in Office files, and the Tags buttons, rating keys and Copy/Paste metadata work on XMP files only.`nIf backups are switched on, a name_original copy is made first. A file that is open in Word cannot be saved - close it first.`n`nPress F1 any time")
# ===== END SCRIPT12 =====
# ===== SCRIPT13-MARKER =====
# ---------- Keyword history ----------
$script:tagSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function Add-TagHistory($tags) {
    foreach ($t in @($tags)) {
        $s = ([string]$t).Trim()
        if ($s -and $s.Length -le 80 -and $script:tagSet.Count -lt 3000) { [void]$script:tagSet.Add($s) }
    }
}

# load saved history
try {
    if ([IO.File]::Exists($settingsFile)) {
        $st13 = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($st13 -and $st13.TagHistory) { Add-TagHistory @($st13.TagHistory) }
    }
} catch { }

# ---------- Camera (read-only, from EXIF) + learn tags while loading columns ----------
function Get-AllText($o) {
    $parts = @()
    foreach ($f in $fields) { $s = Get-FieldText $o $f.Key; if ($s) { $parts += $s } }
    $m = Get-FieldText $o 'Model'
    if ($m) { $parts += $m }
    return (($parts -join ' ').ToLowerInvariant())
}

function Set-ItemCols($it, $o) {
    $it.TitleText   = Get-FieldText $o 'Title'
    $it.SubjectText = Get-FieldText $o 'Headline'
    $it.AuthorText  = Get-FieldText $o 'Creator'
    $it.TagsText    = Get-FieldText $o 'Subject'
    $r = 0
    [void][int]::TryParse((Get-FieldText $o 'Rating'), [ref]$r)
    if ($r -gt 0) { $it.RatingText = ([string][char]0x2605) * [Math]::Min(5, $r) } else { $it.RatingText = '' }
    $it.CameraText = Get-FieldText $o 'Model'
    if ($it.TagsText) { Add-TagHistory @($it.TagsText -split '\s*[,;]\s*') }
}

function Start-ColMeta($items) {
    Stop-ColMeta
    $map = @{}
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
    foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
    $lines.Add('-Model')
    foreach ($it in $items) {
        if ($it.IsDir -or $it.IsCloud) { continue }
        $mode = Get-XmpMode $it
        if (-not $mode) { continue }
        if ($mode -eq 'office') { $script:offQueue.Enqueue($it); continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $lines.Add($tp) }
    }
    if ($script:offQueue.Count -gt 0) { $offTimer.Start() }
    if ($map.Count -eq 0) { return }
    $argFile = Join-Path $root 'cache\_cols_args.txt'
    [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
    $script:colMap = $map
    $x = New-Object AsyncExif
    $script:colExif = $x
    $x.Start($cfg.ExifToolPath, $argFile)
    $colTimer.Start()
}

function Update-SavedCols {
    try {
        $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir -and (Get-XmpMode $_) })
        if ($sel.Count -eq 0) { return }
        foreach ($it in @($sel | Where-Object { (Get-XmpMode $_) -eq 'office' })) {
            Set-ItemCols $it (Read-OfficeProps $it.FullPath)
        }
        $map = @{}
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        $cmd += '-Model'
        foreach ($it in @($sel | Where-Object { (Get-XmpMode $_) -ne 'office' })) {
            $tp = Get-MetaTarget $it
            if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $cmd += $tp }
        }
        if ($map.Count -eq 0) { return }
        $json = $script:et.Run([string[]]$cmd)
        if (-not $json.Trim()) { return }
        $objs = @()
        $objs += (ConvertFrom-Json $json)
        foreach ($o in $objs) {
            $key = (("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()
            $it = $map[$key]
            if ($it) { Set-ItemCols $it $o }
        }
    } catch { Write-Log $_.Exception.ToString() }
}

# sort by Camera column
$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource
    if ($h -is [System.Windows.Controls.GridViewColumnHeader] -and $h.Role -ne 'Padding' -and "$($h.Content)" -eq 'Camera') {
        if ($script:sortProp -eq 'CameraText' -and $script:sortDir -eq 'Ascending') { $script:sortDir = 'Descending' }
        else { $script:sortProp = 'CameraText'; $script:sortDir = 'Ascending' }
        Apply-Sort
    }
})

# ---------- Tag autocomplete popup on the Tags box ----------
$tagBox = New-Object System.Windows.Controls.ListBox
$tagBox.MaxHeight = 170
$tagBox.MinWidth = 160
$tagBox.BorderBrush = [Windows.Media.Brushes]::Gray
$tagPopup = New-Object System.Windows.Controls.Primitives.Popup
$tagPopup.PlacementTarget = $txtTags
$tagPopup.Placement = 'Bottom'
$tagPopup.StaysOpen = $false
$tagPopup.Child = $tagBox

function Accept-Tag([string]$tag) {
    $t = $txtTags.Text
    $ci = [Math]::Min($txtTags.CaretIndex, $t.Length)
    $pre = $t.Substring(0, $ci)
    $m = [regex]::Match($pre, '[^,;]*$')
    $ws = ([regex]::Match($m.Value, '^\s*')).Value
    $post = $t.Substring($ci)
    $ins = $ws + $tag
    if ($post.Trim() -eq '') { $ins += ', '; $post = '' }
    $txtTags.Text = $t.Substring(0, $m.Index) + $ins + $post
    $txtTags.CaretIndex = $m.Index + $ins.Length
    $tagPopup.IsOpen = $false
    $txtTags.Focus() | Out-Null
}

function Update-TagSuggestions {
    try {
        if (-not $txtTags.IsKeyboardFocusWithin -or -not $txtTags.IsEnabled) { $tagPopup.IsOpen = $false; return }
        $t = $txtTags.Text
        $ci = [Math]::Min($txtTags.CaretIndex, $t.Length)
        $tok = ([regex]::Match($t.Substring(0, $ci), '[^,;]*$')).Value.Trim()
        if ($tok.Length -lt 1) { $tagPopup.IsOpen = $false; return }
        $have = @($t -split '\s*[,;]\s*' | ForEach-Object { $_.Trim().ToLowerInvariant() })
        $m = @($script:tagSet | Where-Object { $_.StartsWith($tok, [StringComparison]::OrdinalIgnoreCase) -and ($have -notcontains $_.ToLowerInvariant()) } | Sort-Object | Select-Object -First 8)
        if ($m.Count -eq 0) { $tagPopup.IsOpen = $false; return }
        $tagBox.ItemsSource = [string[]]$m
        $tagBox.SelectedIndex = -1
        $tagBox.MinWidth = [Math]::Max(160, $txtTags.ActualWidth)
        $tagPopup.IsOpen = $true
    } catch { }
}

$txtTags.Add_TextChanged({ Update-TagSuggestions })
$txtTags.Add_LostKeyboardFocus({ if (-not $tagBox.IsMouseOver) { $tagPopup.IsOpen = $false } })
$txtTags.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $tagPopup.IsOpen) { return }
    $k = "$($e.Key)"
    if ($k -eq 'Down') {
        $i = $tagBox.SelectedIndex + 1
        if ($i -ge $tagBox.Items.Count) { $i = 0 }
        $tagBox.SelectedIndex = $i
        $e.Handled = $true
    }
    elseif ($k -eq 'Up') {
        $i = $tagBox.SelectedIndex - 1
        if ($i -lt 0) { $i = $tagBox.Items.Count - 1 }
        $tagBox.SelectedIndex = $i
        $e.Handled = $true
    }
    elseif ($k -eq 'Tab' -or $k -eq 'Return') {
        $tag = $tagBox.SelectedItem
        if (-not $tag -and $k -eq 'Tab' -and $tagBox.Items.Count -gt 0) { $tag = $tagBox.Items[0] }
        if ($tag) { Accept-Tag ([string]$tag); $e.Handled = $true }
    }
    elseif ($k -eq 'Escape') { $tagPopup.IsOpen = $false; $e.Handled = $true }
})
$tagBox.Add_PreviewMouseLeftButtonUp({
    if ($tagBox.SelectedItem) { Accept-Tag ([string]$tagBox.SelectedItem) }
})

# ---------- Save history on exit ----------
$win.Add_Closing({
    try { Set-Setting 'TagHistory' ([string[]]@($script:tagSet | Sort-Object)) } catch { }
})

# ---------- Help text ----------
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`nKEYWORD HISTORY AND CAMERA`nAs you type in the Tags box, matching tags you have used before pop up. Use Up/Down then Enter or Tab (Tab takes the first one), or click one. History is learned from every folder you browse and every tag you save.`nThe Camera column (Details view) shows the camera model from the photo EXIF. It is read-only, sortable and searchable.`n`nPress F1 any time")
# ===== END SCRIPT13 =====
# ===== SCRIPT14-MARKER =====
# ---------- "12 of 48 selected" ----------
$list.Add_SelectionChanged({
    $sel = @($list.SelectedItems)
    if ($sel.Count -gt 0) {
        $b = ($sel | Where-Object { -not $_.IsDir } | Measure-Object Size -Sum).Sum
        $txtStatus.Text = "$($sel.Count) of $($list.Items.Count) selected ($(Format-Size ([long]$b)))   |   $($script:folderStatus)"
    }
})

# ---------- Status bar colours: red = error, amber = hint, green = done ----------
$script:stBrush = @{
    err  = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(198, 40, 40)))
    warn = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(178, 106, 0)))
    ok   = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(46, 125, 50)))
    norm = [System.Windows.Media.Brushes]::Black
}
$dpdStatus = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.TextBlock]::TextProperty, [System.Windows.Controls.TextBlock])
$dpdStatus.AddValueChanged($txtStatus, [EventHandler]{
    try {
        $t = [string]$txtStatus.Text
        if ($t -match '(^|\|\s+)(Error|Warning):|^Cannot |Could not|[Ff]ailed|must be a number') { $k = 'err' }
        elseif ($t -match '^(Select |Nothing copied|No changes|No metadata|That file has no)|nothing changed') { $k = 'warn' }
        elseif ($t -match '^(Saved |Set rating|Cleared rating|Added tag|Removed tag|Pasted |Copyright preset|Thumbnail cache cleared)') { $k = 'ok' }
        else { $k = 'norm' }
        $txtStatus.Foreground = $script:stBrush[$k]
    } catch { }
})

# ---------- Unsaved-edit cue: orange Save button + orange border on changed fields ----------
$bc = New-Object System.Windows.Media.BrushConverter
$script:cueBorder = $bc.ConvertFromString('#E65100')
$script:cueClean  = $bc.ConvertFromString('#999999')
$script:saveBlue  = $bc.ConvertFromString('#1565C0')
$script:saveOrange = $bc.ConvertFromString('#E65100')
function Update-DirtyCue {
    try {
        $dirty = $false
        foreach ($f in $fields) {
            $c = $f.Ctl
            $d = $false
            if ($c.IsEnabled) {
                $old = [string]$script:loaded[$f.Key]
                if ($c.Text -cne $old) { $d = $true }
            }
            if ($d) { $c.BorderBrush = $script:cueBorder; $dirty = $true } else { $c.BorderBrush = $script:cueClean }
        }
        if ($dirty -and $btnSave.IsEnabled) {
            $btnSave.Background = $script:saveOrange
            $btnSave.Content = 'SAVE CHANGES  (Ctrl+S)'
        } else {
            $btnSave.Background = $script:saveBlue
            $btnSave.Content = 'SAVE METADATA'
        }
    } catch { }
}
foreach ($f in $fields) { $f.Ctl.Add_TextChanged({ Update-DirtyCue }) }
$script:origShowMeta14 = ${function:Show-Metadata}
function Show-Metadata { & $script:origShowMeta14; Update-DirtyCue }

# ---------- Window title shows the current folder ----------
function Update-WinTitle {
    try {
        $p = [string]$txtPath.Text
        if ($p) {
            $leaf = [IO.Path]::GetFileName($p.TrimEnd('\'))
            if (-not $leaf) { $leaf = $p }
            $win.Title = "$leaf  -  MetadataEditor v3.0"
        } else { $win.Title = 'MetadataEditor v3.0' }
    } catch { }
}
$txtPath.Add_TextChanged({ Update-WinTitle })
Update-WinTitle

# ---------- Window icon (drawn in code) ----------
try {
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $bg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(21, 101, 192))
    $dc.DrawRoundedRectangle($bg, $null, [System.Windows.Rect]::new(2, 2, 60, 60), 12, 12)
    $ft = New-Object System.Windows.Media.FormattedText('M', [Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface('Segoe UI')), 40, [System.Windows.Media.Brushes]::White)
    $ft.SetFontWeight([System.Windows.FontWeights]::Bold)
    $dc.DrawText($ft, [System.Windows.Point]::new(32 - $ft.Width / 2, 32 - $ft.Height / 2))
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    $win.Icon = $rtb
} catch { }

# ---------- Remember column widths and pane widths ----------
$script:mainGrid14 = $tree.Parent.Parent
$gvDet = $win.FindResource('detailsView')
$st14 = $null
if ([IO.File]::Exists($settingsFile)) { try { $st14 = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch { } }
if ($st14) {
    try {
        $cd = $script:mainGrid14.ColumnDefinitions
        if ($cd.Count -ge 5) {
            if ($st14.PaneLeft)  { $cd[0].Width = [System.Windows.GridLength]::new([Math]::Max(140, [Math]::Min(600, [double]$st14.PaneLeft))) }
            if ($st14.PaneRight) { $cd[4].Width = [System.Windows.GridLength]::new([Math]::Max(240, [Math]::Min(600, [double]$st14.PaneRight))) }
        }
    } catch { }
    try {
        if ($st14.ColWidths) {
            foreach ($c in $gvDet.Columns) {
                $hdr = "$($c.Header)"
                if ($hdr -eq 'Folder') { continue }
                $p = $st14.ColWidths.PSObject.Properties[$hdr]
                if ($p) { $v = [double]$p.Value; if ($v -ge 40 -and $v -le 900) { $c.Width = $v } }
            }
        }
    } catch { }
}
$win.Add_Closing({
    try {
        $h = [ordered]@{}
        foreach ($c in $gvDet.Columns) {
            $hdr = "$($c.Header)"
            if ($hdr -eq 'Folder') { continue }
            $w = $c.ActualWidth
            if ($w -lt 20) { $w = $c.Width }
            if ($w -ge 20) { $h[$hdr] = [int]$w }
        }
        if ($h.Count -gt 0) { Set-Setting 'ColWidths' ([pscustomobject]$h) }
        $cd = $script:mainGrid14.ColumnDefinitions
        if ($cd[0].ActualWidth -ge 100) { Set-Setting 'PaneLeft' ([int]$cd[0].ActualWidth) }
        if ($cd[4].ActualWidth -ge 100) { Set-Setting 'PaneRight' ([int]$cd[4].ActualWidth) }
    } catch { }
})

# ---------- Thumbnail cache: size cap on start + Clear cache button ----------
function Get-ThumbCacheBytes {
    $d = Join-Path $root 'cache\thumbs'
    $s = (Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($s) { return [long]$s } else { return 0L }
}
function Trim-ThumbCache([long]$maxBytes) {
    $d = Join-Path $root 'cache\thumbs'
    $total = Get-ThumbCacheBytes
    if ($total -le $maxBytes) { return }
    foreach ($x in @(Get-ChildItem $d -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
        if ($total -le ($maxBytes * 0.7)) { break }
        $sz = (Get-ChildItem $x.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Remove-Item $x.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $total -= [long]$sz
    }
}
try { Trim-ThumbCache 200MB } catch { }

function Clear-ThumbCache {
    try {
        Stop-Thumbs
        $before = Get-ThumbCacheBytes
        $d = Join-Path $root 'cache\thumbs'
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $script:thumbDir = $null
        $mb = [Math]::Round($before / 1MB, 1)
        Refresh-Folder
        $txtStatus.Text = "Thumbnail cache cleared ($mb MB freed) - thumbnails rebuild as you browse"
    } catch { $txtStatus.Text = 'Error: could not clear cache - ' + $_.Exception.Message }
}
$btnClearCache = New-Object System.Windows.Controls.Button
$btnClearCache.Content = 'Clear cache'
$btnClearCache.Style = $win.FindResource('TB')
$btnClearCache.ToolTip = 'Delete cached thumbnails (they rebuild automatically)'
$btnClearCache.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
$dpTop14 = $rbThumbs.Parent
$dpTop14.Children.Insert($dpTop14.Children.IndexOf($sizeSlider) + 1, $btnClearCache)
if ($rbThumbs.IsChecked) { $btnClearCache.Visibility = 'Visible' } else { $btnClearCache.Visibility = 'Collapsed' }
$rbThumbs.Add_Checked({ $btnClearCache.Visibility = 'Visible' })
$rbThumbs.Add_Unchecked({ $btnClearCache.Visibility = 'Collapsed' })
$btnClearCache.Add_Click({ Clear-ThumbCache })

# ---------- Help text ----------
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`nPOLISH`nThe Save button turns orange (and changed fields get an orange border) while you have unsaved edits. The status bar shows errors in red, hints in amber and completed actions in green. Column widths and pane sizes are remembered. In Thumbnails view, Clear cache deletes cached thumbnails (they rebuild by themselves; the cache is also trimmed automatically above 200 MB).`n`nPress F1 any time")
# ===== END SCRIPT14 =====
# ===== SCRIPT15-MARKER =====
$script:appVersion = '3.1'
$script:donateUrl  = 'https://paypal.me/AndrewSnell791'

function Get-AncestorOf($d, [type]$t) {
    while ($null -ne $d -and -not $t.IsInstanceOfType($d)) {
        if ($d -is [System.Windows.Media.Visual] -or $d -is [System.Windows.Media.Media3D.Visual3D]) { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
        else { $d = [System.Windows.LogicalTreeHelper]::GetParent($d) }
    }
    return $d
}

# ---------- Subject history (for autocomplete) ----------
$script:subjSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$st15 = $null
if ([IO.File]::Exists($settingsFile)) { try { $st15 = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch { } }
if ($st15 -and $st15.SubjectHistory) {
    foreach ($x in @($st15.SubjectHistory)) { $s = ([string]$x).Trim(); if ($s -and $script:subjSet.Count -lt 2000) { [void]$script:subjSet.Add($s) } }
}

# ---------- Copyright column (+ learn subjects while columns load) ----------
$script:origSetItemCols15 = ${function:Set-ItemCols}
function Set-ItemCols($it, $o) {
    & $script:origSetItemCols15 $it $o
    $it.CopyrightText = Get-FieldText $o 'Rights'
    $s = ([string]$it.SubjectText).Trim()
    if ($s -and $s.Length -le 120 -and $script:subjSet.Count -lt 2000) { [void]$script:subjSet.Add($s) }
}
$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource
    if ($h -is [System.Windows.Controls.GridViewColumnHeader] -and $h.Role -ne 'Padding' -and "$($h.Content)" -eq 'Copyright') {
        if ($script:sortProp -eq 'CopyrightText' -and $script:sortDir -eq 'Ascending') { $script:sortDir = 'Descending' }
        else { $script:sortProp = 'CopyrightText'; $script:sortDir = 'Ascending' }
        Apply-Sort
    }
})

# ---------- Subject box: same suggestions as Tags ----------
$subjBox = New-Object System.Windows.Controls.ListBox
$subjBox.MaxHeight = 170
$subjBox.MinWidth = 160
$subjBox.BorderBrush = [Windows.Media.Brushes]::Gray
$subjPopup = New-Object System.Windows.Controls.Primitives.Popup
$subjPopup.PlacementTarget = $txtSubject
$subjPopup.Placement = 'Bottom'
$subjPopup.StaysOpen = $false
$subjPopup.Child = $subjBox

function Accept-Subject([string]$s) {
    $subjPopup.IsOpen = $false
    $txtSubject.Text = $s
    $txtSubject.CaretIndex = $s.Length
    $txtSubject.Focus() | Out-Null
}
function Update-SubjectSuggestions {
    try {
        if (-not $txtSubject.IsKeyboardFocusWithin -or -not $txtSubject.IsEnabled) { $subjPopup.IsOpen = $false; return }
        $tok = $txtSubject.Text.Trim()
        if ($tok.Length -lt 1) { $subjPopup.IsOpen = $false; return }
        $m = @($script:subjSet | Where-Object { $_.IndexOf($tok, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_ -ine $tok } |
            Sort-Object @{ Expression = { -not $_.StartsWith($tok, [StringComparison]::OrdinalIgnoreCase) } }, @{ Expression = { $_ } } |
            Select-Object -First 8)
        if ($m.Count -eq 0) { $subjPopup.IsOpen = $false; return }
        $subjBox.ItemsSource = [string[]]$m
        $subjBox.SelectedIndex = -1
        $subjBox.MinWidth = [Math]::Max(160, $txtSubject.ActualWidth)
        $subjPopup.IsOpen = $true
    } catch { }
}
$txtSubject.Add_TextChanged({ Update-SubjectSuggestions })
$txtSubject.Add_LostKeyboardFocus({ if (-not $subjBox.IsMouseOver) { $subjPopup.IsOpen = $false } })
$txtSubject.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $subjPopup.IsOpen) { return }
    $k = "$($e.Key)"
    if ($k -eq 'Down') {
        $i = $subjBox.SelectedIndex + 1
        if ($i -ge $subjBox.Items.Count) { $i = 0 }
        $subjBox.SelectedIndex = $i
        $e.Handled = $true
    }
    elseif ($k -eq 'Up') {
        $i = $subjBox.SelectedIndex - 1
        if ($i -lt 0) { $i = $subjBox.Items.Count - 1 }
        $subjBox.SelectedIndex = $i
        $e.Handled = $true
    }
    elseif ($k -eq 'Tab' -or $k -eq 'Return') {
        $v = $subjBox.SelectedItem
        if (-not $v -and $k -eq 'Tab' -and $subjBox.Items.Count -gt 0) { $v = $subjBox.Items[0] }
        if ($v) { Accept-Subject ([string]$v); $e.Handled = $true }
    }
    elseif ($k -eq 'Escape') { $subjPopup.IsOpen = $false; $e.Handled = $true }
})
$subjBox.Add_PreviewMouseLeftButtonUp({
    if ($subjBox.SelectedItem) { Accept-Subject ([string]$subjBox.SelectedItem) }
})
$win.Add_Closing({
    try { Set-Setting 'SubjectHistory' ([string[]]@($script:subjSet | Sort-Object)) } catch { }
})

# ---------- Properties (right-click menu + Alt+Enter) ----------
function Do-Properties {
    try {
        $sel = @($list.SelectedItems)
        if ($sel.Count -gt 0) { $p = [string]$sel[0].FullPath } else { $p = [string]$txtPath.Text }
        if (-not $p) { return }
        $p = $p.TrimEnd('\')
        $parent = [IO.Path]::GetDirectoryName($p)
        $leaf = [IO.Path]::GetFileName($p)
        if (-not $parent -or -not $leaf) { return }
        $sh = New-Object -ComObject Shell.Application
        $ns = $sh.NameSpace($parent)
        if ($ns) {
            $item = $ns.ParseName($leaf)
            if ($item) { $item.InvokeVerb('Properties') }
        }
        if ($sel.Count -gt 1) { $txtStatus.Text = 'Properties shown for the first selected item.' }
    } catch { $txtStatus.Text = 'Error: could not open Properties - ' + $_.Exception.Message }
}
[void]$cm.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$cm.Items.Add((New-MenuItem 'Properties     Alt+Enter' { Do-Properties }))
$win.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'System' -and $e.SystemKey -eq 'Return' -and $list.IsKeyboardFocusWithin) { Do-Properties; $e.Handled = $true }
})

# ---------- Drag and drop: middle pane -> folder in the left pane ----------
$script:dragStart = $null
$script:clickPending = $null
$script:internalDrop = $false
$script:dropHot = $null
$script:pendingDrop = $null

$list.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $script:dragStart = $null
    $script:clickPending = $null
    $item = Get-AncestorOf $e.OriginalSource ([System.Windows.Controls.ListViewItem])
    if ($item) {
        $script:dragStart = $e.GetPosition($list)
        # keep a multi-selection intact when you press on one of the selected items (so it can be dragged)
        if ($e.ClickCount -eq 1 -and $item.IsSelected -and $list.SelectedItems.Count -gt 1 -and ([int][System.Windows.Input.Keyboard]::Modifiers -eq 0)) {
            $script:clickPending = $item
            $e.Handled = $true
        }
    }
})
$list.Add_PreviewMouseLeftButtonUp({
    param($s, $e)
    $it = $script:clickPending
    $script:dragStart = $null
    $script:clickPending = $null
    if ($it) { $list.SelectedItems.Clear(); $it.IsSelected = $true; $it.Focus() | Out-Null }
})
$list.Add_PreviewMouseMove({
    param($s, $e)
    if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed -or $null -eq $script:dragStart) { return }
    $p = $e.GetPosition($list)
    if ([Math]::Abs($p.X - $script:dragStart.X) -lt [System.Windows.SystemParameters]::MinimumHorizontalDragDistance -and [Math]::Abs($p.Y - $script:dragStart.Y) -lt [System.Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
    $script:dragStart = $null
    $script:clickPending = $null
    $paths = @(Get-SelPaths)
    if ($paths.Count -eq 0) { return }
    $data = New-Object System.Windows.DataObject
    $data.SetData([System.Windows.DataFormats]::FileDrop, [string[]]$paths)
    $script:internalDrop = $false
    $res = [System.Windows.DragDrop]::DoDragDrop($list, $data, [System.Windows.DragDropEffects]'Copy, Move')
    if (-not $script:internalDrop -and "$res" -match 'Move') { Refresh-Folder }
})

function Clear-DropHot {
    if ($script:dropHot) {
        try { $script:dropHot.ClearValue([System.Windows.Controls.Control]::BackgroundProperty) } catch { }
        $script:dropHot = $null
    }
}
function Get-DropEffect($e, $dest, $paths) {
    $ks = [int]$e.KeyStates
    if (($ks -band 8) -ne 0) { return 'Copy' }
    if (($ks -band 4) -ne 0) { return 'Move' }
    $same = $true
    try { $same = ([IO.Path]::GetPathRoot($dest) -ieq [IO.Path]::GetPathRoot([string]$paths[0])) } catch { }
    if ($same) { return 'Move' } else { return 'Copy' }
}

$tree.AllowDrop = $true
$tree.Add_DragOver({
    param($s, $e)
    $e.Handled = $true
    $e.Effects = [System.Windows.DragDropEffects]::None
    try {
        if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
        $tvi = Get-AncestorOf $e.OriginalSource ([System.Windows.Controls.TreeViewItem])
        if (-not $tvi -or -not $tvi.Tag -or -not [IO.Directory]::Exists([string]$tvi.Tag)) { Clear-DropHot; return }
        $paths = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $e.Effects = [System.Windows.DragDropEffects](Get-DropEffect $e ([string]$tvi.Tag) $paths)
        if ($script:dropHot -ne $tvi) {
            Clear-DropHot
            $tvi.Background = [System.Windows.Media.Brushes]::LightSkyBlue
            $script:dropHot = $tvi
        }
    } catch { }
})
$tree.Add_DragLeave({ Clear-DropHot })
$tree.Add_Drop({
    param($s, $e)
    $e.Handled = $true
    try {
        Clear-DropHot
        if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
        $tvi = Get-AncestorOf $e.OriginalSource ([System.Windows.Controls.TreeViewItem])
        if (-not $tvi -or -not $tvi.Tag) { return }
        $dest = [string]$tvi.Tag
        if (-not [IO.Directory]::Exists($dest)) { return }
        $paths = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
        if ($paths.Count -eq 0) { return }
        $eff = Get-DropEffect $e $dest $paths
        $script:internalDrop = $true
        $e.Effects = [System.Windows.DragDropEffects]$eff
        $script:pendingDrop = @{ Paths = $paths; Dest = $dest; Move = ($eff -eq 'Move') }
        [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
            $d = $script:pendingDrop
            $script:pendingDrop = $null
            if ($d) { Transfer-Items $d.Paths $d.Dest $d.Move }
        })
    } catch { $txtStatus.Text = 'Error: drop failed - ' + $_.Exception.Message }
})

# ---------- Help text + About section ----------
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`nDRAG AND DROP`nDrag files or folders from the middle pane onto a folder in the left pane to move them. Hold Ctrl to copy instead (Shift forces a move). Dragging to a folder on another drive copies by default.`n`nPROPERTIES, COPYRIGHT AND SUBJECT`nRight-click > Properties (or Alt+Enter) opens the Windows Properties window. The Copyright column shows the XMP copyright text (click the header to sort). The Subject box suggests earlier subjects as you type, the same way Tags does.`n`nPress F1 any time")

function Show-Help {
    $w = New-Object System.Windows.Window
    $w.Title = 'MetadataEditor - Help'
    $w.Width = 640; $w.Height = 700
    $w.Owner = $win; $w.WindowStartupLocation = 'CenterOwner'
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(18)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $script:helpText
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize = 14
    [void]$sp.Children.Add($tb)

    $ab = New-Object System.Windows.Controls.TextBlock
    $ab.TextWrapping = 'Wrap'
    $ab.FontSize = 14
    $ab.Margin = [System.Windows.Thickness]::new(0, 20, 0, 0)
    $r = New-Object System.Windows.Documents.Run
    $r.Text = "ABOUT`nMetadataEditor v$($script:appVersion) - free, with an optional donation.`nIt writes XMP metadata into your original files (the picture or document content is not changed), so back up anything important first. To keep a copy of each file as it was before a change, set KeepBackups to true in config.json (copies end in _original).`nPowered by ExifTool by Phil Harvey (exiftool.org), free software.`nIf this saved you time and you would like to say thanks, an optional $([char]0x00A3)1 is welcome: "
    [void]$ab.Inlines.Add($r)
    $link = New-Object System.Windows.Documents.Hyperlink
    $link.NavigateUri = [Uri]$script:donateUrl
    [void]$link.Inlines.Add('paypal.me/AndrewSnell791')
    $link.Add_RequestNavigate({ param($s, $e) try { Start-Process $s.NavigateUri.AbsoluteUri } catch { }; $e.Handled = $true })
    [void]$ab.Inlines.Add($link)
    [void]$sp.Children.Add($ab)

    $sv.Content = $sp
    $w.Content = $sv
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    [void]$w.ShowDialog()
}
# ===== END SCRIPT15 =====
# ===== SCRIPT16-MARKER =====
$script:docExts = '.pdf .doc .docx .dot .dotx .docm .rtf .odt .xls .xlsx .xlsm .xlsb .xlt .xltx .ods .csv .tsv .ppt .pptx .pptm .pps .ppsx .potx .odp .txt .log .md .ini .xml .json .zip .7z .rar' -split ' '
$script:docIconCache = @{}

function Get-DocStyle([string]$ext) {
    switch -Regex ($ext) {
        '^\.pdf$'                            { return @('PDF', '#D32F2F') }
        '^\.(docx?|docm|dotx?|rtf|odt)$'     { return @('DOC', '#1F5FBF') }
        '^\.(xlsx?|xlsm|xlsb|xltx?|ods)$'    { return @('XLS', '#1E7B45') }
        '^\.(csv|tsv)$'                      { return @('CSV', '#2E9E5B') }
        '^\.(pptx?|pptm|pps|ppsx|potx|odp)$' { return @('PPT', '#D2571E') }
        '^\.(zip|7z|rar)$'                   { return @('ZIP', '#B8860B') }
        '^\.(txt|log|md|ini)$'               { return @('TXT', '#607D8B') }
        '^\.(xml|json)$'                     { return @(($ext.TrimStart('.').ToUpper()), '#6A5ACD') }
        default                              { return @(($ext.TrimStart('.').ToUpper()), '#546E7A') }
    }
}

function New-DocIconImage([string]$label, [string]$hex) {
    $S = 384
    $bc = New-Object System.Windows.Media.BrushConverter
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRectangle($bc.ConvertFromString('#EEF2F7'), $null, [System.Windows.Rect]::new(0, 0, $S, $S))
    $pw = 200; $ph = 260; $fold = 56
    $x = ($S - $pw) / 2; $y = ($S - $ph) / 2 - 4
    $pen = New-Object System.Windows.Media.Pen -ArgumentList $bc.ConvertFromString('#B0BAC5'), 3.0

    $g = New-Object System.Windows.Media.StreamGeometry
    $c = $g.Open()
    $c.BeginFigure([System.Windows.Point]::new($x, $y), $true, $true)
    $c.LineTo([System.Windows.Point]::new($x + $pw - $fold, $y), $true, $false)
    $c.LineTo([System.Windows.Point]::new($x + $pw, $y + $fold), $true, $false)
    $c.LineTo([System.Windows.Point]::new($x + $pw, $y + $ph), $true, $false)
    $c.LineTo([System.Windows.Point]::new($x, $y + $ph), $true, $false)
    $c.Close()
    $g.Freeze()
    $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $pen, $g)

    $f = New-Object System.Windows.Media.StreamGeometry
    $c = $f.Open()
    $c.BeginFigure([System.Windows.Point]::new($x + $pw - $fold, $y), $true, $true)
    $c.LineTo([System.Windows.Point]::new($x + $pw - $fold, $y + $fold), $true, $false)
    $c.LineTo([System.Windows.Point]::new($x + $pw, $y + $fold), $true, $false)
    $c.Close()
    $f.Freeze()
    $dc.DrawGeometry($bc.ConvertFromString('#DDE3EA'), $pen, $f)

    $grey = $bc.ConvertFromString('#D5DBE2')
    $dc.DrawRectangle($grey, $null, [System.Windows.Rect]::new($x + 24, $y + 78, 120, 9))
    $dc.DrawRectangle($grey, $null, [System.Windows.Rect]::new($x + 24, $y + 98, 150, 9))
    $dc.DrawRectangle($grey, $null, [System.Windows.Rect]::new($x + 24, $y + 118, 100, 9))

    $by = $y + 160; $bh = 70
    $dc.DrawRectangle($bc.ConvertFromString($hex), $null, [System.Windows.Rect]::new($x, $by, $pw, $bh))
    try {
        $fs = 46; if ($label.Length -ge 4) { $fs = 36 }
        $ft = New-Object System.Windows.Media.FormattedText($label, [Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface('Segoe UI')), $fs, [System.Windows.Media.Brushes]::White)
        $ft.SetFontWeight([System.Windows.FontWeights]::Bold)
        $dc.DrawText($ft, [System.Windows.Point]::new($x + ($pw - $ft.Width) / 2, $by + ($bh - $ft.Height) / 2))
    } catch { }
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($S, $S, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $rtb.Freeze()
    return $rtb
}

function Get-DocIcon([string]$name) {
    $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
    if (-not $ext -or $script:docExts -notcontains $ext) { return $null }
    $st = Get-DocStyle $ext
    $key = $st[0] + $st[1]
    if (-not $script:docIconCache.ContainsKey($key)) { $script:docIconCache[$key] = New-DocIconImage $st[0] $st[1] }
    return $script:docIconCache[$key]
}

$script:origStartShell16 = ${function:Start-ShellThumbs}
function Start-ShellThumbs($items, $includeJpg = $false, $force = $false, $px = 0) {
    try {
        foreach ($it in $items) {
            if ($it.IsDir -or $it.IsJpg) { continue }
            $ic = Get-DocIcon $it.Name
            if ($ic) { $it.Thumb = $ic }
        }
    } catch { }
    & $script:origStartShell16 $items $includeJpg $force $px
}
# ===== END SCRIPT16 =====
# ===== SCRIPT-EPUB-MARKER =====
$script:docExts = @($script:docExts) + '.epub'
$script:origDocStyleEpub = ${function:Get-DocStyle}
function Get-DocStyle([string]$ext) {
    if ($ext -eq '.epub') { return @('EPUB', '#0097A7') }
    return (& $script:origDocStyleEpub $ext)
}
# ===== END SCRIPT-EPUB =====
# ===== SCRIPT17-MARKER =====
# ---------- Search upgrade: field terms, names only, recent searches, cancel + progress ----------
$script:fieldTerms = @()
$script:nameOnly = $false
$script:metaObjs = @{}
$script:metaFields = @{}
$script:deepHasMeta = $false
$script:deepIdx = $null
$script:suppressFieldCache = $false
$script:fieldKeys = @('Title', 'Headline', 'Creator', 'Subject', 'Description', 'Rights', 'Model', 'Rating')
$script:fieldAlias = @{
    title = 'Title'; subject = 'Headline'; headline = 'Headline'
    author = 'Creator'; authors = 'Creator'; creator = 'Creator'
    tag = 'Subject'; tags = 'Subject'; keyword = 'Subject'; keywords = 'Subject'
    comment = 'Description'; comments = 'Description'; description = 'Description'
    copyright = 'Rights'; rights = 'Rights'
    camera = 'Model'; model = 'Model'
    rating = 'Rating'; stars = 'Rating'
    name = '_name'; file = '_name'; filename = '_name'
    ext = '_ext'; type = '_ext'
}

try {
if (-not ('DeepSearchIndex' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;

public class DeepSearchIndex {
    private Dictionary<string, Dictionary<string, string>> map = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);

    public void Add(string path, string[] keys, string[] vals) {
        Dictionary<string, string> d = new Dictionary<string, string>();
        for (int i = 0; i < keys.Length; i++) { d[keys[i]] = vals[i]; }
        map[path] = d;
    }

    public string[] Run(string[] files, Dictionary<string, string> meta, string[] plain, bool nameOnly,
                        string[] fKeys, string[] fOps, string[] fVals, int[] fNums, int max) {
        List<string> res = new List<string>();
        foreach (string f in files) {
            string name = Path.GetFileName(f).ToLowerInvariant();
            bool ok = true;
            if (plain.Length > 0) {
                string m = null;
                if (!nameOnly && meta != null) { meta.TryGetValue(f, out m); }
                foreach (string t in plain) {
                    if (!(name.Contains(t) || (m != null && m.Contains(t)))) { ok = false; break; }
                }
            }
            if (ok && fKeys.Length > 0) {
                Dictionary<string, string> fm = null;
                map.TryGetValue(f, out fm);
                for (int i = 0; i < fKeys.Length && ok; i++) {
                    string k = fKeys[i];
                    if (k == "_name") { ok = name.Contains(fVals[i]); }
                    else if (k == "_ext") { ok = (Path.GetExtension(name).TrimStart('.') == fVals[i]); }
                    else if (k == "Rating") {
                        int r = 0;
                        string rs = null;
                        if (fm != null && fm.TryGetValue("Rating", out rs)) { int.TryParse(rs, out r); }
                        string op = fOps[i];
                        int n = fNums[i];
                        if (op == ">=") { ok = (r >= n); }
                        else if (op == "<=") { ok = (r <= n); }
                        else if (op == ">") { ok = (r > n); }
                        else if (op == "<") { ok = (r < n); }
                        else { ok = (r == n); }
                    } else {
                        string tx = null;
                        ok = (fm != null && fm.TryGetValue(k, out tx) && tx != null && tx.Length > 0 && tx.Contains(fVals[i]));
                    }
                }
            }
            if (ok) { res.Add(f); if (res.Count >= max) { break; } }
        }
        return res.ToArray();
    }
}
"@
}
} catch { Write-Log ('DeepSearchIndex: ' + $_.Exception.ToString()) }

# ---------- Query parsing ----------
function Parse-SearchQuery([string]$q) {
    $plain = New-Object 'System.Collections.Generic.List[string]'
    $fl = New-Object 'System.Collections.Generic.List[object]'
    $q = ([string]$q).ToLowerInvariant()
    foreach ($m in [regex]::Matches($q, '(?:([a-z]+):)?(?:"([^"]*)"|(\S+))')) {
        $pre = $m.Groups[1].Value
        if ($m.Groups[2].Success) { $val = $m.Groups[2].Value } else { $val = $m.Groups[3].Value.Trim('"') }
        $val = $val.Trim()
        if ($pre -and $script:fieldAlias.ContainsKey($pre)) {
            if (-not $val) { continue }
            $key = $script:fieldAlias[$pre]
            if ($key -eq 'Rating') {
                $op = '='
                $num = $null
                if ($val -match '^(>=|<=|>|<|=)?\s*(\d+)$') {
                    if ($matches[1]) { $op = $matches[1] }
                    $num = [int]$matches[2]
                } elseif ($val -eq 'none' -or $val -eq 'unrated') { $num = 0 }
                if ($null -eq $num) { continue }
                $fl.Add(@{ Key = 'Rating'; Op = $op; Num = $num; Value = $val })
            } else {
                if ($key -eq '_ext') { $val = $val.TrimStart('.') }
                if (-not $val) { continue }
                $fl.Add(@{ Key = $key; Op = ''; Num = 0; Value = $val })
            }
        } else {
            if ($pre) { $val = $m.Value.Trim().Trim('"') }
            if (-not $val) { continue }
            if ($val -match '^([a-z]+):$' -and $script:fieldAlias.ContainsKey($matches[1])) { continue }
            $plain.Add($val)
        }
    }
    return @{ Plain = $plain.ToArray(); Fields = $fl.ToArray() }
}

function Get-FieldMap($o) {
    $m = @{}
    foreach ($k in $script:fieldKeys) { $m[$k] = (Get-FieldText $o $k).ToLowerInvariant() }
    return $m
}

function Get-CachedFields([string]$path) {
    $m = $script:metaFields[$path]
    if ($null -ne $m) { return $m }
    $o = $script:metaObjs[$path]
    if ($null -eq $o) { return $null }
    $m = Get-FieldMap $o
    $script:metaFields[$path] = $m
    return $m
}

function Test-FieldTerm($ft, [string]$fileName, $ff) {
    $k = $ft.Key
    if ($k -eq '_name') { return $fileName.ToLowerInvariant().Contains($ft.Value) }
    if ($k -eq '_ext') { return ([IO.Path]::GetExtension($fileName).TrimStart('.').ToLowerInvariant() -eq $ft.Value) }
    if ($k -eq 'Rating') {
        $r = 0
        if ($ff) { [void][int]::TryParse([string]$ff['Rating'], [ref]$r) }
        $n = [int]$ft.Num
        switch ($ft.Op) {
            '>=' { return ($r -ge $n) }
            '<=' { return ($r -le $n) }
            '>'  { return ($r -gt $n) }
            '<'  { return ($r -lt $n) }
            default { return ($r -eq $n) }
        }
    }
    if (-not $ff) { return $false }
    $t = [string]$ff[$k]
    return ($t.Length -gt 0 -and $t.Contains($ft.Value))
}

function Test-SearchNeedsMeta {
    foreach ($ft in @($script:fieldTerms)) { if ($ft.Key -ne '_name' -and $ft.Key -ne '_ext') { return $true } }
    if (-not $script:nameOnly -and @($script:searchTerms).Count -gt 0) { return $true }
    return $false
}

# keep the per-file field data fresh whenever the Details columns are (re)loaded or saved
$script:prevSetItemCols17 = ${function:Set-ItemCols}
function Set-ItemCols($it, $o) {
    & $script:prevSetItemCols17 $it $o
    try {
        if (-not $script:suppressFieldCache) {
            $script:metaObjs[$it.FullPath] = $o
            $script:metaFields.Remove($it.FullPath)
        }
    } catch { }
}

# ---------- Current-folder index and filter ----------
function Build-MetaIndex {
    $script:metaText = @{}
    $script:metaObjs = @{}
    $script:metaFields = @{}
    $byKey = @{}
    $oitems = @()
    foreach ($it in @($list.ItemsSource)) {
        if ($it.IsDir) { continue }
        $mode = Get-XmpMode $it
        if (-not $mode) { continue }
        if ($mode -eq 'office') { if (-not $it.IsCloud) { $oitems += $it }; continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $byKey[$tp.ToLowerInvariant()] = @{ Item = $it; Path = $tp } }
    }
    $all = @($byKey.Values | ForEach-Object { $_.Path })
    for ($i = 0; $i -lt $all.Count; $i += 150) {
        $chunk = @($all[$i..([Math]::Min($i + 149, $all.Count - 1))])
        $cmd = @('-j', '-charset', 'filename=utf8')
        foreach ($f in $fields) { $cmd += ('-' + $f.Tag) }
        $cmd += '-Model'
        $cmd += $chunk
        $json = $script:et.Run([string[]]$cmd)
        if (-not $json.Trim()) { continue }
        $objs = @()
        $objs += (ConvertFrom-Json $json)
        foreach ($o in $objs) {
            $key = (("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()
            $entry = $byKey[$key]
            if (-not $entry) { continue }
            $script:metaText[$entry.Item.FullPath] = (Get-AllText $o)
            $script:metaObjs[$entry.Item.FullPath] = $o
        }
    }
    foreach ($it in $oitems) {
        $o = Read-OfficeProps $it.FullPath
        $script:metaText[$it.FullPath] = (Get-AllText $o)
        $script:metaObjs[$it.FullPath] = $o
    }
    $script:metaReady = $true
}

$script:searchPredicate = [System.Predicate[object]]{
    param($o)
    $name = $o.Name.ToLowerInvariant()
    if (@($script:searchTerms).Count -gt 0) {
        $meta = $null
        if (-not $script:nameOnly) { $meta = $script:metaText[$o.FullPath] }
        foreach ($term in $script:searchTerms) {
            if (-not ($name.Contains($term) -or ($meta -and $meta.Contains($term)))) { return $false }
        }
    }
    if (@($script:fieldTerms).Count -gt 0) {
        $ff = $null
        foreach ($ft in $script:fieldTerms) {
            if ($ft.Key -ne '_name' -and $ft.Key -ne '_ext' -and $null -eq $ff) { $ff = Get-CachedFields $o.FullPath }
            if (-not (Test-FieldTerm $ft $o.Name $ff)) { return $false }
        }
    }
    return $true
}

# ---------- Subfolder search: progress bar + Cancel ----------
$s17Border = $txtStatus.Parent
if ($s17Border -is [System.Windows.Controls.Border]) {
    $s17Border.Child = $null
    $s17Dock = New-Object System.Windows.Controls.DockPanel
    $btnDeepCancel = New-Object System.Windows.Controls.Button
    $btnDeepCancel.Content = 'Cancel search'
    $btnDeepCancel.FontSize = 12
    $btnDeepCancel.Height = 20
    $btnDeepCancel.Padding = [System.Windows.Thickness]::new(10, 0, 10, 0)
    $btnDeepCancel.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $btnDeepCancel.Visibility = 'Collapsed'
    [System.Windows.Controls.DockPanel]::SetDock($btnDeepCancel, [System.Windows.Controls.Dock]::Right)
    $script:deepProg = New-Object System.Windows.Controls.ProgressBar
    $script:deepProg.IsIndeterminate = $true
    $script:deepProg.Width = 150
    $script:deepProg.Height = 12
    $script:deepProg.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $script:deepProg.Visibility = 'Collapsed'
    [System.Windows.Controls.DockPanel]::SetDock($script:deepProg, [System.Windows.Controls.Dock]::Right)
    [void]$s17Dock.Children.Add($btnDeepCancel)
    [void]$s17Dock.Children.Add($script:deepProg)
    [void]$s17Dock.Children.Add($txtStatus)
    $s17Border.Child = $s17Dock
}
function Show-DeepProgress { try { $script:deepProg.Visibility = 'Visible'; $btnDeepCancel.Visibility = 'Visible' } catch { } }
function Hide-DeepProgress { try { $script:deepProg.Visibility = 'Collapsed'; $btnDeepCancel.Visibility = 'Collapsed' } catch { } }

function Stop-Deep {
    $deepTimer.Stop()
    Hide-DeepProgress
    if ($script:deepReady) { return }
    if ($script:deepWalker) { $script:deepWalker.Stop() }
    if ($script:deepExif) { $script:deepExif.Kill() }
    $script:deepWalker = $null
    $script:deepExif = $null
}

function Import-DeepMeta($w, $json) {
    if (-not $json -or -not $json.Trim()) { return }
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $objs = $js.DeserializeObject($json)
    $keys = [string[]]$script:fieldKeys
    foreach ($o in $objs) {
        $sf = ([string]$o['SourceFile']) -replace '/', '\'
        $m = Get-FieldMap $o
        $vals = New-Object 'string[]' $keys.Length
        for ($i = 0; $i -lt $keys.Length; $i++) { $vals[$i] = [string]$m[$keys[$i]] }
        if ($script:deepIdx) { $script:deepIdx.Add($sf, $keys, $vals) }
        $txt = ($vals -join ' ').Trim()
        if ($txt) { $w.Meta[$sf] = $txt }
        $script:deepFields[$sf.ToLowerInvariant()] = $o
    }
}

function Show-DeepResults {
    $w = $script:deepWalker
    if (-not $w -or (@($script:searchTerms).Count -eq 0 -and @($script:fieldTerms).Count -eq 0)) { return }
    $terms = [string[]]@($script:searchTerms)
    if ($script:deepIdx) {
        $fts = @($script:fieldTerms)
        $fKeys = [string[]]@($fts | ForEach-Object { $_.Key })
        $fOps = [string[]]@($fts | ForEach-Object { $_.Op })
        $fVals = [string[]]@($fts | ForEach-Object { $_.Value })
        $fNums = [int[]]@($fts | ForEach-Object { [int]$_.Num })
        $files = [string[]]([DeepWalker2].GetField('files', [System.Reflection.BindingFlags]'Instance,NonPublic').GetValue($w))
        $paths = @($script:deepIdx.Run($files, $w.Meta, $terms, [bool]$script:nameOnly, $fKeys, $fOps, $fVals, $fNums, 2000))
    } else {
        $paths = @($w.Filter($terms, 2000))
    }
    $items = New-Object 'System.Collections.Generic.List[FileItem]'
    $script:suppressFieldCache = $true
    try {
        foreach ($pth in $paths) {
            $i = New-ItemFromPath $pth $script:deepRoot
            if ($i) {
                $o = $script:deepFields[$pth.ToLowerInvariant()]
                if ($o) { Set-ItemCols $i $o }
                $items.Add($i)
            }
        }
    } finally { $script:suppressFieldCache = $false }
    $script:deepActive = $true
    $list.ItemsSource = $items
    Set-FolderCol $true
    Apply-Sort
    Start-ShellThumbs $items $true
    $more = ''
    if ($paths.Count -ge 2000) { $more = ' (first 2000 shown)' }
    $txtStatus.Text = "$($items.Count) match(es) in subfolders$more for '$($txtSearch.Text.Trim())'   |   $($w.FileCount) files searched"
}

function Start-Deep {
    $sroot = $txtPath.Text
    if (-not $sroot -or -not [IO.Directory]::Exists($sroot)) { return }
    if ([IO.Path]::GetPathRoot($sroot).TrimEnd('\') -ieq $sroot.TrimEnd('\')) {
        $txtStatus.Text = 'Subfolder search needs a folder, not a whole drive.'
        return
    }
    $script:deepRoot = $sroot
    $script:deepReady = $false
    $script:deepHasMeta = $false
    $script:deepExifStarted = $false
    $script:deepExif = $null
    $script:deepFields = @{}
    try { $script:deepIdx = New-Object DeepSearchIndex } catch { $script:deepIdx = $null }
    $w = New-Object DeepWalker2
    $script:deepWalker = $w
    $w.Start($sroot, 100000, [string[]]$script:xmpEmbedded)
    $txtStatus.Text = 'Searching subfolders...'
    Show-DeepProgress
    $deepTimer.Start()
}

$deepTimer = New-Object System.Windows.Threading.DispatcherTimer
$deepTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$deepTimer.Add_Tick({
    try {
        $w = $script:deepWalker
        if (-not $w) { $deepTimer.Stop(); Hide-DeepProgress; return }
        if (-not $w.Done) { $txtStatus.Text = "Searching subfolders... $($w.Count) files scanned"; return }
        if (-not $script:deepExifStarted) {
            $script:deepExifStarted = $true
            $rd = @($w.Readable)
            if ($rd.Count -eq 0) { $script:deepHasMeta = $true }
            elseif (Test-SearchNeedsMeta) {
                $lines = New-Object 'System.Collections.Generic.List[string]'
                foreach ($a in '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
                foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
                $lines.Add('-Model')
                foreach ($r in $rd) { $lines.Add($r) }
                $argFile = Join-Path $root 'cache\_deep_args.txt'
                [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
                $x0 = New-Object AsyncExif
                $script:deepExif = $x0
                $x0.Start($cfg.ExifToolPath, $argFile)
                return
            }
        }
        $x = $script:deepExif
        if ($x -and -not $x.Done) { $txtStatus.Text = "Reading XMP from $(@($w.Readable).Count) files..."; return }
        $deepTimer.Stop()
        Hide-DeepProgress
        if ($x) { Import-DeepMeta $w $x.Output; $script:deepHasMeta = $true }
        $script:deepReady = $true
        $script:metaReady = $true
        Show-DeepResults
    } catch {
        $deepTimer.Stop()
        Hide-DeepProgress
        $txtStatus.Text = 'Subfolder search error: ' + $_.Exception.Message
        Write-Log $_.Exception.ToString()
    }
})

$btnDeepCancel.Add_Click({
    try {
        $deepTimer.Stop()
        if ($script:deepWalker) { $script:deepWalker.Stop() }
        if ($script:deepExif) { $script:deepExif.Kill() }
        $script:deepWalker = $null
        $script:deepExif = $null
        $script:deepReady = $false
        $script:deepHasMeta = $false
        Hide-DeepProgress
        $chkSub.IsChecked = $false
        Apply-Search
        $txtStatus.Text = 'Subfolder search cancelled   |   ' + $txtStatus.Text
    } catch { Write-Log $_.Exception.ToString() }
})

# ---------- Apply / reset ----------
function Apply-Search {
    $raw = $txtSearch.Text.Trim()
    $pq = Parse-SearchQuery $raw
    $script:searchTerms = $pq.Plain
    $script:fieldTerms = $pq.Fields
    if ($script:searchTerms.Count -eq 0 -and $script:fieldTerms.Count -eq 0) {
        Stop-Deep
        Restore-Folder
        $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list.ItemsSource)
        if ($v) { $v.Filter = $null; $v.Refresh() }
        if ($script:folderStatus) { $txtStatus.Text = $script:folderStatus }
        return
    }
    $needMeta = Test-SearchNeedsMeta

    if ($chkSub.IsChecked) {
        if (-not $script:metaReady -and $script:deepReady) {
            $script:deepReady = $false; $script:deepWalker = $null; $script:deepExif = $null
        }
        if ($script:deepReady -and $needMeta -and -not $script:deepHasMeta) {
            $script:deepReady = $false; $script:deepWalker = $null; $script:deepExif = $null
        }
        if ($script:deepReady) { Show-DeepResults; return }
        if ($script:deepWalker) { $deepTimer.Start(); return }
        Start-Deep
        return
    }

    Stop-Deep
    Restore-Folder
    $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list.ItemsSource)
    if (-not $v) { return }
    if ($needMeta -and -not $script:metaReady) {
        $txtStatus.Text = 'Indexing XMP metadata...'
        $win.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        Build-MetaIndex
    }
    $v.Filter = $script:searchPredicate
    $v.Refresh()
    $cnt = 0
    foreach ($x in $v) { $cnt++ }
    $txtStatus.Text = "$cnt match(es) for '$raw'   |   $($script:folderStatus)"
}

function Reset-Search {
    $script:metaReady = $false
    $script:metaText = @{}
    $script:metaObjs = @{}
    $script:metaFields = @{}
    $script:searchTerms = @()
    $script:fieldTerms = @()
    $script:deepReady = $false
    $script:deepHasMeta = $false
    Stop-Deep
    $script:deepWalker = $null
    $script:deepExif = $null
    $script:deepActive = $false
    Set-FolderCol $false
    if ($txtSearch.Text) { $txtSearch.Text = '' }
}

# ---------- Names only toggle, recent searches, wider search box ----------
$txtSearch.Width = 230
$txtSearch.ToolTip = "Search file names and XMP. All words must match.`nField search: tag:holiday  title:paris  author:name  comment:text  copyright:text  camera:model  rating:4  rating:>=3  ext:jpg  name:text`nUse quotes for phrases. Esc clears."

$chkName = New-Object System.Windows.Controls.CheckBox
$chkName.Content = 'Names only'
$chkName.FontSize = 12
$chkName.VerticalAlignment = 'Center'
$chkName.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
$chkName.ToolTip = "Plain words match file names only (XMP is ignored).`nfield:value terms such as tag:holiday still work."
[System.Windows.Controls.DockPanel]::SetDock($chkName, [System.Windows.Controls.Dock]::Right)
$txtSearch.Parent.Children.Add($chkName) | Out-Null
$chkName.Add_Click({
    $script:nameOnly = [bool]$chkName.IsChecked
    $searchTimer.Stop()
    Apply-Search
})

$script:recentSearches = @()
try {
    if ([IO.File]::Exists($settingsFile)) {
        $st17 = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($st17 -and $st17.RecentSearches) { $script:recentSearches = @($st17.RecentSearches | ForEach-Object { [string]$_ } | Select-Object -First 10) }
    }
} catch { }

function Add-RecentSearch([string]$q) {
    $q = ([string]$q).Trim()
    if ($q.Length -lt 2) { return }
    $cur = @($script:recentSearches)
    if ($cur.Count -gt 0 -and $cur[0] -ieq $q) { return }
    $acc = New-Object 'System.Collections.Generic.List[string]'
    $acc.Add($q)
    foreach ($r in $cur) { if ($r -and $r -ine $q -and $acc.Count -lt 10) { $acc.Add($r) } }
    $script:recentSearches = $acc.ToArray()
    Set-Setting 'RecentSearches' ([string[]]$script:recentSearches)
}
function Clear-RecentSearches {
    $script:recentSearches = @()
    Set-Setting 'RecentSearches' ([string[]]@())
}
function Use-RecentSearch([string]$q) {
    if (-not $q) { return }
    Add-RecentSearch $q
    if ($txtSearch.Text -eq $q) { $searchTimer.Stop(); Apply-Search } else { $txtSearch.Text = $q }
    $txtSearch.Focus() | Out-Null
    $txtSearch.CaretIndex = $txtSearch.Text.Length
}
function Show-RecentSearches {
    $cm = New-Object System.Windows.Controls.ContextMenu
    $recent = @($script:recentSearches)
    if ($recent.Count -eq 0) {
        $mi0 = New-Object System.Windows.Controls.MenuItem
        $mi0.Header = '(no recent searches yet)'
        $mi0.IsEnabled = $false
        [void]$cm.Items.Add($mi0)
    } else {
        foreach ($r in $recent) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $tbk = New-Object System.Windows.Controls.TextBlock
            $tbk.Text = [string]$r
            $mi.Header = $tbk
            $mi.Tag = [string]$r
            $mi.Add_Click({ param($s, $e) Use-RecentSearch ([string]$s.Tag) })
            [void]$cm.Items.Add($mi)
        }
        [void]$cm.Items.Add((New-Object System.Windows.Controls.Separator))
        $mc = New-Object System.Windows.Controls.MenuItem
        $mc.Header = 'Clear recent searches'
        $mc.Add_Click({ Clear-RecentSearches })
        [void]$cm.Items.Add($mc)
    }
    $cm.PlacementTarget = $btnRecent
    $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $cm.IsOpen = $true
}

$btnRecent = New-Object System.Windows.Controls.Button
try { $btnRecent.Style = $win.FindResource('TB') } catch { }
$btnRecent.Content = [string][char]0x25BE
$btnRecent.Width = 22
$btnRecent.Height = 26
$btnRecent.Margin = [System.Windows.Thickness]::new(2, 0, 0, 0)
$btnRecent.Focusable = $false
$btnRecent.ToolTip = 'Recent searches'
[System.Windows.Controls.DockPanel]::SetDock($btnRecent, [System.Windows.Controls.Dock]::Right)
$s17Bar = $txtSearch.Parent
$s17Bar.Children.Insert($s17Bar.Children.IndexOf($txtSearch), $btnRecent)
$btnRecent.Add_Click({ Show-RecentSearches })

$txtSearch.AddHandler([System.Windows.UIElement]::PreviewKeyDownEvent, [System.Windows.Input.KeyEventHandler]{
    param($s, $e)
    if ($e.Key -eq 'Return') { Add-RecentSearch $txtSearch.Text }
}, $true)
$txtSearch.Add_LostKeyboardFocus({ Add-RecentSearch $txtSearch.Text })

$s17Help = @(
'SEARCHING',
'Type words to match file names and XMP metadata; every word must match. To search one field only, use field:value, for example tag:holiday, title:paris, author:andrew, comment:wedding, copyright:snell, subject:harbour, camera:x-e5, rating:4, rating:>=3, ext:jpg or name:img. Put quotes round a phrase: tag:"new york". Field terms match part of a word, so tag:holiday also finds holidays. Tag: is the Tags box; subject: is the Subject box.',
'Tick Names only to match plain words against file names only; field:value terms still work. It also makes subfolder searches much faster because XMP is not read.',
'Tick Subfolders to search below this folder. The bar at the bottom shows progress and Cancel search stops it. The arrow beside the search box lists your recent searches.'
) -join "`n"
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`n" + $s17Help + "`n`nPress F1 any time")
# ===== END SCRIPT17 =====

# ===== SCRIPT18-MARKER =====
# ---------- Negated search terms: -tag:holiday  -rating:>=3  -word ----------
$script:negPlain = @()
$script:negFields = @()

function Parse-SearchQuery([string]$q) {
    $plain = New-Object 'System.Collections.Generic.List[string]'
    $fl = New-Object 'System.Collections.Generic.List[object]'
    $np = New-Object 'System.Collections.Generic.List[string]'
    $nf = New-Object 'System.Collections.Generic.List[object]'
    $q = ([string]$q).ToLowerInvariant()
    foreach ($m in [regex]::Matches($q, '(-(?=[a-z"]))?(?:([a-z]+):)?(?:"([^"]*)"|(\S+))')) {
        $neg = $m.Groups[1].Success
        $pre = $m.Groups[2].Value
        if ($m.Groups[3].Success) { $val = $m.Groups[3].Value } else { $val = $m.Groups[4].Value.Trim('"') }
        $val = $val.Trim()
        if ($pre -and $script:fieldAlias.ContainsKey($pre)) {
            if (-not $val) { continue }
            $key = $script:fieldAlias[$pre]
            if ($key -eq 'Rating') {
                $op = '='
                $num = $null
                if ($val -match '^(>=|<=|>|<|=)?\s*(\d+)$') {
                    if ($matches[1]) { $op = $matches[1] }
                    $num = [int]$matches[2]
                } elseif ($val -eq 'none' -or $val -eq 'unrated') { $num = 0 }
                if ($null -eq $num) { continue }
                $ft = @{ Key = 'Rating'; Op = $op; Num = $num; Value = $val }
            } else {
                if ($key -eq '_ext') { $val = $val.TrimStart('.') }
                if (-not $val) { continue }
                $ft = @{ Key = $key; Op = ''; Num = 0; Value = $val }
            }
            if ($neg) { $nf.Add($ft) } else { $fl.Add($ft) }
        } else {
            if ($pre) { $val = $m.Value.TrimStart('-').Trim().Trim('"') }
            if (-not $val) { continue }
            if ($val -match '^([a-z]+):$' -and $script:fieldAlias.ContainsKey($matches[1])) { continue }
            if ($neg) { $np.Add($val) } else { $plain.Add($val) }
        }
    }
    # a query of only negatives starts from "everything"
    if ($plain.Count -eq 0 -and $fl.Count -eq 0 -and ($np.Count + $nf.Count) -gt 0) {
        $fl.Add(@{ Key = '_name'; Op = ''; Num = 0; Value = '' })
    }
    $script:negPlain = $np.ToArray()
    $script:negFields = $nf.ToArray()
    return @{ Plain = $plain.ToArray(); Fields = $fl.ToArray() }
}

function Test-Excluded([string]$fileName, $ff, [string]$metaText) {
    $nm = $fileName.ToLowerInvariant()
    foreach ($t in @($script:negPlain)) {
        if (-not $t) { continue }
        if ($nm.Contains($t)) { return $true }
        if ((-not $script:nameOnly) -and $metaText -and $metaText.Contains($t)) { return $true }
    }
    foreach ($ft in @($script:negFields)) {
        if ($ft -and (Test-FieldTerm $ft $fileName $ff)) { return $true }
    }
    return $false
}

function Test-SearchNeedsMeta {
    foreach ($ft in (@($script:fieldTerms) + @($script:negFields))) {
        if ($ft -and $ft.Key -ne '_name' -and $ft.Key -ne '_ext') { return $true }
    }
    if (-not $script:nameOnly -and (@($script:searchTerms).Count -gt 0 -or @($script:negPlain).Count -gt 0)) { return $true }
    return $false
}

$script:prevPredicate18 = $script:searchPredicate
$script:searchPredicate = [System.Predicate[object]]{
    param($o)
    if (-not $script:prevPredicate18.Invoke($o)) { return $false }
    if (@($script:negPlain).Count -eq 0 -and @($script:negFields).Count -eq 0) { return $true }
    if ($o.IsDir) { return $true }
    $ff = $null
    if (@($script:negFields).Count -gt 0) { $ff = Get-CachedFields $o.FullPath }
    $mt = $script:metaText[$o.FullPath]
    if (Test-Excluded $o.Name $ff $mt) { return $false }
    return $true
}

function Show-DeepResults {
    $w = $script:deepWalker
    if (-not $w -or (@($script:searchTerms).Count -eq 0 -and @($script:fieldTerms).Count -eq 0)) { return }
    $terms = [string[]]@($script:searchTerms)
    if ($script:deepIdx) {
        $fts = @($script:fieldTerms)
        $fKeys = [string[]]@($fts | ForEach-Object { $_.Key })
        $fOps = [string[]]@($fts | ForEach-Object { $_.Op })
        $fVals = [string[]]@($fts | ForEach-Object { $_.Value })
        $fNums = [int[]]@($fts | ForEach-Object { [int]$_.Num })
        $files = [string[]]([DeepWalker2].GetField('files', [System.Reflection.BindingFlags]'Instance,NonPublic').GetValue($w))
        $paths = @($script:deepIdx.Run($files, $w.Meta, $terms, [bool]$script:nameOnly, $fKeys, $fOps, $fVals, $fNums, 2000))
    } else {
        $paths = @($w.Filter($terms, 2000))
    }
    if (@($script:negPlain).Count -gt 0 -or @($script:negFields).Count -gt 0) {
        $paths = @($paths | Where-Object {
            $ff = $null
            $o2 = $script:deepFields[([string]$_).ToLowerInvariant()]
            if ($o2) { $ff = Get-FieldMap $o2 }
            $mt = $null
            try { $mt = $w.Meta[[string]$_] } catch { }
            -not (Test-Excluded ([IO.Path]::GetFileName([string]$_)) $ff $mt)
        })
    }
    $items = New-Object 'System.Collections.Generic.List[FileItem]'
    $script:suppressFieldCache = $true
    try {
        foreach ($pth in $paths) {
            $i = New-ItemFromPath $pth $script:deepRoot
            if ($i) {
                $o = $script:deepFields[$pth.ToLowerInvariant()]
                if ($o) { Set-ItemCols $i $o }
                $items.Add($i)
            }
        }
    } finally { $script:suppressFieldCache = $false }
    $script:deepActive = $true
    $list.ItemsSource = $items
    Set-FolderCol $true
    Apply-Sort
    Start-ShellThumbs $items $true
    $more = ''
    if ($paths.Count -ge 2000) { $more = ' (first 2000 shown)' }
    $txtStatus.Text = "$($items.Count) match(es) in subfolders$more for '$($txtSearch.Text.Trim())'   |   $($w.FileCount) files searched"
}

$txtSearch.ToolTip = "Search file names and XMP. All words must match.`nField search: tag:holiday  title:paris  author:name  comment:text  copyright:text  camera:model  rating:4  rating:>=3  ext:jpg  name:text`nPut - in front to exclude: -tag:holiday  -rating:>=3  -draft`nUse quotes for phrases. Esc clears."

# ---------- Recent-searches arrow: make it visible ----------
try {
    $btnRecent.Padding = [System.Windows.Thickness]::new(0)
    $btnRecent.Width = 24
    $btnRecent.FontSize = 15
    $btnRecent.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Symbol')
    $btnRecent.Foreground = [System.Windows.Media.Brushes]::Black
    $btnRecent.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#E3EAF3')
} catch { Write-Log ('btnRecent: ' + $_.Exception.Message) }

# ---------- Comments + Taken columns ----------
$script:prevSetItemCols18 = ${function:Set-ItemCols}
function Set-ItemCols($it, $o) {
    & $script:prevSetItemCols18 $it $o
    try {
        $it.CommentText = ((Get-FieldText $o 'Description') -replace '\s+', ' ').Trim()
        $tk = Get-FieldText $o 'DateTimeOriginal'
        if ($tk.Length -ge 16) { $it.TakenText = ($tk.Substring(0, 10) -replace ':', '-') + ' ' + $tk.Substring(11, 5) }
        elseif (-not $it.TakenText) { $it.TakenText = '' }
    } catch { }
}

function Start-ColMeta($items) {
    Stop-ColMeta
    $map = @{}
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in '-j', '-charset', 'filename=utf8') { $lines.Add($a) }
    foreach ($f in $fields) { $lines.Add('-' + $f.Tag) }
    $lines.Add('-Model')
    $lines.Add('-DateTimeOriginal')
    foreach ($it in $items) {
        if ($it.IsDir -or $it.IsCloud) { continue }
        $mode = Get-XmpMode $it
        if (-not $mode) { continue }
        if ($mode -eq 'office') { $script:offQueue.Enqueue($it); continue }
        $tp = Get-MetaTarget $it
        if ([IO.File]::Exists($tp)) { $map[$tp.ToLowerInvariant()] = $it; $lines.Add($tp) }
    }
    if ($script:offQueue.Count -gt 0) { $offTimer.Start() }
    if ($map.Count -eq 0) { return }
    $argFile = Join-Path $root 'cache\_cols_args.txt'
    [IO.File]::WriteAllLines($argFile, $lines, (New-Object Text.UTF8Encoding($false)))
    $script:colMap = $map
    $x = New-Object AsyncExif
    $script:colExif = $x
    $x.Start($cfg.ExifToolPath, $argFile)
    $colTimer.Start()
}

$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource
    if ($h -is [System.Windows.Controls.GridViewColumnHeader] -and $h.Role -ne 'Padding') {
        $map18 = @{ 'Comments' = 'CommentText'; 'Taken' = 'TakenText' }
        $prop = $map18["$($h.Content)"]
        if ($prop) {
            if ($script:sortProp -eq $prop -and $script:sortDir -eq 'Ascending') { $script:sortDir = 'Descending' }
            else { $script:sortProp = $prop; $script:sortDir = 'Ascending' }
            Apply-Sort
        }
    }
})

# ---------- Undo save (restores the _original backup; needs KeepBackups) ----------
function Do-UndoSave {
    if (-not $cfg.KeepBackups) { $txtStatus.Text = 'Select files... Undo needs KeepBackups set to true in config.json (backups end in _original).'; return }
    $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir })
    if ($sel.Count -eq 0) { $txtStatus.Text = 'Select the files to undo first.'; return }
    $pairs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in $sel) {
        $tp = Get-MetaTarget $it
        $bk = $tp + '_original'
        if ([IO.File]::Exists($bk)) { $pairs.Add(@{ Target = $tp; Backup = $bk }) }
    }
    if ($pairs.Count -eq 0) { $txtStatus.Text = 'No metadata backups (_original) found for the selected files.'; return }
    if ((Msg "Restore $($pairs.Count) file(s) from their _original backups?`nThis replaces the current files." 'YesNo' 'Question') -ne 'Yes') { return }
    Stop-Thumbs
    Stop-ColMeta
    $done = 0; $errs = @()
    foreach ($p in $pairs) {
        try { Move-Item -LiteralPath $p.Backup -Destination $p.Target -Force -ErrorAction Stop; $done++ }
        catch { $errs += ([IO.Path]::GetFileName($p.Target) + ': ' + $_.Exception.Message) }
    }
    $script:metaReady = $false
    if ($script:deepActive) { Apply-Search } else { Refresh-All }
    $txtStatus.Text = "Restored $done file(s) from backup"
    if ($errs.Count -gt 0) { [void](Msg ("Some files could not be restored:`n`n" + ($errs -join "`n")) 'OK' 'Warning') }
}

# ---------- Batch rename from metadata ----------
function Get-RenameData($sel) {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($it in $sel) {
        $paths.Add($it.FullPath)
        $mt = Get-MetaTarget $it
        if ($mt -ne $it.FullPath -and [IO.File]::Exists($mt)) { $paths.Add($mt) }
    }
    $all = @($paths | Select-Object -Unique)
    $res = @{}
    for ($i = 0; $i -lt $all.Count; $i += 100) {
        $chunk = @($all[$i..([Math]::Min($i + 99, $all.Count - 1))])
        $cmd = @('-j', '-charset', 'filename=utf8', '-m', '-DateTimeOriginal', '-CreateDate', '-Title', '-Headline', '-Creator', '-Model', '-Rating')
        $cmd += $chunk
        try {
            $json = $script:et.Run([string[]]$cmd)
            if (-not $json.Trim()) { continue }
            $objs = @()
            $objs += (ConvertFrom-Json $json)
            foreach ($o in $objs) { $res[(("$($o.SourceFile)") -replace '/', '\').ToLowerInvariant()] = $o }
        } catch { Write-Log ('Get-RenameData: ' + $_.Exception.Message) }
    }
    return $res
}

function Get-RenameInfo($it) {
    $fo = $script:brData[$it.FullPath.ToLowerInvariant()]
    $mo = $script:brData[(Get-MetaTarget $it).ToLowerInvariant()]
    if (-not $mo) { $mo = $fo }
    $dt = $null
    foreach ($src in @($fo, $mo)) {
        if (-not $src -or $dt) { continue }
        foreach ($tg in 'DateTimeOriginal', 'CreateDate') {
            if ($dt) { break }
            $v = Get-FieldText $src $tg
            $mm = [regex]::Match($v, '^(\d{4}):(\d\d):(\d\d)[ T](\d\d):(\d\d):(\d\d)')
            if ($mm.Success) {
                try { $dt = [datetime]::new([int]$mm.Groups[1].Value, [int]$mm.Groups[2].Value, [int]$mm.Groups[3].Value, [int]$mm.Groups[4].Value, [int]$mm.Groups[5].Value, [int]$mm.Groups[6].Value) } catch { $dt = $null }
            }
        }
    }
    if (-not $dt) { try { $dt = [IO.File]::GetLastWriteTime($it.FullPath) } catch { $dt = Get-Date } }
    $r = @{}
    $r['date'] = $dt.ToString('yyyyMMdd')
    $r['time'] = $dt.ToString('HHmmss')
    $r['title'] = Get-FieldText $mo 'Title'
    $r['subject'] = Get-FieldText $mo 'Headline'
    $r['author'] = Get-FieldText $mo 'Creator'
    $r['camera'] = Get-FieldText $mo 'Model'
    $r['rating'] = Get-FieldText $mo 'Rating'
    $r['name'] = [IO.Path]::GetFileNameWithoutExtension($it.Name)
    return $r
}

function New-RenamePlan([string]$pattern) {
    $plan = New-Object 'System.Collections.Generic.List[object]'
    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $trimChars = [char[]]' ._-'
    $n = 0
    foreach ($it in $script:brSel) {
        $n++
        $e = @{ Item = $it; Old = $it.Name; New = $it.Name; Skip = '' }
        if ([string]::IsNullOrWhiteSpace($pattern)) { $e.Skip = 'empty pattern'; $plan.Add($e); continue }
        $v = Get-RenameInfo $it
        $v['n'] = $n.ToString('000')
        $s = $pattern
        foreach ($k in @($v.Keys)) {
            $s = [regex]::Replace($s, [regex]::Escape('{' + $k + '}'), ([string]$v[$k]).Replace('$', '$$'), 'IgnoreCase')
        }
        $s = (($s.ToCharArray() | Where-Object { $bad -notcontains $_ }) -join '')
        $s = ($s -replace '\s+', ' ' -replace '_{2,}', '_').Trim($trimChars)
        if ($s.Length -gt 150) { $s = $s.Substring(0, 150).Trim($trimChars) }
        if (-not $s) { $e.Skip = 'nothing left after filling the pattern'; $plan.Add($e); continue }
        $ext = [IO.Path]::GetExtension($it.Name)
        $dir = [IO.Path]::GetDirectoryName($it.FullPath)
        $mode = Get-XmpMode $it
        $cand = $s + $ext
        $i = 2
        while ($true) {
            $cf = Join-Path $dir $cand
            if ($cf -ieq $it.FullPath) { break }
            $occ = ($taken.Contains($cf) -or [IO.File]::Exists($cf) -or [IO.Directory]::Exists($cf))
            if (-not $occ -and $mode -eq 'sidecar') { $occ = [IO.File]::Exists([IO.Path]::ChangeExtension($cf, 'xmp')) }
            if (-not $occ) { break }
            $cand = $s + '_' + $i + $ext
            $i++
            if ($i -gt 999) { break }
        }
        [void]$taken.Add((Join-Path $dir $cand))
        $e.New = $cand
        $plan.Add($e)
    }
    return $plan.ToArray()
}

function Update-RenamePreview {
    $plan = @(New-RenamePlan $script:brTb.Text)
    $script:brPlan = $plan
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $skip = 0; $chg = 0
    foreach ($p in $plan) {
        if ($p.Skip) { $skip++; $t = $p.Old + '   ->   (skipped: ' + $p.Skip + ')' }
        elseif ($p.New -ceq $p.Old) { $t = $p.Old + '   (no change)' }
        else { $chg++; $t = $p.Old + '   ->   ' + $p.New }
        if ($lines.Count -lt 400) { $lines.Add($t) }
    }
    $script:brLb.ItemsSource = $lines
    $script:brSum.Text = "$chg to rename, $skip skipped, $($plan.Count - $chg - $skip) unchanged"
    $script:brOk.IsEnabled = ($chg -gt 0)
}

function Do-BatchRename {
    $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir })
    if ($sel.Count -eq 0) { $txtStatus.Text = 'Select the files to rename first.'; return }
    $txtStatus.Text = "Reading metadata for $($sel.Count) file(s)..."
    try { $win.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { }
    $script:brSel = $sel
    $script:brData = Get-RenameData $sel
    $pat = '{date}_{title}'
    try {
        if ([IO.File]::Exists($settingsFile)) {
            $st18 = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ($st18 -and $st18.RenamePattern) { $pat = [string]$st18.RenamePattern }
        }
    } catch { }

    $w = New-Object System.Windows.Window
    $w.Title = 'Batch rename from metadata'
    $w.Width = 720; $w.Height = 560
    $w.Owner = $win
    $w.WindowStartupLocation = 'CenterOwner'
    $dock = New-Object System.Windows.Controls.DockPanel
    $dock.Margin = [System.Windows.Thickness]::new(12)
    $top = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.DockPanel]::SetDock($top, [System.Windows.Controls.Dock]::Top)
    $l1 = New-Object System.Windows.Controls.TextBlock
    $l1.Text = "New name pattern (the file extension is kept; nothing is ever overwritten):"
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = $pat
    $tb.Height = 28; $tb.FontSize = 14
    $tb.VerticalContentAlignment = 'Center'
    $tb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $l2 = New-Object System.Windows.Controls.TextBlock
    $l2.Text = "Tokens: {date} yyyymmdd (date taken, else file date)   {time} hhmmss   {title}   {subject}   {author}   {camera}   {rating}   {name} (old name)   {n} 001, 002...`nExamples: {date}_{title}    {date}_{time}    {date}_{subject}_{n}"
    $l2.TextWrapping = 'Wrap'; $l2.FontSize = 11
    $l2.Foreground = [System.Windows.Media.Brushes]::DimGray
    $l2.Margin = [System.Windows.Thickness]::new(0, 6, 0, 8)
    [void]$top.Children.Add($l1); [void]$top.Children.Add($tb); [void]$top.Children.Add($l2)
    $bot = New-Object System.Windows.Controls.StackPanel
    $bot.Orientation = 'Horizontal'
    $bot.HorizontalAlignment = 'Right'
    $bot.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($bot, [System.Windows.Controls.Dock]::Bottom)
    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = 'Rename'; $ok.Width = 90; $ok.Height = 30; $ok.IsDefault = $true
    $ok.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cn = New-Object System.Windows.Controls.Button
    $cn.Content = 'Cancel'; $cn.Width = 90; $cn.Height = 30; $cn.IsCancel = $true
    [void]$bot.Children.Add($ok); [void]$bot.Children.Add($cn)
    $sum = New-Object System.Windows.Controls.TextBlock
    $sum.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($sum, [System.Windows.Controls.Dock]::Bottom)
    $lb = New-Object System.Windows.Controls.ListBox
    $lb.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $lb.FontSize = 12
    [void]$dock.Children.Add($top); [void]$dock.Children.Add($bot); [void]$dock.Children.Add($sum); [void]$dock.Children.Add($lb)
    $w.Content = $dock
    $script:brWin = $w; $script:brTb = $tb; $script:brLb = $lb; $script:brSum = $sum; $script:brOk = $ok
    Update-RenamePreview
    $tb.Add_TextChanged({ Update-RenamePreview })
    $ok.Add_Click({ $script:brWin.DialogResult = $true })
    $tb.Focus() | Out-Null
    $tb.CaretIndex = $tb.Text.Length
    $res = $w.ShowDialog()
    $txtStatus.Text = $script:folderStatus
    if ($res -ne $true) { return }
    $patNow = [string]$script:brTb.Text
    Set-Setting 'RenamePattern' $patNow
    $todo = @($script:brPlan | Where-Object { -not $_.Skip -and $_.New -cne $_.Old })
    if ($todo.Count -eq 0) { return }

    Stop-Thumbs
    Stop-ColMeta
    $done = 0; $errs = @()
    foreach ($p in $todo) {
        try {
            $old = $p.Item.FullPath
            $dir = [IO.Path]::GetDirectoryName($old)
            $newFull = Join-Path $dir $p.New
            Rename-Item -LiteralPath $old -NewName $p.New -ErrorAction Stop
            if ((Get-XmpMode $p.Item) -eq 'sidecar') {
                $ox = [IO.Path]::ChangeExtension($old, 'xmp')
                $nx = [IO.Path]::GetFileName([IO.Path]::ChangeExtension($newFull, 'xmp'))
                if ([IO.File]::Exists($ox)) { Rename-Item -LiteralPath $ox -NewName $nx -ErrorAction Stop }
                if ([IO.File]::Exists($ox + '_original')) { Rename-Item -LiteralPath ($ox + '_original') -NewName ($nx + '_original') -ErrorAction Stop }
            }
            if ([IO.File]::Exists($old + '_original')) { Rename-Item -LiteralPath ($old + '_original') -NewName ($p.New + '_original') -ErrorAction Stop }
            $done++
        } catch { $errs += ($p.Old + ': ' + $_.Exception.Message) }
    }
    $script:metaReady = $false
    if ($script:deepActive) { Apply-Search } else { Refresh-All }
    $txtStatus.Text = "Renamed $done file(s)"
    if ($errs.Count -gt 0) { [void](Msg ("Some files could not be renamed:`n`n" + ($errs -join "`n")) 'OK' 'Warning') }
}

# ---------- Toolbar buttons + right-click entry ----------
try {
    $s18Move = $win.FindName('btnMoveTo')
    $s18Bar = $s18Move.Parent
    $s18Idx = $s18Bar.Children.IndexOf($s18Move)
    $btnUndo = New-Object System.Windows.Controls.Button
    $btnUndo.Content = 'Undo save'
    try { $btnUndo.Style = $win.FindResource('TB') } catch { }
    $btnUndo.ToolTip = "Restore the selected files from their _original backups.`nNeeds KeepBackups = true in config.json."
    $btnUndo.Add_Click({ Do-UndoSave })
    $btnBR = New-Object System.Windows.Controls.Button
    $btnBR.Content = 'Batch rename'
    try { $btnBR.Style = $win.FindResource('TB') } catch { }
    $btnBR.ToolTip = 'Rename the selected files from their metadata, e.g. {date}_{title}'
    $btnBR.Add_Click({ Do-BatchRename })
    $s18Bar.Children.Insert($s18Idx + 1, $btnUndo)
    $s18Bar.Children.Insert($s18Idx + 2, $btnBR)
} catch { Write-Log ('toolbar18: ' + $_.Exception.ToString()) }
try {
    $mi18 = New-Object System.Windows.Controls.MenuItem
    $mi18.Header = 'Batch rename from metadata...'
    $mi18.Add_Click({ Do-BatchRename })
    $list.ContextMenu.Items.Insert(4, $mi18)
} catch { }

# ---------- Window title from $script:appVersion + red tile / green v3 window icon ----------
function Update-WinTitle {
    try {
        $p = [string]$txtPath.Text
        $t = 'MetadataEditor v' + $script:appVersion
        if ($p) {
            $leaf = [IO.Path]::GetFileName($p.TrimEnd('\'))
            if (-not $leaf) { $leaf = $p }
            $win.Title = "$leaf  -  $t"
        } else { $win.Title = $t }
    } catch { }
}
Update-WinTitle

try {
    $dv18 = New-Object System.Windows.Media.DrawingVisual
    $dc18 = $dv18.RenderOpen()
    $bg18 = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(198, 40, 40))
    $dc18.DrawRoundedRectangle($bg18, $null, [System.Windows.Rect]::new(2, 2, 60, 60), 12, 12)
    $gr18 = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(105, 240, 174))
    $ft18 = New-Object System.Windows.Media.FormattedText('v3', [Globalization.CultureInfo]::InvariantCulture, [System.Windows.FlowDirection]::LeftToRight, (New-Object System.Windows.Media.Typeface('Segoe UI')), 36, $gr18)
    $ft18.SetFontWeight([System.Windows.FontWeights]::Bold)
    $dc18.DrawText($ft18, [System.Windows.Point]::new(32 - $ft18.Width / 2, 32 - $ft18.Height / 2))
    $dc18.Close()
    $rtb18 = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb18.Render($dv18)
    $rtb18.Freeze()
    $win.Icon = $rtb18
} catch { Write-Log ('icon18: ' + $_.Exception.Message) }

# ---------- Help ----------
$s18Help = @(
'NEW IN THIS VERSION',
'Exclude with a minus sign: -tag:holiday, -rating:>=3, -draft. Combine freely, for example tag:paris -tag:holiday ext:jpg.',
'The Taken column is the date the photo was taken (from the file metadata). Created is the date the file was created on this computer, which changes when a file is copied. Comments is the XMP comment text.',
'Undo save restores the selected files from their _original backups (KeepBackups must be true in config.json).',
'Batch rename (button or right-click) renames the selected files from their metadata, for example {date}_{title}. It never overwrites: a clash gets _2, _3 added. RAW sidecar .xmp files and _original backups are renamed with their file.'
) -join "`n"
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`n" + $s18Help + "`n`nPress F1 any time")
# ===== END SCRIPT18 =====
# ===== SCRIPT19-MARKER =====
# ---------- Larger fonts: toolbar, left, centre and right panes ----------
$script:fontBump = 2
try {
    if ([IO.File]::Exists($settingsFile)) {
        $st19 = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($st19 -and $st19.FontBump -ne $null) { $script:fontBump = [Math]::Max(0, [Math]::Min(8, [double]$st19.FontBump)) }
    }
} catch { }

function Bump-Fonts($el, [double]$d) {
    if ($el -is [System.Windows.Controls.TextBox]) {
        $el.FontSize = $el.FontSize + $d
        if ($el.Height -gt 0) { $el.Height = $el.Height + 2 * $d }
        return
    }
    if ($el -is [System.Windows.Controls.TextBlock] -or $el -is [System.Windows.Controls.Primitives.ButtonBase]) {
        $el.FontSize = $el.FontSize + $d
        return
    }
    if ($el -is [System.Windows.DependencyObject]) {
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($el)) {
            if ($c -is [System.Windows.DependencyObject]) { Bump-Fonts $c $d }
        }
    }
}

if ($script:fontBump -gt 0) {
    try {
        Bump-Fonts $win.FindName('btnBack').Parent $script:fontBump    # toolbar
        $tree.FontSize = $tree.FontSize + $script:fontBump              # left pane
        $list.FontSize = $list.FontSize + $script:fontBump              # centre pane
        Bump-Fonts $txtName.Parent $script:fontBump                     # right pane
    } catch { Write-Log ('fontBump: ' + $_.Exception.ToString()) }
}
# ===== END SCRIPT19 =====
# ===== SCRIPT20-MARKER =====
# ---------- 1. Warn before a save creates _original backup copies ----------
function Confirm-BackupCopies($targets) {
    if (-not $cfg.KeepBackups) { return 'normal' }
    $new = @($targets | Where-Object { $_ -and -not [IO.File]::Exists($_ + '_original') }).Count
    if ($new -eq 0) { return 'normal' }
    $txt = "Backups are switched on (KeepBackups in config.json).`nThis save will create $new extra backup file(s) ending in _original next to your files.`n`nYes = save and keep the backup copies`nNo = save WITHOUT making backups`nCancel = do not save"
    $r = Msg $txt 'YesNoCancel' 'Warning'
    if ($r -eq 'Yes') { return 'normal' }
    if ($r -eq 'No') { return 'nobackup' }
    return 'cancel'
}

$script:prevInvokeXmpWrite20 = ${function:Invoke-XmpWrite}
function Invoke-XmpWrite($sel, $changes, $label) {
    $mode = 'normal'
    try { $mode = Confirm-BackupCopies @(Get-Targets $sel) } catch { Write-Log ('backup prompt: ' + $_.Exception.Message) }
    if ($mode -eq 'cancel') { $txtStatus.Text = 'Cancelled - nothing was changed.'; return }
    $saved = $cfg.KeepBackups
    if ($mode -eq 'nobackup') { $cfg.KeepBackups = $false }
    try { & $script:prevInvokeXmpWrite20 $sel $changes $label }
    finally { if ($mode -eq 'nobackup') { $cfg.KeepBackups = $saved } }
}

$script:prevSaveMetadata20 = ${function:Save-Metadata}
function Save-Metadata {
    $nb = $false
    try {
        if ($cfg.KeepBackups) {
            $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir } | Where-Object { Get-XmpMode $_ })
            $keys = @(); $bad = $false
            foreach ($f in $fields) {
                if ($f.Ctl.Text -ceq $script:loaded[$f.Key]) { continue }
                $keys += $f.Key
                if ($f.Key -eq 'Rating') { $nv = $f.Ctl.Text.Trim(); if ($nv -ne '' -and $nv -notmatch '^[0-5]$') { $bad = $true } }
            }
            if ($keys.Count -gt 0 -and -not $bad -and $sel.Count -gt 0) {
                $tg = @()
                $xs = @($sel | Where-Object { (Get-XmpMode $_) -ne 'office' })
                if ($xs.Count -gt 0) { $tg += @(Get-Targets $xs) }
                $officeKeys = @($keys | Where-Object { $_ -ne 'Rights' -and $_ -ne 'Rating' })
                if ($officeKeys.Count -gt 0) { $tg += @($sel | Where-Object { (Get-XmpMode $_) -eq 'office' } | ForEach-Object { $_.FullPath }) }
                $mode = Confirm-BackupCopies $tg
                if ($mode -eq 'cancel') { $txtStatus.Text = 'Cancelled - nothing was saved.'; return }
                if ($mode -eq 'nobackup') { $nb = $true }
            }
        }
    } catch { Write-Log ('backup prompt: ' + $_.Exception.Message) }
    $saved = $cfg.KeepBackups
    if ($nb) { $cfg.KeepBackups = $false }
    try { & $script:prevSaveMetadata20 }
    finally { if ($nb) { $cfg.KeepBackups = $saved } }
}

# ---------- 2. Copy / move: never overwrite silently; compare the two files ----------
function Format-FileSize20([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB ({1:N0} bytes)' -f ($b / 1GB), $b) }
    if ($b -ge 1MB) { return ('{0:N1} MB ({1:N0} bytes)' -f ($b / 1MB), $b) }
    if ($b -ge 1KB) { return ('{0:N0} KB ({1:N0} bytes)' -f ($b / 1KB), $b) }
    return ('{0:N0} bytes' -f $b)
}

function Get-ConflictInfo([string]$p, [bool]$isDir) {
    $r = @{}
    if ($isDir) {
        $di = New-Object IO.DirectoryInfo $p
        $r.Len = 0
        $r.Modified = $di.LastWriteTime
        $r.Text1 = ('{0} item(s)' -f @([IO.Directory]::GetFileSystemEntries($p)).Count)
    } else {
        $fi = New-Object IO.FileInfo $p
        $r.Len = $fi.Length
        $r.Modified = $fi.LastWriteTime
        $r.Text1 = Format-FileSize20 $fi.Length
    }
    $r.ModText = $r.Modified.ToString('d MMM yyyy HH:mm:ss')
    $r.Folder = [IO.Path]::GetDirectoryName($p)
    return $r
}

function New-GridCell20($grid, [string]$text, [int]$row, [int]$col, [bool]$bold, [string]$tip) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
    $tb.MaxWidth = 250
    $tb.TextTrimming = 'CharacterEllipsis'
    if ($bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($tip) { $tb.ToolTip = $tip }
    [System.Windows.Controls.Grid]::SetRow($tb, $row)
    [System.Windows.Controls.Grid]::SetColumn($tb, $col)
    [void]$grid.Children.Add($tb)
}

function Show-ConflictDialog([string]$src, [string]$dst, [bool]$isDir) {
    if ($script:xfAll) { return @{ Choice = $script:xfAll; All = $true } }
    $ei = Get-ConflictInfo $dst $isDir
    $si = Get-ConflictInfo $src $isDir
    $name = [IO.Path]::GetFileName($dst)

    $w = New-Object System.Windows.Window
    if ($isDir) { $w.Title = 'Folder already exists' } else { $w.Title = 'File already exists' }
    $w.SizeToContent = 'WidthAndHeight'
    $w.MinWidth = 620
    $w.ResizeMode = 'NoResize'
    $w.Owner = $win
    $w.WindowStartupLocation = 'CenterOwner'

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(18)
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = "'$name' already exists in the destination."
    $h.FontSize = 15
    $h.FontWeight = [System.Windows.FontWeights]::SemiBold
    $h.TextWrapping = 'Wrap'
    $h.MaxWidth = 640
    $h.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$sp.Children.Add($h)

    $g = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(270)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(270)
    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    for ($i = 0; $i -lt 4; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = [System.Windows.GridLength]::Auto
        [void]$g.RowDefinitions.Add($rd)
    }
    New-GridCell20 $g '' 0 0 $false ''
    New-GridCell20 $g 'Already there' 0 1 $true ''
    New-GridCell20 $g 'Incoming' 0 2 $true ''
    New-GridCell20 $g 'Folder' 1 0 $true ''
    New-GridCell20 $g $ei.Folder 1 1 $false $ei.Folder
    New-GridCell20 $g $si.Folder 1 2 $false $si.Folder
    if ($isDir) { $lab = 'Contains' } else { $lab = 'Size' }
    New-GridCell20 $g $lab 2 0 $true ''
    New-GridCell20 $g $ei.Text1 2 1 $false ''
    New-GridCell20 $g $si.Text1 2 2 $false ''
    New-GridCell20 $g 'Modified' 3 0 $true ''
    New-GridCell20 $g $ei.ModText 3 1 $false ''
    New-GridCell20 $g $si.ModText 3 2 $false ''
    [void]$sp.Children.Add($g)

    $noteText = ''
    if (-not $isDir) {
        $secs = ($si.Modified - $ei.Modified).TotalSeconds
        $bits = @()
        if ($secs -gt 2) { $bits += 'newer' } elseif ($secs -lt -2) { $bits += 'older' }
        if ($si.Len -gt $ei.Len) { $bits += 'larger' } elseif ($si.Len -lt $ei.Len) { $bits += 'smaller' }
        if ($bits.Count -eq 0) { $noteText = 'Both files have the same size and date - they are probably identical.' }
        else { $noteText = 'The incoming file is ' + ($bits -join ' and ') + ' than the one already there.' }
        $noteText = $noteText.Replace('newer than', 'newer than').Replace('older and', 'older and')
    }
    if ($noteText) {
        $nt = New-Object System.Windows.Controls.TextBlock
        $nt.Text = $noteText
        $nt.TextWrapping = 'Wrap'; $nt.MaxWidth = 640
        $nt.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
        [void]$sp.Children.Add($nt)
    }
    $tp = New-Object System.Windows.Controls.TextBlock
    if ($isDir) { $tp.Text = 'Merge copies the contents in; you are asked about each file that clashes. Keep both gives the incoming folder a new name.' }
    else { $tp.Text = 'Replace sends the existing file to the Recycle Bin first, so you can get it back. Keep both gives the incoming file a new name.' }
    $tp.TextWrapping = 'Wrap'; $tp.MaxWidth = 640
    $tp.Foreground = [System.Windows.Media.Brushes]::DimGray
    $tp.FontSize = 12
    $tp.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$sp.Children.Add($tp)

    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.Content = 'Do this for all remaining conflicts'
    $chk.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [void]$sp.Children.Add($chk)

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation = 'Horizontal'
    $bp.HorizontalAlignment = 'Right'
    $bp.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    $mk = {
        param($text)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $text; $b.Width = 100; $b.Height = 30
        $b.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        return $b
    }
    if ($isDir) { $rtxt = 'Merge' } else { $rtxt = 'Replace' }
    $bR = & $mk $rtxt
    $bB = & $mk 'Keep both'; $bB.IsDefault = $true
    $bS = & $mk 'Skip'
    $bC = & $mk 'Cancel'; $bC.IsCancel = $true
    $script:xfWin = $w; $script:xfChk = $chk; $script:xfChoice = 'cancel'
    $bR.Add_Click({ $script:xfChoice = 'replace'; $script:xfWin.Close() })
    $bB.Add_Click({ $script:xfChoice = 'both'; $script:xfWin.Close() })
    $bS.Add_Click({ $script:xfChoice = 'skip'; $script:xfWin.Close() })
    $bC.Add_Click({ $script:xfChoice = 'cancel'; $script:xfWin.Close() })
    foreach ($b in @($bR, $bB, $bS, $bC)) { [void]$bp.Children.Add($b) }
    [void]$sp.Children.Add($bp)
    $w.Content = $sp
    [void]$w.ShowDialog()

    $res = @{ Choice = $script:xfChoice; All = [bool]$script:xfChk.IsChecked }
    if ($res.All -and $res.Choice -ne 'cancel') { $script:xfAll = $res.Choice }
    return $res
}

function Do-Xfer([string]$src, [string]$target, [bool]$isDir, [bool]$move) {
    if ($move) { Move-Item -LiteralPath $src -Destination $target | Out-Null }
    else { Copy-Item -LiteralPath $src -Destination $target -Recurse | Out-Null }
}

function Merge-Folder([string]$srcDir, [string]$dstDir, [bool]$move) {
    foreach ($child in @([IO.Directory]::GetFileSystemEntries($srcDir))) {
        $cn = [IO.Path]::GetFileName($child)
        $cIsDir = [IO.Directory]::Exists($child)
        $r = Transfer-One $child $dstDir $cn $cIsDir $move $false
        if ($r -eq 'cancel') { return 'cancel' }
    }
    if ($move -and @([IO.Directory]::GetFileSystemEntries($srcDir)).Count -eq 0) {
        try { [IO.Directory]::Delete($srcDir) } catch { }
    }
    return 'done'
}

function Transfer-One([string]$srcTrim, [string]$destDir, [string]$name, [bool]$isDir, [bool]$move, [bool]$sameDir) {
    $target = Join-Path $destDir $name
    $tIsDir = [IO.Directory]::Exists($target)
    $exists = ($tIsDir -or [IO.File]::Exists($target))
    if (-not $exists) { Do-Xfer $srcTrim $target $isDir $move; return 'done' }
    if ($sameDir -or ($isDir -ne $tIsDir)) {
        $t2 = Get-UniquePath $destDir $name $isDir
        Do-Xfer $srcTrim $t2 $isDir $move
        return 'done'
    }
    $d = Show-ConflictDialog $srcTrim $target $isDir
    $c = $d.Choice
    if ($c -eq 'cancel') { return 'cancel' }
    if ($c -eq 'skip') { $script:xfSkipped++; return 'skip' }
    if ($c -eq 'both') {
        $t2 = Get-UniquePath $destDir $name $isDir
        Do-Xfer $srcTrim $t2 $isDir $move
        return 'done'
    }
    if ($isDir) { return (Merge-Folder $srcTrim $target $move) }
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($target, 'OnlyErrorDialogs', 'SendToRecycleBin')
    Do-Xfer $srcTrim $target $false $move
    $script:xfReplaced++
    return 'done'
}

function Transfer-Items($paths, $dest, $move) {
    Stop-Thumbs
    $script:xfAll = $null; $script:xfReplaced = 0; $script:xfSkipped = 0
    $errors = @(); $done = 0; $cancelled = $false
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
            $sameDir = ($srcDir.TrimEnd('\') -ieq $dest.TrimEnd('\'))
            if ($move -and $sameDir) { continue }
            $r = Transfer-One $srcTrim $dest $name $isDir $move $sameDir
            if ($r -eq 'done') { $done++ }
            elseif ($r -eq 'cancel') { $cancelled = $true; break }
        } catch { $errors += "${name}: $($_.Exception.Message)" }
    }
    Refresh-All
    if ($move) { $verb = 'Moved' } else { $verb = 'Copied' }
    $msg = "$verb $done item(s)"
    if ($script:xfReplaced -gt 0) { $msg += ", replaced $($script:xfReplaced)" }
    if ($script:xfSkipped -gt 0) { $msg += ", skipped $($script:xfSkipped)" }
    if ($cancelled) { $msg = 'Cancelled - ' + $msg + ' before cancelling' }
    $txtStatus.Text = $msg
    if ($errors.Count -gt 0) { [void](Msg ("Some items failed:`n`n" + ($errors -join "`n")) 'OK' 'Warning') }
}

# ---------- Help ----------
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`nCOPYING AND MOVING`nIf the destination already has an item with the same name, a window compares the two (size and date) and asks: Replace, Keep both, Skip or Cancel. For a folder you can Merge. Replace sends the old file to the Recycle Bin first. Tick the box to use your answer for all remaining conflicts. Nothing is overwritten without asking.`n`nBACKUP COPIES`nIf KeepBackups is on, you are asked before a save creates _original copies: Yes keeps them, No saves without them, Cancel stops.`n`nPress F1 any time")
# ===== END SCRIPT20 =====
# ===== SCRIPT20-MARKER =====
# ---------- 1. Warn before a save creates _original backup copies ----------
function Confirm-BackupCopies($targets) {
    if (-not $cfg.KeepBackups) { return 'normal' }
    $new = @($targets | Where-Object { $_ -and -not [IO.File]::Exists($_ + '_original') }).Count
    if ($new -eq 0) { return 'normal' }
    $txt = "Backups are switched on (KeepBackups in config.json).`nThis save will create $new extra backup file(s) ending in _original next to your files.`n`nYes = save and keep the backup copies`nNo = save WITHOUT making backups`nCancel = do not save"
    $r = Msg $txt 'YesNoCancel' 'Warning'
    if ($r -eq 'Yes') { return 'normal' }
    if ($r -eq 'No') { return 'nobackup' }
    return 'cancel'
}

$script:prevInvokeXmpWrite20 = ${function:Invoke-XmpWrite}
function Invoke-XmpWrite($sel, $changes, $label) {
    $mode = 'normal'
    try { $mode = Confirm-BackupCopies @(Get-Targets $sel) } catch { Write-Log ('backup prompt: ' + $_.Exception.Message) }
    if ($mode -eq 'cancel') { $txtStatus.Text = 'Cancelled - nothing was changed.'; return }
    $saved = $cfg.KeepBackups
    if ($mode -eq 'nobackup') { $cfg.KeepBackups = $false }
    try { & $script:prevInvokeXmpWrite20 $sel $changes $label }
    finally { if ($mode -eq 'nobackup') { $cfg.KeepBackups = $saved } }
}

$script:prevSaveMetadata20 = ${function:Save-Metadata}
function Save-Metadata {
    $nb = $false
    try {
        if ($cfg.KeepBackups) {
            $sel = @($list.SelectedItems | Where-Object { -not $_.IsDir } | Where-Object { Get-XmpMode $_ })
            $keys = @(); $bad = $false
            foreach ($f in $fields) {
                if ($f.Ctl.Text -ceq $script:loaded[$f.Key]) { continue }
                $keys += $f.Key
                if ($f.Key -eq 'Rating') { $nv = $f.Ctl.Text.Trim(); if ($nv -ne '' -and $nv -notmatch '^[0-5]$') { $bad = $true } }
            }
            if ($keys.Count -gt 0 -and -not $bad -and $sel.Count -gt 0) {
                $tg = @()
                $xs = @($sel | Where-Object { (Get-XmpMode $_) -ne 'office' })
                if ($xs.Count -gt 0) { $tg += @(Get-Targets $xs) }
                $officeKeys = @($keys | Where-Object { $_ -ne 'Rights' -and $_ -ne 'Rating' })
                if ($officeKeys.Count -gt 0) { $tg += @($sel | Where-Object { (Get-XmpMode $_) -eq 'office' } | ForEach-Object { $_.FullPath }) }
                $mode = Confirm-BackupCopies $tg
                if ($mode -eq 'cancel') { $txtStatus.Text = 'Cancelled - nothing was saved.'; return }
                if ($mode -eq 'nobackup') { $nb = $true }
            }
        }
    } catch { Write-Log ('backup prompt: ' + $_.Exception.Message) }
    $saved = $cfg.KeepBackups
    if ($nb) { $cfg.KeepBackups = $false }
    try { & $script:prevSaveMetadata20 }
    finally { if ($nb) { $cfg.KeepBackups = $saved } }
}

# ---------- 2. Copy / move: never overwrite silently; compare the two files ----------
function Format-FileSize20([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB ({1:N0} bytes)' -f ($b / 1GB), $b) }
    if ($b -ge 1MB) { return ('{0:N1} MB ({1:N0} bytes)' -f ($b / 1MB), $b) }
    if ($b -ge 1KB) { return ('{0:N0} KB ({1:N0} bytes)' -f ($b / 1KB), $b) }
    return ('{0:N0} bytes' -f $b)
}

function Get-ConflictInfo([string]$p, [bool]$isDir) {
    $r = @{}
    if ($isDir) {
        $di = New-Object IO.DirectoryInfo $p
        $r.Len = 0
        $r.Modified = $di.LastWriteTime
        $r.Text1 = ('{0} item(s)' -f @([IO.Directory]::GetFileSystemEntries($p)).Count)
    } else {
        $fi = New-Object IO.FileInfo $p
        $r.Len = $fi.Length
        $r.Modified = $fi.LastWriteTime
        $r.Text1 = Format-FileSize20 $fi.Length
    }
    $r.ModText = $r.Modified.ToString('d MMM yyyy HH:mm:ss')
    $r.Folder = [IO.Path]::GetDirectoryName($p)
    return $r
}

function New-GridCell20($grid, [string]$text, [int]$row, [int]$col, [bool]$bold, [string]$tip) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
    $tb.MaxWidth = 250
    $tb.TextTrimming = 'CharacterEllipsis'
    if ($bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($tip) { $tb.ToolTip = $tip }
    [System.Windows.Controls.Grid]::SetRow($tb, $row)
    [System.Windows.Controls.Grid]::SetColumn($tb, $col)
    [void]$grid.Children.Add($tb)
}

function Show-ConflictDialog([string]$src, [string]$dst, [bool]$isDir) {
    if ($script:xfAll) { return @{ Choice = $script:xfAll; All = $true } }
    $ei = Get-ConflictInfo $dst $isDir
    $si = Get-ConflictInfo $src $isDir
    $name = [IO.Path]::GetFileName($dst)

    $w = New-Object System.Windows.Window
    if ($isDir) { $w.Title = 'Folder already exists' } else { $w.Title = 'File already exists' }
    $w.SizeToContent = 'WidthAndHeight'
    $w.MinWidth = 620
    $w.ResizeMode = 'NoResize'
    $w.Owner = $win
    $w.WindowStartupLocation = 'CenterOwner'

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(18)
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = "'$name' already exists in the destination."
    $h.FontSize = 15
    $h.FontWeight = [System.Windows.FontWeights]::SemiBold
    $h.TextWrapping = 'Wrap'
    $h.MaxWidth = 640
    $h.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    [void]$sp.Children.Add($h)

    $g = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(270)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(270)
    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1); [void]$g.ColumnDefinitions.Add($c2)
    for ($i = 0; $i -lt 4; $i++) {
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = [System.Windows.GridLength]::Auto
        [void]$g.RowDefinitions.Add($rd)
    }
    New-GridCell20 $g '' 0 0 $false ''
    New-GridCell20 $g 'Already there' 0 1 $true ''
    New-GridCell20 $g 'Incoming' 0 2 $true ''
    New-GridCell20 $g 'Folder' 1 0 $true ''
    New-GridCell20 $g $ei.Folder 1 1 $false $ei.Folder
    New-GridCell20 $g $si.Folder 1 2 $false $si.Folder
    if ($isDir) { $lab = 'Contains' } else { $lab = 'Size' }
    New-GridCell20 $g $lab 2 0 $true ''
    New-GridCell20 $g $ei.Text1 2 1 $false ''
    New-GridCell20 $g $si.Text1 2 2 $false ''
    New-GridCell20 $g 'Modified' 3 0 $true ''
    New-GridCell20 $g $ei.ModText 3 1 $false ''
    New-GridCell20 $g $si.ModText 3 2 $false ''
    [void]$sp.Children.Add($g)

    $noteText = ''
    if (-not $isDir) {
        $secs = ($si.Modified - $ei.Modified).TotalSeconds
        $bits = @()
        if ($secs -gt 2) { $bits += 'newer' } elseif ($secs -lt -2) { $bits += 'older' }
        if ($si.Len -gt $ei.Len) { $bits += 'larger' } elseif ($si.Len -lt $ei.Len) { $bits += 'smaller' }
        if ($bits.Count -eq 0) { $noteText = 'Both files have the same size and date - they are probably identical.' }
        else { $noteText = 'The incoming file is ' + ($bits -join ' and ') + ' than the one already there.' }
    }
    if ($noteText) {
        $nt = New-Object System.Windows.Controls.TextBlock
        $nt.Text = $noteText
        $nt.TextWrapping = 'Wrap'; $nt.MaxWidth = 640
        $nt.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
        [void]$sp.Children.Add($nt)
    }
    $tp = New-Object System.Windows.Controls.TextBlock
    if ($isDir) { $tp.Text = 'Merge copies the contents in; you are asked about each file that clashes. Keep both gives the incoming folder a new name.' }
    else { $tp.Text = 'Replace sends the existing file to the Recycle Bin first, so you can get it back. Keep both gives the incoming file a new name.' }
    $tp.TextWrapping = 'Wrap'; $tp.MaxWidth = 640
    $tp.Foreground = [System.Windows.Media.Brushes]::DimGray
    $tp.FontSize = 12
    $tp.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void]$sp.Children.Add($tp)

    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.Content = 'Do this for all remaining conflicts'
    $chk.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [void]$sp.Children.Add($chk)

    $bp = New-Object System.Windows.Controls.StackPanel
    $bp.Orientation = 'Horizontal'
    $bp.HorizontalAlignment = 'Right'
    $bp.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    $mk = {
        param($text)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $text; $b.Width = 100; $b.Height = 30
        $b.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        return $b
    }
    if ($isDir) { $rtxt = 'Merge' } else { $rtxt = 'Replace' }
    $bR = & $mk $rtxt
    $bB = & $mk 'Keep both'; $bB.IsDefault = $true
    $bS = & $mk 'Skip'
    $bC = & $mk 'Cancel'; $bC.IsCancel = $true
    $script:xfWin = $w; $script:xfChk = $chk; $script:xfChoice = 'cancel'
    $bR.Add_Click({ $script:xfChoice = 'replace'; $script:xfWin.Close() })
    $bB.Add_Click({ $script:xfChoice = 'both'; $script:xfWin.Close() })
    $bS.Add_Click({ $script:xfChoice = 'skip'; $script:xfWin.Close() })
    $bC.Add_Click({ $script:xfChoice = 'cancel'; $script:xfWin.Close() })
    foreach ($b in @($bR, $bB, $bS, $bC)) { [void]$bp.Children.Add($b) }
    [void]$sp.Children.Add($bp)
    $w.Content = $sp
    [void]$w.ShowDialog()

    $res = @{ Choice = $script:xfChoice; All = [bool]$script:xfChk.IsChecked }
    if ($res.All -and $res.Choice -ne 'cancel') { $script:xfAll = $res.Choice }
    return $res
}

function Do-Xfer([string]$src, [string]$target, [bool]$isDir, [bool]$move) {
    if ($move) { Move-Item -LiteralPath $src -Destination $target | Out-Null }
    else { Copy-Item -LiteralPath $src -Destination $target -Recurse | Out-Null }
}

function Merge-Folder([string]$srcDir, [string]$dstDir, [bool]$move) {
    foreach ($child in @([IO.Directory]::GetFileSystemEntries($srcDir))) {
        $cn = [IO.Path]::GetFileName($child)
        $cIsDir = [IO.Directory]::Exists($child)
        $r = Transfer-One $child $dstDir $cn $cIsDir $move $false
        if ($r -eq 'cancel') { return 'cancel' }
    }
    if ($move -and @([IO.Directory]::GetFileSystemEntries($srcDir)).Count -eq 0) {
        try { [IO.Directory]::Delete($srcDir) } catch { }
    }
    return 'done'
}

function Transfer-One([string]$srcTrim, [string]$destDir, [string]$name, [bool]$isDir, [bool]$move, [bool]$sameDir) {
    $target = Join-Path $destDir $name
    $tIsDir = [IO.Directory]::Exists($target)
    $exists = ($tIsDir -or [IO.File]::Exists($target))
    if (-not $exists) { Do-Xfer $srcTrim $target $isDir $move; return 'done' }
    if ($sameDir -or ($isDir -ne $tIsDir)) {
        $t2 = Get-UniquePath $destDir $name $isDir
        Do-Xfer $srcTrim $t2 $isDir $move
        return 'done'
    }
    $d = Show-ConflictDialog $srcTrim $target $isDir
    $c = $d.Choice
    if ($c -eq 'cancel') { return 'cancel' }
    if ($c -eq 'skip') { $script:xfSkipped++; return 'skip' }
    if ($c -eq 'both') {
        $t2 = Get-UniquePath $destDir $name $isDir
        Do-Xfer $srcTrim $t2 $isDir $move
        return 'done'
    }
    if ($isDir) { return (Merge-Folder $srcTrim $target $move) }
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($target, 'OnlyErrorDialogs', 'SendToRecycleBin')
    Do-Xfer $srcTrim $target $false $move
    $script:xfReplaced++
    return 'done'
}

function Transfer-Items($paths, $dest, $move) {
    Stop-Thumbs
    $script:xfAll = $null; $script:xfReplaced = 0; $script:xfSkipped = 0
    $errors = @(); $done = 0; $cancelled = $false
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
            $sameDir = ($srcDir.TrimEnd('\') -ieq $dest.TrimEnd('\'))
            if ($move -and $sameDir) { continue }
            $r = Transfer-One $srcTrim $dest $name $isDir $move $sameDir
            if ($r -eq 'done') { $done++ }
            elseif ($r -eq 'cancel') { $cancelled = $true; break }
        } catch { $errors += "${name}: $($_.Exception.Message)" }
    }
    Refresh-All
    if ($move) { $verb = 'Moved' } else { $verb = 'Copied' }
    $msg = "$verb $done item(s)"
    if ($script:xfReplaced -gt 0) { $msg += ", replaced $($script:xfReplaced)" }
    if ($script:xfSkipped -gt 0) { $msg += ", skipped $($script:xfSkipped)" }
    if ($cancelled) { $msg = 'Cancelled - ' + $msg + ' before cancelling' }
    $txtStatus.Text = $msg
    if ($errors.Count -gt 0) { [void](Msg ("Some items failed:`n`n" + ($errors -join "`n")) 'OK' 'Warning') }
}

# ---------- Help ----------
$script:helpText = $script:helpText.Replace("`n`nPress F1 any time", "`n`nCOPYING AND MOVING`nIf the destination already has an item with the same name, a window compares the two (size and date) and asks: Replace, Keep both, Skip or Cancel. For a folder you can Merge. Replace sends the old file to the Recycle Bin first. Tick the box to use your answer for all remaining conflicts. Nothing is overwritten without asking.`n`nBACKUP COPIES`nIf KeepBackups is on, you are asked before a save creates _original copies: Yes keeps them, No saves without them, Cancel stops.`n`nPress F1 any time")
# ===== END SCRIPT20 =====
$win.ShowDialog() | Out-Null











