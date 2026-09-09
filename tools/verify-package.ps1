[CmdletBinding()]
param([string]$Version='0.2.0')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root "release/ArenaDuel-$Version"
$run=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$qa=Join-Path $root "artifacts/package/$run"
$install=Join-Path $qa 'installed'
New-Item -ItemType Directory -Force $qa | Out-Null
& powershell.exe -NoProfile -File "$source/Install.ps1" -InstallRoot $install -NoShortcuts
if ($LASTEXITCODE -ne 0) { throw 'Install failed' }
$exe=Join-Path $install "$Version/ArenaDuel.exe"
foreach ($case in @('menu','practice','reject-debug')) {
    $arguments=@('--headless','--quit-after','120','--','--profile',('pq_'+$run.Replace('-','')),'--instance-lock-port','27839')
    if ($case -eq 'practice') { $arguments += @('--role','practice') }
    if ($case -eq 'reject-debug') { $arguments += @('--scenario','smoke') }
    $p=Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput "$qa/$case.stdout.log" -RedirectStandardError "$qa/$case.stderr.log"
    $expected=if ($case -eq 'reject-debug') {1} else {0}
    if ($p.ExitCode -ne $expected) { throw "Package $case exit $($p.ExitCode) expected $expected" }
    $errors=Get-Content "$qa/$case.stderr.log" -Raw
    if ($case -ne 'reject-debug' -and $errors) { throw "Package runtime errors: $case" }
    if ($case -eq 'reject-debug' -and $errors -notmatch 'DEBUG_ARGUMENT_REJECTED') { throw 'Missing rejection evidence' }
    $p.Dispose()
}
'must survive' | Set-Content "$install/$Version/user-added.txt"
& powershell.exe -NoProfile -File "$install/$Version/Uninstall.ps1"
if ($LASTEXITCODE -ne 0 -or !(Test-Path "$install/$Version/user-added.txt") -or (Test-Path $exe)) { throw 'Uninstall scope failed' }
& powershell.exe -NoProfile -File "$source/Install.ps1" -InstallRoot $install -NoShortcuts
if ($LASTEXITCODE -ne 0) { throw 'Reinstall failed' }
@{status='PASS';version=$Version;checks=@('PS5.1 install','release menu','release practice','debug hooks rejected','uninstall retains added files','reinstall');logPath=$qa} | ConvertTo-Json | Set-Content "$qa/result.json"
Get-Content "$qa/result.json"
