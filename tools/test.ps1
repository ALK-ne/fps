[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$godot = Join-Path $PSScriptRoot 'godot/4.7.2/Godot_v4.7.2-stable_win64_console.exe'
if (!(Test-Path $godot)) { throw 'Run tools/bootstrap.ps1 first.' }
$run = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$logs = Join-Path $root "artifacts/tests/$run"
New-Item -ItemType Directory -Force $logs | Out-Null
& (Join-Path $PSScriptRoot 'sync-spec.ps1')
& $godot --headless --path "$root/game" --editor --import --log-file "$logs/import.log" 2>&1 | Tee-Object "$logs/import.stdout.log"
if ($LASTEXITCODE -ne 0 -or (Select-String -Path "$logs/import.stdout.log" -Pattern 'SCRIPT ERROR|Parse Error|Compile Error' -Quiet)) { throw "Godot import failed: $logs" }
& $godot --headless --path "$root/game" --script res://tests/run.gd --log-file "$logs/unit.log" 2>&1 | Tee-Object "$logs/unit.stdout.log"
if ($LASTEXITCODE -ne 0 -or (Select-String -Path "$logs/unit.stdout.log" -Pattern 'SCRIPT ERROR|Parse Error|Compile Error' -Quiet)) { throw "Godot tests failed: $logs" }
Push-Location $root
try {
    & node tools/validate-design.mjs | Out-File "$logs/design.json" -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Design validation failed' }
    & npm test 2>&1 | Tee-Object "$logs/spike.log"
    if ($LASTEXITCODE -ne 0) { throw 'Spike tests failed' }
} finally { Pop-Location }
@{run=$run;engine='4.7.2-stable';seed=20260906;status='PASS';scope='import, registered Godot unit tests, design validator, Node spike'} | ConvertTo-Json | Set-Content "$logs/result.json"
Write-Output "Test evidence: $logs"
