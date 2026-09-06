# 03 接続・認証・wire protocol

## 初版の接続経路

ENetConnectionの同じアダプターを全経路で使う。優先順は①ゲーム単体の直接接続＋任意のUPnP、②同じ直接接続へ手動で到達可能endpointを入力、③無料補助経路のTailscale IP。EOSはこの初版の依存に含めない。登録情報のない外部SDKを仮の認証成功で通さない。

ホスト操作は「部屋を作る」→直接接続/補助ネットワークを選択→招待コードをコピー。UPnPはUIの「ルーターへ一時的な接続設定を作成」をONにした時だけ使う。コード実装の許可と、ユーザーのルーター設定変更の許可を混同しない。

UPnP OFFでもlistenを開始できる。UPnP ONではdiscover(timeout=2000)をworkerで実行し、利用可能ポート27840–27849から選んだUDPポートのマッピングを要求する。既存の別用途マッピングを上書きしないため、競合/既存状態を確認できないgatewayでは自動変更を止めて手動/補助経路を表示する。外部アドレス取得失敗・私設アドレス・CGNAT候補・二重NATでは単体接続成功と表示しない。

UPnPの成功は到達性の証明ではない。相手の認証済み接続が完了して初めて「接続済み」。失敗なら8秒で「接続できません。補助ネットワークを利用」を表示する。同じ経路を無制限に調査し続けない。

Tailscaleはユーザーが両PCへ導入・認証・共有済みであることが外部前提。ゲームはローカルIPv4一覧から100.64.0.0/10候補を表示するが、範囲だけでTailscale接続済みとは判定しない。選択またはIP直接入力でENet接続し、実認証成功で確認する。Tailscale CLIのインストールは製品依存にしない。

## 招待コード・身元・再起動

招待コード形式は`AD1:`＋base64url(UTF-8 JSON)。JSONの固定キーはv=1、match（hex32文字）、host（IPv4/IPv6/hostname）、port、secret（32 random bytesのhex64）、rules（hex64）、map（hex64）。最大2048文字。localhost以外でテスト用secretを使わない。コードの共有操作はユーザーが行う。

起動時に128 bit player_idを作りprofileへ保存、boot_idは毎起動新規。部屋作成時にmatch IDと256 bit secretを暗号学的乱数で生成し、hostのpending invitationを保存する。ゲストは最初の認証後に同じmatch、secret、host endpoint、両identity、最新履歴を保存する。表示名はUIのみで、復帰照合に使わない。

ホストは1対戦だけ、guest slot1を最初の認証player IDへ束縛。復帰で別player IDへ譲らない。host slot0固定。再起動は保存済みポートをまずbindし、取れない場合は勝手に別ポートへ変更せずPORT_IN_USE表示。補助ネットワークIPまたは公開endpointが変わった時は保存コードで自動復帰できないため、新しいコードを入力する導線を出すが期限は延長しない。

## ENetの具体的な呼び出し

ホスト: `create_host_bound(bind_address, port, 4, 4)`。未認証の短時間枠を含む4接続を許すが認証済みguestは1つ。ゲスト: `create_host(1, 4)`→`connect_to_host(address, port, 4)`。`service(0)`をフレームごと最大64イベント、最大2 ms予算まで処理し、EVENT_NONEで停止する。

serviceの配列は[type, peer, data, channel]。EVENT_RECEIVEではpeerのget_packet()を読み、そのpeerに対応する認証状態からslotを決める。パケットが申告するslotをそのまま信じない。EVENT_CONNECTだけではゲーム参加させない。

peer.send(channel, bytes, FLAG_RELIABLE)またはflags=0の非確実送信。全送信後にflush。ENetのreliable配送だけでdisk ACKを代用しない。UDP proxyを使う統合試験でも本番と同じENetコードを通す。

| channel | 内容 | 配送 |
| --- | --- | --- |
| 0 | Hello/Auth/Heartbeat/Phase/Ready/Resume制御 | reliable、Heartbeatは非確実 |
| 1 | InputBundle | 非確実、seqで最新採用 |
| 2 | PlayerSnapshot/ProjectileCorrection | 非確実、snapshot tickで最新採用 |
| 3 | ActionRequest/Result、durable記録/ACK、baseline、history chunk | reliable |

大量履歴は8 KiBごとに制御キューへ戻し、別チャネルのheartbeatを妨げない。1論理messageは32 KiBまで。wire packetへ分割する場合は1120 bytes以下のpayload単位とし、同時assemble最大4件、総量128 KiB、期限3秒。サイズ不正で巨大配列を確保しない。

## パケットの正確な共通形式

little endian。整数は範囲検査し、floatはIEEE754 float32有限値のみ。StringはUTF-8 bytesにu16長を付ける。任意Variantのbytes_to_var、オブジェクト復元、ネットワークからのResource loadは禁止。

| offset | bytes | フィールド |
| ---: | ---: | --- |
| 0 | 4 | magic ASCII `ADU1` |
| 4 | 2 | protocol_version=1 |
| 6 | 2 | message_type |
| 8 | 16 | match_id |
| 24 | 4 | connection_epoch |
| 28 | 8 | packet_seq（チャネル/送信方向ごと） |
| 36 | 1 | sender_slot |
| 37 | 1 | channel |
| 38 | 2 | flags（bit0=fragment、その他0） |
| 40 | 4 | payload_length≤1120 |
| 44 | 4 | reserved=0 |
| 48 | N | typed payload |
| 48+N | 32 | HMAC-SHA256(header＋payload) |

packet合計≤1200。断片payloadの先頭はmessage ID:u64、part index:u16、part count:u16、total size:u32、残りが分割bytes。重複partは無視し、part数/総量が矛盾すれば破棄。PlayerSnapshotは単一packetに収める。確定履歴の分割だけでなく、ワールドbaselineにも同じ仕組みを使う。

## 認証手順

1. GuestHello: guest player ID/boot ID/nonce32、protocol/rules/map hash。初回packetのHMACはinvite secretを使う。
2. ホストはsecretと版を検査し、HostChallenge: host identity/boot ID/nonce32、割り当てepoch、guest nonceのechoを返す。同じsecretでMAC。
3. 双方は`session_key=HMAC(secret, "AD1-session" || match || epoch || host_nonce || guest_nonce || host_boot || guest_boot)`を計算。GuestProofは両nonceを含めsession keyでMAC。
4. ホストはGuestProofを検査しAuthenticatedを返す。既存matchならResumeHello、初回ならLobbyへ。3秒で終わらなければ切断。

reconnectごとにhostが未使用epochを保存してから発行する。epochは4章の接続世代で、old_epochを含むRecoveryObservationとの対応を保持する。guestの受け入れ済み最低epoch未満を拒否し、古いpacketを新接続の入力へ流さない。

MAC比較はconstant-time APIを利用。セッションkeyが変わるためpacket seqは新epochで0へ戻せる。非確実チャネルは最新seq未満を破棄、reliable側は1024件の受信windowで重複拒否。パケット紛失は不正と扱わない。HMACは傍受防止ではないので、この経路にチャット/個人情報を乗せない。

認証前はpacket≤1200、Hello≤1 KiB、peerごと10 packet/s、4枠、3秒期限。認証後は240 packet/s・128 KiB/sを2秒windowで検査し、持続超過は切断する。無効payloadを1回受けたことだけで相手の敗北にしない。

## payloadの固定定義

順序は以下の左から右。enumや構造体は01/02と共通。配列の先頭にu16 countを置き、固定配列以外は明示した上限を検査する。

| type | payload | 上限/処理 |
| --- | --- | --- |
| 1 GuestHello | player16, boot16, nonce32, rules32, map32, displayName | 初回のみ、epoch=0可 |
| 2 HostChallenge | hostPlayer16, hostBoot16, hostNonce32, guestNonce32, epoch:u32 | Challenge検証 |
| 3 GuestProof | hostNonce32, guestNonce32 | session key使用 |
| 4 Authenticated | epoch:u32, boundGuest16, hostLatestSeq:u64, hash32 | peer→slot束縛 |
| 5 Heartbeat | sentMonoUs:u64, echoMonoUs:u64, lastServerTick:u64 | RTTは自分のechoだけで算出 |
| 6 LobbyReady | ready:u8 | 同match/両者一致 |
| 10 InputBundle | round:u32, count:u8, InputSample×count | count≤3、古いround拒否 |
| 11 PlayerSnapshot | round:u32, serverTick:u64, ackInputSeq:u64, PlayerWire×2 | 1 packet内 |
| 12 ProjectileCorrection | round:u32, tick:u64, ProjectileWire[] | 最大24個/packet、10 Hz以下 |
| 20 ActionRequest | round:u32, actionId:u64, sampledTick:u64, actionType:u8, targetId:u32, expectedRevision:u32, argument:i32 | 各slot120件/秒以下 |
| 21 ActionResult | round:u32, actionId:u64, resultCode:u16, inventoryRevision:u32, EventWire[] | 副作用は同ID1回 |
| 22 GameEvent | round:u32, eventId:u64, eventType:u8, typedEventPayload | shot/throw/hit/item/armor break |
| 23 PhaseState | round:u32, revision:u32, phase:u8, firstSlot:u8, spawns:i8×2, deadlineTick:u64 | lootなし |
| 24 WorldBaseline | round:u32, startTick:u64, Players×2, Pickups[], Grenades[], Flames[] | 最大32 KiB、ACK後に操作開放 |
| 25 WorldReady | round:u32, baselineHash32 | baselineを適用済み、該当roundのみ |
| 30 DurableTransaction | firstSeq:u64, prevHash32, canonicalBytes | 04で検証して保存 |
| 31 DurableAck | seq:u64, hash32, epoch:u32 | 保存完了のみ |
| 32 ResumeHello | oldEpoch:u32, boot16, oldPeerBoot16, seq:u64, hash32, observedRound:u32, remainingMs:u32, cause:u8, terminal:u8 | remaining≤60000 |
| 33 HistoryRequest | checkpointSeq:u64, seq:u64, hash32 | 既知prefixから要求 |
| 34 HistoryChunk | fromSeq:u64, toSeq:u64, bytes | 8 KiBまで、順に適用 |
| 35 ResumePrepared | recoveryId16, oldEpoch:u32, resolution:u8, offender:i8, baseSeq:u64, baseHash32, remainingMs:u32 | hostから提案 |
| 36 ResumePreparedAck | recoveryId16, baseHash32 | deadline内・照合済みを表す |
| 37 Checkpoint | seq:u64, hash32, stateBytes, checkpointHash32 | 04の保存境界 |
| 40 RematchReady | ready:u8 | 両者trueで新match |
| 41 GracefulLeave | reason:u8, oldEpoch:u32 | 送信者の切断観測を保存 |

InputSampleはseq:u64、sampleTick:u64、axisX/axisY:i16（−32767..32767）、yaw/pitch:f32、held:u16。held bitは0 forward、1 back、2 left、3 rightを使わず軸に統一し、0 fire、1 ads、2 sprint、3 crouch、4 interact、5 grenadeAim。ジャンプ等のedgeはActionRequestへ送る。

PlayerWireはslot:u8、position:f32×3、velocity:f32×3、yaw/pitch:f32、hp/armor:i32、movement flags:u16、action:u8、actionEndTick:u64、inventoryRevision:u32、activeSlot:i8、各武器のid:u32/kind:u8/mag:u16×2、reserve:u16×3、heal:u8×4、grenade:u8×2、slideRemaining:u16、vaultStart/End:f32×3、vaultProgress:u16。未知の列を黙って読み飛ばさずprotocol mismatchとして拒否。

ProjectileWireはid:u32、owner:u8、kind:u8、position:f32×3、velocity:f32×3。spawn/expiry/shot IDはGameEvent SpawnProjectileで初回送信し、未知IDのcorrectionはbaseline再要求。snapshotでdamageを推論しない。

EventWireの固定typeはShotFired（shotID,weaponID,origin,dir,seed）、ProjectileEnded（id,point,normal）、DamageConfirmed（target,amount,hitKind,shotID）、InventoryChanged（slot,full Inventory）、PickupChanged（id,revision,kind,amount,position）、GrenadeThrown（id,owner,kind,pos,vel,expiryTick）、FlameCreated（id,owner,expiryTick,cells）、ArmorBroken（slot）。これ以外の自由なDictionary eventを追加しない。

## 入力遅延と予測補正

ホストは受信入力のseqを単調に進め、sample tickが推定server tick±12以上ならrejectする。sample tickを命中時刻として使わず、受け取った次の物理tickに適用する。過去入力を後からホスト世界へ差し込まない。RTT由来の推定offsetはHeartbeatの往復から平滑化し、急変時は250 ms以内で補正する。

ゲストは256入力ringを持ち、SnapshotのackInputSeq以前を捨て、権威MovementStateへ戻して残りを同じMovementSolverで再実行する。衝突proxyの位置は直ちに補正、cameraだけ誤差を100 msで補間。誤差1 m以上/壁貫通/ring溢れは即補正しbaseline再要求。再演算で音・消費・弾生成を二重実行しない。

相手はserverTickの100 ms前を補間、100 ms以上データがなければ外挿停止。角度は最短経路、瞬間移動/round変更では補間を破棄する。全てのdamage/拾得はホストだけが確定する。

## 列挙値と入れ子データの固定

enum値は以下を正とし、未知値は拒否する。wireでは型名に対応するu8、ResultCodeだけu16。後から追加する場合はprotocol versionを上げる。

| enum | 値 |
| --- | --- |
| Phase | Lobby=0、Opening=1、SelectingFirst=2、SelectingSecond=3、Countdown=4、Fighting=5、Resolving=6、Suspended=7、MatchResult=8、Conflict=9、StorageError=10 |
| ActionType | Cancel=0、SwitchWeapon=1、GrenadeToggle=2、UseHeal=3、Reload=4、Interact=5、Melee=6、FirePressed=7、JumpVault=8、SelectHeal=9、SelectGrenade=10、GrenadeRelease=11、ChooseSpawn=12 |
| ActionState | IDLE=0、SWITCH=1、RELOAD=2、HEAL=3、GRENADE_READY=4、GRENADE_AIM=5、SWAP=6、VAULT=7 |
| WeaponKind | NONE=0、rifle=1、shotgun=2、pistol=3 |
| PickupKind | weapon=1、ammo=2、heal=3、grenade=4 |
| HealKind | health_small=1、health_full=2、armor_small=3、armor_full=4 |
| GrenadeKind | frag=1、incendiary=2 |
| ResultCode | OK=0、WRONG_PHASE=1、STALE_ROUND=2、STALE_ITEM=3、OUT_OF_RANGE=4、OCCLUDED=5、NO_STOCK=6、CAP_REACHED=7、ACTION_CONFLICT=8、INVALID_INPUT=9、COOLDOWN=10、UNKNOWN_TARGET=11 |
| GameEventType | ShotFired=1、ProjectileEnded=2、DamageConfirmed=3、InventoryChanged=4、PickupChanged=5、GrenadeThrown=6、FlameCreated=7、ArmorBroken=8 |
| DurableType | MatchCreated=1、RoundPrepared=2、RoundActivated=3、RoundClosed=4、RecoveryResolved=5、CheckpointInstalled=6 |
| RecoveryDisposition | close=0、keep=1、forfeit=2、abort=3 |
| RecoveryCause | SILENCE=0、ENET_DISCONNECT=1、GRACEFUL_LEAVE=2、LOCAL_STALL=3、CLOCK_UNCERTAIN=4 |
| HitKind | body=0、head=1、explosion=2、fire=3 |

ActionRequest.argumentはSwitchWeaponにslot0/1、UseHeal/SelectHealにkind1–4、SelectGrenadeにkind1/2、ChooseSpawnにspawn0–5。それ以外0。targetId/revisionはInteractだけで使用し、他actionでは0を要求する。GrenadeToggleは構え/解除、GrenadeReleaseは照準中の放出。ADS/移動/射撃hold/aim holdはInputSample、半自動FirePressedとJumpVaultはedge要求を使う。

| 入れ子型 | byte順（左→右） |
| --- | --- |
| Vec3 | x:f32,y:f32,z:f32 |
| InventoryWire | revision:u32,activeSlot:i8,WeaponWire×2,reserve:u16×3,heals:u8×4,grenades:u8×2,selectedHeal:u8,selectedGrenade:u8 |
| WeaponWire | id:u32,kind:u8,magazine:u16。空slotは全0 |
| PickupWire | id:u32,revision:u32,kind:u8,subtype:u8,amount:u16,position:Vec3,WeaponWire（非weaponは全0） |
| GrenadeWire | id:u32,owner:u8,kind:u8,position:Vec3,velocity:Vec3,expiryTick:u64 |
| FlameWire | id:u32,owner:u8,expiryTick:u64,nextDamageTick:u64,cellCount:u16,CellWire×count（≤81） |
| CellWire | surfaceId:u16,gridX:i16,gridZ:i16,height:f32 |
| ShotFired | shotID:u64,weaponID:u32,origin:Vec3,direction:Vec3,seed:u64 |
| ProjectileEnded | id:u32,point:Vec3,normal:Vec3 |
| DamageConfirmed | target:u8,amountMilli:i32,hitKind:u8,shotID:u64（爆風/炎は対応entity IDをu64化） |
| InventoryChanged | slot:u8,InventoryWire |
| PickupChanged | PickupWire（削除はkind保持＋amount=0） |
| GrenadeThrown | GrenadeWire |
| FlameCreated | FlameWire |
| ArmorBroken | slot:u8 |

EventWireはeventId:u64,type:u8,payloadLength:u16,payload。EventWire[]はcount:u16≤64。GameEvent.messageのtyped payloadも同じ定義を使う。PlayerSnapshotのackInputSeqは受信するguest自身の入力ACKである。

WorldBaselineはPlayerWire×2、PickupWire[]≤32、GrenadeWire[]≤4、FlameWire[]≤8、ProjectileWire[]≤128をその順に格納する。baselineHashはcanonical payload全体のSHA256。Countdown開始と同時に送信しWorldReadyを待つ。3秒終了時にReady未着ならFightingへ進めずSuspendedへ。FightingのPhaseStateだけ先着しても、guestは当該baseline適用まで操作を開放しない。

Snapshotのmovement flagsはbit0 grounded、bit1 crouched、bit2 sprinting、bit3 slide、bit4 vault、他0。フル予測stateの必要な列を省略しない。通常PlayerSnapshotは小さい固定長、item/投擲の変更はrevision付きreliable eventで配信し、未知revisionではbaselineを再要求する。

## 参照した公式仕様

ENetの呼び出しとイベント配列は[ENetConnection](https://docs.godotengine.org/en/stable/classes/class_enetconnection.html)、UPnPの失敗/マッピング条件は[UPNP](https://docs.godotengine.org/en/stable/classes/class_upnp.html)を確認した。専用SDKなしの設計はこれらからの採用判断で、家庭回線での到達性の実証ではない。
