[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$godot = Join-Path $PSScriptRoot 'godot/4.7.2/Godot_v4.7.2-stable_win64_console.exe'
$run = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$logs = Join-Path $root "artifacts/debug-export/$run"
New-Item -ItemType Directory -Force $logs | Out-Null
$exe = Join-Path $logs 'ArenaDuel-debug.exe'
& $godot --headless --path "$root/game" --export-debug 'Windows Desktop' $exe 2>&1 | Tee-Object "$logs/export.log"
if ($LASTEXITCODE -ne 0 -or (Select-String "$logs/export.log" -Pattern 'SCRIPT ERROR|Parse Error|Export failed' -Quiet)) { throw 'Debug export failed' }
$profile = 'dq_' + $run.Replace('-','')
$p = Start-Process -FilePath $exe -ArgumentList @('--headless','--quit-after','120','--','--profile',$profile,'--instance-lock-port','27839') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput "$logs/start.stdout.log" -RedirectStandardError "$logs/start.stderr.log"
if ($p.ExitCode -ne 0 -or (Get-Item "$logs/start.stderr.log").Length -gt 0) { throw 'Debug export startup failed' }
$p.Dispose()
@{status='PASS';engine='4.7.2-stable';checks=@('Windows debug export','empty profile startup');logPath=$logs} | ConvertTo-Json | Set-Content "$logs/result.json"
Get-Content "$logs/result.json"
