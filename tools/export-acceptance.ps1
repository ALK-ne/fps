[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$godot = Join-Path $PSScriptRoot 'godot/4.7.2/Godot_v4.7.2-stable_win64_console.exe'
$output = Join-Path $root 'artifacts/acceptance-build'
New-Item -ItemType Directory -Force $output | Out-Null
& $godot --headless --path "$root/game" --editor --import 2>&1 | Tee-Object "$output/import.log"
if ($LASTEXITCODE -ne 0 -or (Select-String "$output/import.log" -Pattern 'SCRIPT ERROR|Parse Error' -Quiet)) { throw 'Acceptance import failed' }
& $godot --headless --path "$root/game" --export-debug 'Windows Acceptance' "$output/ArenaDuel.exe" 2>&1 | Tee-Object "$output/export.log"
if ($LASTEXITCODE -ne 0 -or (Select-String "$output/export.log" -Pattern 'SCRIPT ERROR|Parse Error|Export failed' -Quiet)) { throw 'Acceptance export failed' }
Get-FileHash -LiteralPath "$output/ArenaDuel.exe","$output/ArenaDuel.pck" -Algorithm SHA256
