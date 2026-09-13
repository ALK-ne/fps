[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs/ArenaDuel'),[switch]$NoShortcuts)
$ErrorActionPreference = 'Stop'
$info = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-info.json') -Raw | ConvertFrom-Json
if ($info.version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9]+)?$') { throw 'Invalid version' }
$installBase = [IO.Path]::GetFullPath($InstallRoot)
$destination = [IO.Path]::GetFullPath((Join-Path $installBase $info.version))
if (!$destination.StartsWith($installBase.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid install path' }
$running = Get-Process -Name ArenaDuel -ErrorAction SilentlyContinue
if ($running) { throw 'Close Arena Duel before installing. No process was terminated.' }
$files = @('ArenaDuel.exe','ArenaDuel.pck','Install.ps1','Uninstall.ps1','PLAY.md','THIRD_PARTY_NOTICES.md','build-info.json','SHA256SUMS')
$verified = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS')) {
    if ($line -notmatch '^([a-fA-F0-9]{64})  ([A-Za-z0-9_.-]+)$') { throw 'Invalid checksum list' }
    $expected = $Matches[1]
    $name = $Matches[2]
    if ($files -notcontains $name -or $name -eq 'SHA256SUMS') { throw 'Unknown package file' }
    if ($verified.ContainsKey($name)) { throw 'Duplicate checksum entry' }
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash -ne $expected) { throw "Checksum mismatch: $name" }
    $verified[$name] = $true
}
if ($verified.Count -ne ($files.Count - 1)) { throw 'Incomplete checksum list' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destination $name) -Force }
$shortcuts = @()
if (!$NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('Programs'))) {
        $shortcutPath = Join-Path $folder 'Arena Duel Prototype.lnk'
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = Join-Path $destination 'ArenaDuel.exe'
        $shortcut.WorkingDirectory = $destination
        $shortcut.Save()
        $shortcuts += $shortcutPath
    }
}
@{schema=1;root=$destination;files=$files;shortcuts=$shortcuts} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'install-manifest.json') -Encoding UTF8
Write-Output "Installed: $destination"
