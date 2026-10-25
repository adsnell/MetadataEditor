param([switch]$NoClear)
Set-Location $PSScriptRoot
if (-not $NoClear) { Clear-Host }
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'MetadataEditor'
$zip = Join-Path $dist 'MetadataEditor-portable.zip'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
robocopy $root $stage /E /XD "$root\.git" "$root\cache" "$root\logs" "$root\dist" "$root\bin" /XF *.bak* settings.json Backup.ps1 .gitignore /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "Copy failed (robocopy code $LASTEXITCODE)" -ForegroundColor Red; return }
$cfg = Get-Content (Join-Path $stage 'config.json') -Raw | ConvertFrom-Json
$cfg.ExifToolPath = 'exiftool\exiftool.exe'
$cfg | ConvertTo-Json | Set-Content (Join-Path $stage 'config.json') -Encoding UTF8
Set-Content (Join-Path $stage 'READ ME FIRST.txt') -Encoding UTF8 -Value @(
    'MetadataEditor - portable',
    '',
    '1. If this zip came by download/email/OneDrive: right-click the zip > Properties > tick Unblock > OK, BEFORE extracting.',
    '2. Extract the MetadataEditor folder anywhere you can write to (e.g. Documents or C:\Tools). Not Program Files.',
    '3. Double-click MetadataEditor.exe.',
    '4. Optional: right-click Create-Shortcut.ps1 > Run with PowerShell to put a shortcut on the Desktop.',
    '',
    'Needs Windows 10/11 (PowerShell 5.1 and .NET Framework 4.8 are built in).',
    'If something fails, see logs\launch.log and logs\app.log.'
)
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
$mb = '{0:N1}' -f ((Get-Item $zip).Length / 1MB)
Write-Host "Created $zip ($mb MB)" -ForegroundColor Green
