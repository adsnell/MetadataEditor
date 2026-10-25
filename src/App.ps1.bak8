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
    public string FolderText { get; set; }
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
        [void][System.Windows.MessageBox]::Show($win, 'No changes detected. Edit a field first.', 'MetadataEditor')
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
    $msg = "Saved XMP to $n file(s) in $($sw.ElapsedMilliseconds) ms"
    if ($created -gt 0) { $msg += " ($created new sidecar file(s))" }
    $skipped = $all.Count - $sel.Count
    if ($skipped -gt 0) { $msg += "  |  $skipped unsupported file(s) skipped" }
    if ($err) { $msg += '  |  ' + (($err -split "`n")[0]); Write-Log $err }
    $txtStatus.Text = $msg; $script:metaReady = $false
    Write-Log ("SAVE cmd: " + ($cmd -join " | "))
    Write-Log ("SAVE out: " + $out)
    [void][System.Windows.MessageBox]::Show($win, ($msg + "`n`n" + $out + $err), 'MetadataEditor')
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
            int hr = f.GetImage(s, 8, out h);
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
        $i.SizeText = Format-Size $f.Length
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

$win.ShowDialog() | Out-Null







