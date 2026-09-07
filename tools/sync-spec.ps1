$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& node (Join-Path $PSScriptRoot 'sync-spec.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Spec generation failed' }
$debug = (Join-Path $PSScriptRoot 'templates/4.7.2/windows_debug_x86_64.exe').Replace('\','/')
$release = (Join-Path $PSScriptRoot 'templates/4.7.2/windows_release_x86_64.exe').Replace('\','/')
$preset = Get-Content (Join-Path $root 'game/export_presets.cfg.in') -Raw
$preset.Replace('@DEBUG@',$debug).Replace('@RELEASE@',$release) | Set-Content (Join-Path $root 'game/export_presets.cfg') -Encoding utf8
