[CmdletBinding()]
param([ValidateSet('Smoke','FullMatch','Rematch','NetworkFaults','RecoveryRealtime','GuestRecoveryRealtime','ExpiryRealtime','GuestExpiryRealtime','All')][string]$Suite='Smoke',[int]$Seed=20260906)
$ErrorActionPreference = 'Stop'
if ($Suite -eq 'All') {
    foreach ($case in @('Smoke','FullMatch','Rematch','RecoveryRealtime','GuestRecoveryRealtime','ExpiryRealtime','GuestExpiryRealtime','NetworkFaults')) {
        & $PSCommandPath -Suite $case -Seed $Seed
    }
    return
}
$root = Split-Path $PSScriptRoot -Parent
$godot = Join-Path $PSScriptRoot 'godot/4.7.2/Godot_v4.7.2-stable_win64.exe'
$run = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$logs = Join-Path $root "artifacts/integration/$run"
New-Item -ItemType Directory -Force $logs | Out-Null
$owned = [Collections.Generic.List[System.Diagnostics.Process]]::new()
$hostProfile = 'ih_' + $run.Replace('-','')
$guestProfile = 'ig_' + $run.Replace('-','')
$scenario = if ($Suite -in @('FullMatch','All')) { 'full_match' } else { 'smoke' }
if ($Suite -eq 'NetworkFaults') { $scenario = 'full_match' }
if ($Suite -eq 'Rematch') { $scenario = 'rematch' }
function Start-Peer([string]$Role,[string]$Profile,[int]$LockPort,[switch]$Resume) {
    $arguments = @('--headless','--path',"`"$root/game`"",'--','--profile',$Profile,'--role',$Role,'--endpoint','127.0.0.1:27846','--instance-lock-port',"$LockPort",'--scenario',$scenario,'--seed',"$Seed")
    if ($Resume) { $arguments = @('--headless','--path',"`"$root/game`"",'--','--profile',$Profile,'--instance-lock-port',"$LockPort",'--scenario','resume','--seed',"$Seed") }
    $suffix = if ($Resume) { '-resume' } else { '' }
    $p = Start-Process -FilePath $godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logs/$Role$suffix.stdout.log" -RedirectStandardError "$logs/$Role$suffix.stderr.log"
    $owned.Add($p)
    return $p
}
function Read-Report([string]$Profile) {
    $path = Join-Path $root "artifacts/scenario-$Profile.json"
    if (!(Test-Path $path)) { return $null }
    $stream = $null
    $reader = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd() | ConvertFrom-Json
    } catch { return $null }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}
function Wait-State([scriptblock]$Condition,[int]$TimeoutSeconds=30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        foreach ($p in $owned) { $p.Refresh() }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Integration timeout. Evidence: $logs"
}
try {
    $hostProcess = Start-Peer 'host' $hostProfile 27836
    # Editor startup may scan/import assets; this is not the in-game recovery deadline.
    Wait-State { (Read-Report $hostProfile) -ne $null } 120
    if ($Suite -eq 'NetworkFaults') {
        $node = (Get-Command node).Source
        $proxy = Start-Process -FilePath $node -ArgumentList @("`"$PSScriptRoot/udp-proxy.mjs`"",'--port','27847','--target-port','27846','--delay','50','--loss','0.01','--seed',"$Seed",'--report',"`"$logs/proxy.json`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logs/proxy.stdout.log" -RedirectStandardError "$logs/proxy.stderr.log"
        $owned.Add($proxy)
        Wait-State { (Get-Item "$logs/proxy.stdout.log").Length -gt 0 } 10
        $invitePath = Join-Path $root 'artifacts/scenario-invite.txt'
        $raw = (Get-Content $invitePath -Raw).Substring(4).Replace('-','+').Replace('_','/')
        while ($raw.Length % 4) { $raw += '=' }
        $invitation = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw)) | ConvertFrom-Json
        $invitation.port = 27847
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($invitation | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
        [IO.File]::WriteAllText($invitePath, 'AD1:' + $encoded)
    }
    $guestProcess = Start-Peer 'guest' $guestProfile 27837
    Wait-State { (Read-Report $guestProfile) -ne $null } 120
    Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.phase -eq 5 -and $g.phase -eq 5 } 35
    if ($Suite -in @('FullMatch','NetworkFaults')) {
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.terminal -and $g.terminal } 120
    }
    if ($Suite -eq 'Rematch') {
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.finished_match -and $h.match -ne $h.finished_match -and $h.match -eq $g.match -and $h.phase -eq 5 -and $g.phase -eq 5 } 120
    }
    if ($Suite -in @('RecoveryRealtime','GuestRecoveryRealtime')) {
        $restartGuest = $Suite -eq 'GuestRecoveryRealtime'
        if ($restartGuest) { Stop-Process -Id $guestProcess.Id -Force } else { Stop-Process -Id $hostProcess.Id -Force }
        Wait-State { $remaining=Read-Report $(if ($restartGuest) {$hostProfile} else {$guestProfile}); $remaining -and $remaining.phase -eq 7 } 10
        Start-Sleep -Seconds 30
        if ($restartGuest) { $guestProcess = Start-Peer 'guest' $guestProfile 27837 -Resume } else { $hostProcess = Start-Peer 'host' $hostProfile 27836 -Resume }
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.round -eq 2 -and $g.round -eq 2 -and $h.phase -eq 5 -and $g.phase -eq 5 } 25
    }
    if ($Suite -in @('ExpiryRealtime','GuestExpiryRealtime')) {
        $restartGuest = $Suite -eq 'GuestExpiryRealtime'
        $survivorProfile = if ($restartGuest) { $hostProfile } else { $guestProfile }
        if ($restartGuest) { Stop-Process -Id $guestProcess.Id -Force } else { Stop-Process -Id $hostProcess.Id -Force }
        Wait-State { $remaining=Read-Report $survivorProfile; $remaining -and $remaining.phase -eq 7 } 10
        $observed = [Diagnostics.Stopwatch]::StartNew()
        while ($observed.Elapsed.TotalSeconds -lt 65) { Start-Sleep -Milliseconds 250 }
        $survivor = Read-Report $survivorProfile
        if (!$survivor.recovery_expired -or !$survivor.tombstone -or ($survivor.scores -join ',') -ne '0,0') { throw 'Expiry was not durably recorded without speculative score' }
        if ($restartGuest) { $guestProcess = Start-Peer 'guest' $guestProfile 27837 -Resume } else { $hostProcess = Start-Peer 'host' $hostProfile 27836 -Resume }
        Wait-State { $restored=Read-Report $(if ($restartGuest) {$guestProfile} else {$hostProfile}); $restored -and $restored.scenario -eq 'resume' } 120
        Start-Sleep -Seconds 5
        foreach ($profileName in @($hostProfile,$guestProfile)) {
            $peerState = Read-Report $profileName
            if ($peerState.phase -eq 5 -or $peerState.round -ne 1 -or ($peerState.scores -join ',') -ne '0,0') { throw 'Expired match resumed or changed score' }
        }
    }
    $h = Read-Report $hostProfile
    $g = Read-Report $guestProfile
    if ($h.hash -ne $g.hash -or $h.seq -ne $g.seq -or ($h.scores -join ',') -ne ($g.scores -join ',')) { throw 'Peer durable states diverged' }
    if ($Suite -eq 'RecoveryRealtime' -and ($h.scores -join ',') -ne '0,1') { throw 'Wrong restart score' }
    if ($Suite -eq 'GuestRecoveryRealtime' -and ($h.scores -join ',') -ne '1,0') { throw 'Wrong restart score' }
    $errors = Get-ChildItem "$logs/*.stderr.log" | Where-Object { $_.Length -gt 0 }
    if ($errors) { throw "Godot errors: $($errors.Name -join ', ')" }
    @{suite=$Suite;seed=$Seed;status='PASS';host=$h;guest=$g;logPath=$logs} | ConvertTo-Json -Depth 10 | Set-Content "$logs/result.json"
    Get-Content "$logs/result.json"
} catch {
    $failure = $_
    @{suite=$Suite;seed=$Seed;status='FAIL';error=$failure.Exception.Message;host=(Read-Report $hostProfile);guest=(Read-Report $guestProfile);logPath=$logs} | ConvertTo-Json -Depth 10 | Set-Content "$logs/result.json"
    throw
} finally {
    foreach ($p in $owned) {
        $p.Refresh()
        if (!$p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        $p.Dispose()
    }
}
