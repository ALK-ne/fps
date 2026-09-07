[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+(?:-[A-Za-z0-9]+)?$')][string]$Version='0.1.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$godot = Join-Path $PSScriptRoot 'godot/4.7.2/Godot_v4.7.2-stable_win64_console.exe'
& (Join-Path $PSScriptRoot 'sync-spec.ps1')
$output = Join-Path $root "release/ArenaDuel-$Version"
New-Item -ItemType Directory -Force $output | Out-Null
& $godot --headless --path "$root/game" --editor --import 2>&1 | Tee-Object "$output/import.log"
if ($LASTEXITCODE -ne 0 -or (Select-String "$output/import.log" -Pattern 'SCRIPT ERROR|Parse Error' -Quiet)) { throw 'Import failed' }
& $godot --headless --path "$root/game" --export-release 'Windows Desktop' "$output/ArenaDuel.exe" 2>&1 | Tee-Object "$output/export.log"
if ($LASTEXITCODE -ne 0 -or (Select-String "$output/export.log" -Pattern 'SCRIPT ERROR|Parse Error|Export failed' -Quiet)) { throw 'Export failed' }
foreach ($name in @('Install.ps1','Uninstall.ps1','PLAY.md','THIRD_PARTY_NOTICES.md')) { Copy-Item -LiteralPath (Join-Path $root "packaging/$name") -Destination $output -Force }
$manifest = Get-Content "$root/game/data/manifest.json" -Raw | ConvertFrom-Json
$commit = & git -C $root rev-parse HEAD
@{version=$Version;engine='4.7.2-stable';specVersion='1.0.0';rulesHash=$manifest.files.'game_config.json';mapHash=$manifest.files.'arena.json';commit=$commit;builtUtc=[DateTime]::UtcNow.ToString('o');release=$true;implementation_complete=$false} | ConvertTo-Json | Set-Content "$output/build-info.json"
$files = @('ArenaDuel.exe','ArenaDuel.pck','Install.ps1','Uninstall.ps1','PLAY.md','THIRD_PARTY_NOTICES.md','build-info.json')
$sums = foreach ($name in $files) { '{0}  {1}' -f (Get-FileHash (Join-Path $output $name) -Algorithm SHA256).Hash.ToLowerInvariant(),$name }
$sums | Set-Content "$output/SHA256SUMS" -Encoding ascii
$zip = Join-Path $root "release/ArenaDuel-$Version.zip"
$paths = @($files + 'SHA256SUMS' | ForEach-Object { Join-Path $output $_ })
Compress-Archive -LiteralPath $paths -DestinationPath $zip -Force
Get-FileHash -LiteralPath $zip -Algorithm SHA256 | Format-List
