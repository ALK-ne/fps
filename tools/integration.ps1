[CmdletBinding()]
param([ValidateSet('Smoke','FullMatch','Rematch','NetworkFaults','RecoveryRealtime','GuestRecoveryRealtime','ExpiryRealtime','GuestExpiryRealtime','BothRestart','NoPeerResume','Inventory','SaveFaults','Checkpoint','Entities','All')][string]$Suite='Smoke',[int]$Seed=20260906,[string]$Case='All',[ValidateSet('Host','Guest','Both')][string]$Role='Both',[string]$Executable='')
$ErrorActionPreference = 'Stop'
if ($Suite -eq 'All') {
    foreach ($case in @('Smoke','FullMatch','Rematch','RecoveryRealtime','GuestRecoveryRealtime','ExpiryRealtime','GuestExpiryRealtime','BothRestart','NoPeerResume','Inventory','SaveFaults','NetworkFaults')) {
        & $PSCommandPath -Suite $case -Seed $Seed -Executable $Executable
    }
    return
}
if ($Suite -eq 'SaveFaults' -and ($Case -eq 'All' -or $Role -eq 'Both')) {
    $boundaries = if ($Case -eq 'All') { @('before_write','partial_write','after_flush','after_rename') } else { @($Case) }
    $faultRoles = if ($Role -eq 'Both') { @('Host','Guest') } else { @($Role) }
    foreach ($boundary in $boundaries) {
        foreach ($faultRole in $faultRoles) { & $PSCommandPath -Suite SaveFaults -Case $boundary -Role $faultRole -Seed $Seed -Executable $Executable }
    }
    return
}
$root = Split-Path $PSScriptRoot -Parent
$godot = if ($Executable) { (Resolve-Path -LiteralPath $Executable).Path } else { Join-Path $PSScriptRoot 'godot/4.7.2/Godot_v4.7.2-stable_win64.exe' }
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
    $arguments += @('--test-invite-file', "`"$logs/invite.txt`"")
    if ($Executable) {
        # Export templates load their adjacent PCK and reject path override flags.
        $arguments = @('--headless') + $arguments[3..($arguments.Count-1)]
    }
    $suffix = if ($Resume) { '-resume' } else { '' }
    $p = Start-Process -FilePath $godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logs/$Role$suffix.stdout.log" -RedirectStandardError "$logs/$Role$suffix.stderr.log"
    $owned.Add($p)
    return $p
}
$reportCache = @{}
function Read-Report([string]$Profile) {
    $port = if ($Profile -eq $hostProfile) { 28836 } else { 28837 }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.ConnectAsync('127.0.0.1', $port)
        if (!$pending.Wait(150)) { throw 'Control endpoint is not ready' }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 500
        $stream.WriteTimeout = 500
        $bytes = [Text.Encoding]::UTF8.GetBytes("{`"command`":`"observe`"}`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($stream)
        $report = $reader.ReadLine() | ConvertFrom-Json
        if ($report.profile -eq $Profile) { $reportCache[$Profile] = $report }
        $reader.Dispose()
    } catch { }
    finally { $client.Dispose() }
    return $reportCache[$Profile]
}
function Send-Control([string]$PeerRole,[hashtable]$Command) {
    $port = if ($PeerRole -eq 'Host') { 28836 } else { 28837 }
    $logFile = Join-Path $logs ($PeerRole.ToLowerInvariant() + '.stdout.log')
    $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $reader = [IO.StreamReader]::new([IO.File]::Open($logFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing))
    try { $lines = $reader.ReadToEnd() -split "`n" } finally { $reader.Dispose() }
    $ready = $lines | Where-Object { $_ -match '"control_ready":true' } | Select-Object -Last 1 | ConvertFrom-Json
    if (!$ready.token) { throw 'Control ready token missing' }
    $Command.token = $ready.token
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1500
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Command | ConvertTo-Json -Depth 12 -Compress) + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $responseReader = [IO.StreamReader]::new($stream)
        try { $response = $responseReader.ReadLine() | ConvertFrom-Json } finally { $responseReader.Dispose() }
        if ($response.error) { throw "Control command rejected: $($response.error)" }
        return $response
    } finally { $client.Dispose() }
}
function Read-SharedText([string]$Path) {
    $reader = [IO.StreamReader]::new([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)))
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
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
    Wait-State { if ($hostProcess.HasExited) { throw "Host startup exited: $logs" }; (Read-Report $hostProfile) -ne $null } 120
    if ($Suite -eq 'NetworkFaults') {
        $node = (Get-Command node).Source
        $proxy = Start-Process -FilePath $node -ArgumentList @("`"$PSScriptRoot/udp-proxy.mjs`"",'--port','27847','--target-port','27846','--delay','50','--loss','0.01','--seed',"$Seed",'--report',"`"$logs/proxy.json`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logs/proxy.stdout.log" -RedirectStandardError "$logs/proxy.stderr.log"
        $owned.Add($proxy)
        Wait-State { (Get-Item "$logs/proxy.stdout.log").Length -gt 0 } 10
        $invitePath = Join-Path $logs 'invite.txt'
        $raw = (Get-Content $invitePath -Raw).Substring(4).Replace('-','+').Replace('_','/')
        while ($raw.Length % 4) { $raw += '=' }
        $invitation = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw)) | ConvertFrom-Json
        $invitation.port = 27847
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($invitation | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
        [IO.File]::WriteAllText($invitePath, 'AD2:' + $encoded)
    }
    $guestProcess = Start-Peer 'guest' $guestProfile 27837
    Wait-State { if ($guestProcess.HasExited) { throw "Guest startup exited: $logs" }; (Read-Report $guestProfile) -ne $null } 120
    Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.phase -eq 5 -and $g.phase -eq 5 } 35
    if ($Suite -eq 'Entities') {
        if ($Case -notin @('All','A17-frag','A19-incendiary')) { throw 'Unknown entity case' }
        $entityCases = if ($Case -eq 'All') { @('frag','incendiary') } elseif ($Case -eq 'A17-frag') { @('frag') } else { @('incendiary') }
        $actors = if ($Role -eq 'Both') { @('Host','Guest') } else { @($Role) }
        foreach ($entityCase in $entityCases) {
            foreach ($actor in $actors) {
                $slot = if ($actor -eq 'Host') { 0 } else { 1 }
                $kindIndex = if ($entityCase -eq 'frag') { 0 } else { 1 }
                Send-Control 'Host' @{command='fixture';case=$entityCase;slot=$slot} | Out-Null
                Wait-State { $g=Read-Report $guestProfile; $g -and $g.inventories[$slot].grenades[$kindIndex] -eq 1 } 2
                $before=Read-Report $guestProfile
                $bornBefore=[int]$before.event_types.'6'
                $removedBefore=[int]$before.event_types.'9'
                Send-Control $actor @{command='arm';tick=0;actions=@(@{action='grenade';pressed=$true},@{action='grenade';pressed=$false})} | Out-Null
                Wait-State { $h=Read-Report $hostProfile; $h.actions[$slot] -eq 4 } 2
                Send-Control $actor @{command='arm';tick=0;actions=@(@{action='fire';pressed=$true})} | Out-Null
                Wait-State { $h=Read-Report $hostProfile; $h.actions[$slot] -eq 5 } 2
                Send-Control $actor @{command='arm';tick=0;actions=@(@{action='fire';pressed=$false})} | Out-Null
                Wait-State { $g=Read-Report $guestProfile; [int]$g.event_types.'6' -eq $bornBefore+1 } 2
                $removals = if ($entityCase -eq 'frag') { 1 } else { 2 }
                Wait-State { $g=Read-Report $guestProfile; [int]$g.event_types.'9' -ge $removedBefore+$removals -and $g.entity_ids.grenades.Count -eq 0 -and $g.entity_ids.flames.Count -eq 0 } 9
                Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h.event_sequence -eq $g.event_sequence -and $h.entity_ids.grenades.Count -eq 0 -and $h.entity_ids.flames.Count -eq 0 } 2
                $h=Read-Report $hostProfile
                $g=Read-Report $guestProfile
                if ($h.inventories[$slot].grenades[$kindIndex] -ne 0 -or $g.inventories[$slot].grenades[$kindIndex] -ne 0 -or $h.event_sequence -ne $g.event_sequence) { throw 'Grenade consumption or event sequence diverged' }
                if ([int]$g.received_types.'12' -lt 1) { throw 'No live entity correction was received' }
            }
        }
    }
    if ($Suite -eq 'Checkpoint') {
        Send-Control 'Host' @{command='fixture';case='checkpoint'} | Out-Null
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.checkpoint_seq -eq 385 -and $g.checkpoint_seq -eq 385 -and $h.round -eq 129 -and $g.round -eq 129 -and $h.phase -eq 5 -and $g.phase -eq 5 } 120
        if (((Read-Report $hostProfile).scores -join ',') -ne '0,0') { throw 'Checkpoint fixture changed draw scores' }
    }
    if ($Suite -eq 'Inventory') {
        if ($Case -notin @('All','A14-empty')) { throw 'This inventory case has not been implemented' }
        $roles = if ($Role -eq 'Both') { @('Host','Guest') } else { @($Role) }
        foreach ($actor in $roles) {
            $slot = if ($actor -eq 'Host') { 0 } else { 1 }
            $fixture = Send-Control 'Host' @{command='fixture';case='pickup_empty';slot=$slot}
            Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and ($h.items.id -contains $fixture.id) -and ($g.items.id -contains $fixture.id) } 2
            $actorState = Read-Report $(if ($slot -eq 0) {$hostProfile} else {$guestProfile})
            Send-Control $actor @{command='arm';tick=($actorState.tick+6);actions=@(@{action='interact';pressed=$true})} | Out-Null
            Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.inventories[$slot].weapons[0].id -eq $fixture.id -and $g.inventories[$slot].weapons[0].id -eq $fixture.id } 3
            if ($slot -eq 1) {
                Wait-State { $g=Read-Report $guestProfile; $g.action_result.resultCode -eq 0 } 2
                $before = Read-Report $hostProfile
                for ($copy=0; $copy -lt 3; $copy++) { Send-Control 'Guest' @{command='resend_action'} | Out-Null }
                Start-Sleep -Milliseconds 700
                $after = Read-Report $hostProfile
                if ($after.inventories[1].revision -ne $before.inventories[1].revision -or $after.action_results_count -ne $before.action_results_count) { throw 'Duplicate request caused repeated inventory mutation' }
            }
            Send-Control $actor @{command='arm';tick=0;actions=@(@{action='interact';pressed=$false})} | Out-Null
        }
    }
    if ($Suite -eq 'SaveFaults') {
        if ($Case -notin @('before_write','partial_write','after_flush','after_rename')) { throw 'Select an explicit persistence boundary for SaveFaults' }
        if ($Role -eq 'Both') { throw 'Select Host or Guest for this fault run' }
        Send-Control $Role @{command='fault';point=$Case;recordType=4;occurrence=1} | Out-Null
        Send-Control 'Host' @{command='fixture';case='close_round'} | Out-Null
        $faultLog = Join-Path $logs ($Role.ToLowerInvariant() + '.stdout.log')
        Wait-State { (Read-SharedText $faultLog).Contains('"fault_point":"'+$Case+'"') } 5
        if ($Role -eq 'Host') {
            Stop-Process -Id $hostProcess.Id -Force
            $hostProcess = Start-Peer 'host' $hostProfile 27836 -Resume
        } else {
            Stop-Process -Id $guestProcess.Id -Force
            $guestProcess = Start-Peer 'guest' $guestProfile 27837 -Resume
        }
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.round -eq 2 -and $g.round -eq 2 -and $h.phase -eq 5 -and $g.phase -eq 5 } 25
        $expected = if ($Role -eq 'Host' -and $Case -ne 'after_rename') { '0,1' } else { '1,0' }
        if (((Read-Report $hostProfile).scores -join ',') -ne $expected) { throw "Wrong score at persistence boundary $Case" }
    }
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
    if ($Suite -in @('BothRestart','NoPeerResume')) {
        Stop-Process -Id $guestProcess.Id -Force
        Stop-Process -Id $hostProcess.Id -Force
        $hostProcess = Start-Peer 'host' $hostProfile 27836 -Resume
        if ($Suite -eq 'BothRestart') {
            $guestProcess = Start-Peer 'guest' $guestProfile 27837 -Resume
            Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.terminal -and $g.terminal } 30
            $h=Read-Report $hostProfile
            $g=Read-Report $guestProfile
            if ($h.winner -ne -1 -or $g.winner -ne -1 -or ($h.scores -join ',') -ne '0,0') { throw 'Unknown responsibility produced an invented winner' }
        } else {
            Wait-State { $h=Read-Report $hostProfile; $h -and $h.scenario -eq 'resume' -and !$h.started } 45
            $h=Read-Report $hostProfile
            if ($h.recovery_expired -or $h.terminal -or $h.tombstone -or $h.phase -eq 5) { throw 'Unreachable peer was treated as expiry or successful recovery' }
        }
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
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.tombstone -and $g.tombstone -and $h.notice_id -and $h.notice_id -eq $g.notice_id } 15
        foreach ($profileName in @($hostProfile,$guestProfile)) {
            $peerState = Read-Report $profileName
            if ($peerState.phase -eq 5 -or $peerState.round -ne 1 -or ($peerState.scores -join ',') -ne '0,0' -or !$peerState.diagnostic -or $peerState.result_status -ne 2 -or !$peerState.recovery_expired) { throw 'Expired match resumed, changed score, or lost terminal evidence' }
        }
    }
    $h = Read-Report $hostProfile
    $g = Read-Report $guestProfile
    if ($h.hash -ne $g.hash -or $h.seq -ne $g.seq -or ($h.scores -join ',') -ne ($g.scores -join ',')) { throw 'Peer durable states diverged' }
    if ($Suite -in @('FullMatch','NetworkFaults')) {
        if (!$h.terminal -or !$g.terminal -or ($h.scores -join ',') -ne '10,0' -or $h.winner -ne 0 -or $g.winner -ne 0) { throw 'Full match did not reach the expected ten-win result' }
        if (($h.hp -join ',') -ne ($g.hp -join ',') -or $h.gun.magazine -ne $g.gun.magazine) { throw 'Final replicated combat state diverged' }
    }
    if ($Suite -eq 'RecoveryRealtime' -and ($h.scores -join ',') -ne '0,1') { throw 'Wrong restart score' }
    if ($Suite -eq 'GuestRecoveryRealtime' -and ($h.scores -join ',') -ne '1,0') { throw 'Wrong restart score' }
    $errors = Get-ChildItem "$logs/*.stderr.log" | Where-Object { $_.Length -gt 0 }
    if ($errors) { throw "Godot errors: $($errors.Name -join ', ')" }
    @{suite=$Suite;case=$Case;role=$Role;seed=$Seed;status='PASS';host=$h;guest=$g;logPath=$logs} | ConvertTo-Json -Depth 10 | Set-Content "$logs/result.json"
    @{suite=$Suite;case=$Case;role=$Role;status='PASS';logPath=$logs} | ConvertTo-Json -Compress
} catch {
    $failure = $_
    @{suite=$Suite;case=$Case;role=$Role;seed=$Seed;status='FAIL';error=$failure.Exception.Message;host=(Read-Report $hostProfile);guest=(Read-Report $guestProfile);logPath=$logs} | ConvertTo-Json -Depth 10 | Set-Content "$logs/result.json"
    throw
} finally {
    foreach ($p in $owned) {
        $p.Refresh()
        if (!$p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        $p.Dispose()
    }
}
