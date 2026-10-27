METADATAEDITOR v2.1
A free XMP metadata editor for Windows - free, with an optional donation.

WHAT IT DOES
Browse your folders, see files as thumbnails or in a details list, and read, edit
and write XMP metadata (Title, Subject, Authors, Tags, Comments, Copyright, Rating)
on one file or many at once. Bulk add/remove tags, copy and paste metadata between
files, and search names and metadata (including subfolders). Word, Excel and
PowerPoint files use their native document properties.

GETTING STARTED
1. Right-click the zip > Properties > tick "Unblock" if it is there > OK.
2. Unzip the whole folder somewhere you can write to (e.g. Documents).
   Do not run it from inside the zip.
3. Double-click MetadataEditor.exe.
4. Optional: right-click Create-Shortcut.ps1 > Run with PowerShell for a desktop shortcut.
Press F1 inside the app for full help.

IF WINDOWS WARNS YOU
The app is not digitally signed, so Windows SmartScreen may show "Windows protected
your PC", and some antivirus tools may flag a PowerShell-based program. Click
"More info" and then "Run anyway". The program is plain, readable script (src\App.ps1)
and it does not connect to the internet.

IMPORTANT - BACK UP FIRST
MetadataEditor writes XMP metadata INTO YOUR ORIGINAL FILES. It only changes the
metadata (not the picture or document content), but please keep a backup of anything
important before you start. To keep an automatic copy of each file as it was before
a change, open config.json and set KeepBackups to true (copies end in _original;
delete them when you are happy). Files open in another program (e.g. Word) cannot
be saved - close them first.

QUICK TIPS
Ctrl+S saves. 1-5 set a rating, 0 clears it. Drag files onto a folder in the left
pane to move them (hold Ctrl to copy). Right-click for more (Properties, Copy/Paste
metadata). F2 renames, Delete sends to the Recycle Bin.

FREE, WITH AN OPTIONAL DONATION
MetadataEditor is free to use and share. If it saves you time and you would like to
say thanks, an optional £1 is very welcome: https://paypal.me/AndrewSnell791
It is a hobby project, so there is no paid support - but feedback is welcome:
https://github.com/adsnell/MetadataEditor (use Issues).

CREDITS
Powered by ExifTool by Phil Harvey - https://exiftool.org
ExifTool is free software and is redistributed here under its own licence
(see Licences\ExifTool-notice.txt).