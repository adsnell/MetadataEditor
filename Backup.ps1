Set-Location $PSScriptRoot
Clear-Host
git add -A
git commit -m ("Backup " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
git push
