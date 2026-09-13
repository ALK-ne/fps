[CmdletBinding()]
param([ValidateSet('Smoke','FullMatch','Rematch','NetworkFaults','RecoveryRealtime','GuestRecoveryRealtime','ExpiryRealtime','GuestExpiryRealtime','BothRestart','NoPeerResume','Inventory','SaveFaults','Checkpoint','Entities','GracefulExpiry','All')][string]$Suite='Smoke',[int]$Seed=20260906,[string]$Case='All',[ValidateSet('Host','Guest','Both')][string]$Role='Both',[string]$Executable='')
$ErrorActionPreference = 'Stop'
if ($Suite -eq 'Entities' -and $Case -eq 'All') {
    foreach ($entityCase in @('A17-frag','A19-incendiary','A21-gap')) { & $PSCommandPath -Suite Entities -Case $entityCase -Role $Role -Seed $Seed -Executable $Executable }
    return
}
if ($Suite -eq 'GracefulExpiry' -and $Role -eq 'Both') {
    foreach ($leavingRole in @('Host','Guest')) { & $PSCommandPath -Suite GracefulExpiry -Role $leavingRole -Seed $Seed -Executable $Executable }
    return
}
if ($Suite -eq 'Checkpoint' -and $Case -eq 'All') {
    foreach ($checkpointCase in @('A27-rounds','A27-keeps')) { & $PSCommandPath -Suite Checkpoint -Case $checkpointCase -Seed $Seed -Executable $Executable }
    return
}
if ($Suite -eq 'All') {
    foreach ($case in @('Smoke','FullMatch','Rematch','RecoveryRealtime','GuestRecoveryRealtime','ExpiryRealtime','GuestExpiryRealtime','BothRestart','NoPeerResume','Inventory','SaveFaults','NetworkFaults','Checkpoint','Entities','GracefulExpiry')) {
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
    if ($Suite -eq 'GracefulExpiry') {
        $actorProfile = if ($Role -eq 'Host') { $hostProfile } else { $guestProfile }
        $survivorProfile = if ($Role -eq 'Host') { $guestProfile } else { $hostProfile }
        $actorProcess = if ($Role -eq 'Host') { $hostProcess } else { $guestProcess }
        $expectedWinner = if ($Role -eq 'Host') { 1 } else { 0 }
        $leave = Send-Control $Role @{command='leave'}
        if (!$leave.closed) { throw 'Graceful leave control failed' }
        Wait-State { $peer=Read-Report $survivorProfile; [int]$peer.received_types.'41' -gt 0 -and $peer.phase -eq 7 } 5
        Stop-Process -Id $actorProcess.Id -Force
        Wait-State { $peer=Read-Report $survivorProfile; $peer.recovery_expired -and $peer.result_status -eq 1 -and $peer.result_winner -eq $expectedWinner } 70
        $lockPort = if ($Role -eq 'Host') { 27836 } else { 27837 }
        $restarted = Start-Peer ($Role.ToLowerInvariant()) $actorProfile $lockPort -Resume
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h.result_status -eq 1 -and $g.result_status -eq 1 -and $h.notice_id -eq $g.notice_id -and $h.notice_id -ne '' } 25
        $h=Read-Report $hostProfile
        $g=Read-Report $guestProfile
        if (!$h.terminal -or $h.winner -ne $expectedWinner -or $h.seq -ne ($g.seq+1) -or $h.notice_seq -ne $g.seq -or $h.notice_hash -ne $g.hash -or ($h.scores -join ',') -ne '0,0' -or ($g.scores -join ',') -ne '0,0') { throw 'Forfeit record/certificate prefix or score mismatch' }
    }
    if ($Suite -eq 'Entities') {
        if ($Case -notin @('All','A17-frag','A19-incendiary','A21-gap')) { throw 'Unknown entity case' }
        $entityCases = if ($Case -eq 'All') { @('frag','incendiary') } elseif ($Case -in @('A17-frag','A21-gap')) { @('frag') } else { @('incendiary') }
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
                if ($Case -eq 'A21-gap') {
                    $drop = Send-Control 'Host' @{command='drop_type';type=22}
                    if (!$drop.armed) { throw 'Event-loss hook unavailable' }
                }
                Send-Control $actor @{command='arm';tick=0;actions=@(@{action='fire';pressed=$false})} | Out-Null
                if ($Case -eq 'A21-gap') {
                    Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; [int]$g.sent_types.'26' -gt [int]$before.sent_types.'26' -and [int]$h.dropped_types.'22' -gt 0 -and $g.inventories[$slot].grenades[0] -eq 0 } 5
                } else {
                    Wait-State { $g=Read-Report $guestProfile; [int]$g.event_types.'6' -eq $bornBefore+1 } 2
                }
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
        if ($Case -notin @('A27-rounds','A27-keeps')) { throw 'Unknown checkpoint case' }
        $fixtureName = if ($Case -eq 'A27-keeps') { 'checkpoint_keep' } else { 'checkpoint' }
        $checkpointSeq = if ($Case -eq 'A27-keeps') { 1024 } else { 385 }
        $nextRound = if ($Case -eq 'A27-keeps') { 2 } else { 129 }
        Send-Control 'Host' @{command='fixture';case=$fixtureName} | Out-Null
        Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.checkpoint_seq -eq $checkpointSeq -and $g.checkpoint_seq -eq $checkpointSeq -and $h.round -eq $nextRound -and $g.round -eq $nextRound -and $h.phase -eq 5 -and $g.phase -eq 5 } 300
        if (((Read-Report $hostProfile).scores -join ',') -ne '0,0') { throw 'Checkpoint fixture changed draw scores' }
    }
    if ($Suite -eq 'Inventory') {
        if ($Case -notin @('All','A14-empty','A14-hold','A15-cap')) { throw 'This inventory case has not been implemented' }
        $roles = if ($Role -eq 'Both') { @('Host','Guest') } else { @($Role) }
        if ($Case -in @('All','A14-empty')) {
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
        if ($Case -in @('All','A14-hold')) {
            foreach ($actor in $roles) {
                $slot = if ($actor -eq 'Host') { 0 } else { 1 }
                $fixture = Send-Control 'Host' @{command='fixture';case='pickup_hold';slot=$slot}
                if (!$fixture.configured) { throw 'Hold fixture failed' }
                Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and ($h.items.id -contains $fixture.id) -and ($g.items.id -contains $fixture.id) -and $g.inventories[$slot].weapons[0].id -eq ($fixture.id+1000) } 3
                $before = Read-Report $hostProfile
                Send-Control $actor @{command='arm';tick=0;actions=@(@{action='interact';pressed=$true})} | Out-Null
                Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.inventories[$slot].weapons[0].id -eq $fixture.id -and $g.inventories[$slot].weapons[0].id -eq $fixture.id } 4
                Start-Sleep -Milliseconds 300
                $trace = Send-Control 'Host' @{command='trace'}
                $trace | ConvertTo-Json -Depth 8 | Set-Content "$logs/hold-$actor-trace.json"
                $start = @($trace.samples | Where-Object action -eq 6 | Select-Object -First 1)
                if ($start.Count -ne 1) { throw 'Missing swap start tick' }
                $endTick = $start[0].end_tick
                if ($endTick -ne ($start[0].tick+60)) { throw 'Swap duration was not 60 simulation ticks' }
                foreach ($offset in @(-1,0,1)) {
                    $sample = @($trace.samples | Where-Object tick -eq ($endTick+$offset))
                    if ($sample.Count -ne 1) { throw "Missing exact swap boundary $offset" }
                    $expected = if ($offset -lt 0) { $fixture.id+1000 } else { $fixture.id }
                    if ($sample[0].weapon -ne $expected) { throw "Incorrect weapon at swap boundary $offset" }
                }
                $after = Read-Report $hostProfile
                $drop = @($after.items | Where-Object { $_.weapon.id -eq ($fixture.id+1000) })
                if ($after.inventories[$slot].revision -ne ($before.inventories[$slot].revision+1) -or $drop.Count -ne 1 -or $drop[0].weapon.magazine -ne 11) { throw 'Swap duplicated or lost dropped magazine' }
                if ($slot -eq 1) {
                    Wait-State { (Read-Report $guestProfile).action_result.resultCode -eq 0 } 2
                    for ($copy=0; $copy -lt 3; $copy++) { Send-Control 'Guest' @{command='resend_action'} | Out-Null }
                    Start-Sleep -Milliseconds 700
                    if ((Read-Report $hostProfile).inventories[$slot].revision -ne $after.inventories[$slot].revision) { throw 'Duplicate swap request caused a second exchange' }
                }
                Send-Control $actor @{command='arm';tick=0;actions=@(@{action='interact';pressed=$false})} | Out-Null
            }
        }
        if ($Case -in @('All','A15-cap')) {
            foreach ($actor in $roles) {
                $slot = if ($actor -eq 'Host') { 0 } else { 1 }
                foreach ($weaponKind in 1..3) {
                    $cap = @(120,30,60)[$weaponKind-1]
                    $fixture = Send-Control 'Host' @{command='fixture';case='ammo_cap';slot=$slot;weaponKind=$weaponKind}
                    if (!$fixture.configured) { throw 'Ammo fixture failed' }
                    Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and ($h.items.id -contains $fixture.id) -and ($g.items.id -contains $fixture.id) -and $g.inventories[$slot].reserve[$weaponKind-1] -eq ($cap-1) } 3
                    $before = Read-Report $hostProfile
                    Send-Control $actor @{command='arm';tick=0;actions=@(@{action='interact';pressed=$true})} | Out-Null
                    Wait-State { $h=Read-Report $hostProfile; $g=Read-Report $guestProfile; $h -and $g -and $h.inventories[$slot].reserve[$weaponKind-1] -eq $cap -and $g.inventories[$slot].reserve[$weaponKind-1] -eq $cap -and @($h.items | Where-Object id -eq $fixture.id)[0].amount -eq 1 -and @($g.items | Where-Object id -eq $fixture.id)[0].amount -eq 1 } 3
                    $after = Read-Report $hostProfile
                    if ($after.inventories[$slot].revision -ne ($before.inventories[$slot].revision+1)) { throw 'Cap pickup must change inventory once' }
                    if ($slot -eq 1) {
                        Wait-State { (Read-Report $guestProfile).action_result.resultCode -eq 0 } 2
                        for ($copy=0; $copy -lt 3; $copy++) { Send-Control 'Guest' @{command='resend_action'} | Out-Null }
                        Start-Sleep -Milliseconds 700
                        $duplicate = Read-Report $hostProfile
                        if ($duplicate.inventories[$slot].revision -ne $after.inventories[$slot].revision -or $duplicate.inventories[$slot].reserve[$weaponKind-1] -ne $cap) { throw 'Duplicate cap pickup mutated inventory' }
                    }
                    Send-Control $actor @{command='arm';tick=0;actions=@(@{action='interact';pressed=$false})} | Out-Null
                }
            }
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
    if ($Suite -ne 'GracefulExpiry' -and ($h.hash -ne $g.hash -or $h.seq -ne $g.seq -or ($h.scores -join ',') -ne ($g.scores -join ','))) { throw 'Peer durable states diverged' }
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
