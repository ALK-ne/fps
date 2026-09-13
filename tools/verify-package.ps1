[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+(?:-[A-Za-z0-9]+)?$')][string]$Version='0.2.1')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$archive=Join-Path $root "release/ArenaDuel-$Version.zip"
$run=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$qa=Join-Path $root "artifacts/package/$run"
$install=Join-Path $qa 'installed'
New-Item -ItemType Directory -Force $qa | Out-Null
$source=Join-Path $qa 'unpacked'
$expectedFiles=@('ArenaDuel.exe','ArenaDuel.pck','Install.ps1','Uninstall.ps1','PLAY.md','THIRD_PARTY_NOTICES.md','build-info.json','SHA256SUMS')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entries=@($zip.Entries | ForEach-Object { $_.FullName })
    if ($entries.Count -ne $expectedFiles.Count -or @($entries | Select-Object -Unique).Count -ne $expectedFiles.Count -or @(Compare-Object $expectedFiles $entries).Count -ne 0) { throw 'Unexpected package archive contents' }
} finally { $zip.Dispose() }
Expand-Archive -LiteralPath $archive -DestinationPath $source
$archiveHash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$sumsPath=Join-Path $source 'SHA256SUMS'
$originalSums=[IO.File]::ReadAllBytes($sumsPath)
$sumLines=@(Get-Content -LiteralPath $sumsPath)
try {
    foreach ($invalidCase in @('missing','duplicate')) {
        $invalidSums=if ($invalidCase -eq 'missing') { @($sumLines | Select-Object -Skip 1) } else { @($sumLines) + $sumLines[0] }
        $invalidSums | Set-Content -LiteralPath $sumsPath -Encoding ascii
        & powershell.exe -NoProfile -File "$source/Install.ps1" -InstallRoot $install -NoShortcuts *> "$qa/checksum-$invalidCase.log"
        if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $install)) { throw "Invalid checksum list was not rejected before install: $invalidCase" }
    }
} finally { [IO.File]::WriteAllBytes($sumsPath,$originalSums) }
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
@{status='PASS';version=$Version;archiveSha256=$archiveHash;checks=@('ZIP contents and extraction','incomplete and duplicate checksum lists rejected','PS5.1 install','release menu','release practice','debug hooks rejected','uninstall retains added files','reinstall');logPath=$qa} | ConvertTo-Json | Set-Content "$qa/result.json"
Get-Content "$qa/result.json"
