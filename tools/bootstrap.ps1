[CmdletBinding()]
param([switch]$Offline)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$spec = Get-Content (Join-Path $root 'docs/implementation/spec.json') -Raw | ConvertFrom-Json
$cache = Join-Path $PSScriptRoot 'cache'
$editorDir = Join-Path $PSScriptRoot 'godot/4.7.2'
$templateDir = Join-Path $PSScriptRoot 'templates/4.7.2'
New-Item -ItemType Directory -Force $cache,$editorDir,$templateDir | Out-Null
foreach ($asset in @(@{name=$spec.engine.editorAsset;hash=$spec.engine.editorSha256},@{name=$spec.engine.templateAsset;hash=$spec.engine.templateSha256})) {
    $file = Join-Path $cache $asset.name
    if (!(Test-Path -LiteralPath $file)) {
        if ($Offline) { throw "Missing verified cache: $($asset.name)" }
        $url = "https://github.com/godotengine/godot/releases/download/$($spec.engine.version)/$($asset.name)"
        Invoke-WebRequest -Uri $url -OutFile "$file.tmp"
        if ((Get-FileHash "$file.tmp" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.hash) { throw "SHA256 mismatch: $($asset.name)" }
        Move-Item -LiteralPath "$file.tmp" -Destination $file
    }
    if ((Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.hash) { throw "SHA256 mismatch: $($asset.name)" }
}
if (!(Test-Path "$editorDir/Godot_v4.7.2-stable_win64_console.exe")) {
    Expand-Archive -LiteralPath (Join-Path $cache $spec.engine.editorAsset) -DestinationPath $editorDir -Force
}
if (!(Test-Path "$templateDir/windows_release_x86_64.exe")) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $cache $spec.engine.templateAsset))
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.Name -in @('windows_debug_x86_64.exe','windows_release_x86_64.exe')) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $templateDir $entry.Name),$true)
            }
        }
    } finally { $archive.Dispose() }
}
New-Item -ItemType File -Force (Join-Path $editorDir '_sc_') | Out-Null
& (Join-Path $PSScriptRoot 'sync-spec.ps1')
$godot = Join-Path $editorDir 'Godot_v4.7.2-stable_win64_console.exe'
& $godot --version
if ($LASTEXITCODE -ne 0) { throw 'Godot version check failed' }
Write-Output "Verified engine: $godot"
