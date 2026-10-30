$root = $PSScriptRoot
$exe = Join-Path $root 'MetadataEditor.exe'
$ico = Join-Path $root 'MetadataEditor_v3.ico'
$desktop = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $desktop 'MetadataEditor v3.lnk'))
$lnk.TargetPath = $exe
$lnk.WorkingDirectory = $root
$lnk.Description = 'XMP metadata editor'
if (Test-Path $ico) { $lnk.IconLocation = $ico } else { $lnk.IconLocation = $exe }
$lnk.Save()
Write-Host "Desktop shortcut created: $(Join-Path $desktop 'MetadataEditor v3.lnk')" -ForegroundColor Green

