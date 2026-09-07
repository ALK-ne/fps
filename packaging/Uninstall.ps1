[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'install-manifest.json'
if (!(Test-Path -LiteralPath $manifestPath)) { throw 'Run this script from the installed version directory.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$installDirectory = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ($manifest.schema -ne 1 -or [IO.Path]::GetFullPath($manifest.root).TrimEnd('\') -ne $installDirectory) { throw 'Invalid install manifest' }
if (Get-Process -Name ArenaDuel -ErrorAction SilentlyContinue) { throw 'Close Arena Duel before uninstalling.' }
$allowed = @('ArenaDuel.exe','ArenaDuel.pck','Install.ps1','Uninstall.ps1','PLAY.md','THIRD_PARTY_NOTICES.md','build-info.json','SHA256SUMS')
$targets = @()
foreach ($name in $manifest.files) {
    if ($allowed -notcontains $name) { throw 'Manifest contains an unknown file' }
    $target = [IO.Path]::GetFullPath((Join-Path $installDirectory $name))
    if (!$target.StartsWith($installDirectory + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe uninstall path' }
    $targets += $target
}
foreach ($shortcutPath in $manifest.shortcuts) {
    $approvedPaths = @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Arena Duel Prototype.lnk'),(Join-Path ([Environment]::GetFolderPath('Programs')) 'Arena Duel Prototype.lnk'))
    if ($approvedPaths -notcontains $shortcutPath) { throw 'Unknown shortcut location' }
    if (Test-Path -LiteralPath $shortcutPath) {
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.CreateShortcut($shortcutPath).TargetPath -eq (Join-Path $installDirectory 'ArenaDuel.exe')) { Remove-Item -LiteralPath $shortcutPath }
    }
}
foreach ($target in $targets) { if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target } }
Remove-Item -LiteralPath $manifestPath
if ((Get-ChildItem -LiteralPath $installDirectory -Force | Measure-Object).Count -eq 0) { Remove-Item -LiteralPath $installDirectory }
Write-Output 'Uninstalled. Settings and saved matches were retained.'
