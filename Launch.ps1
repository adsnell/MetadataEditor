Set-Location $PSScriptRoot
Clear-Host
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'src\App.ps1')
