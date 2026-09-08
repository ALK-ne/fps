# 03 接続・認証・wire protocol

## 初版の接続経路

ENetConnectionの同じアダプターを全経路で使う。優先順は①ゲーム単体の直接接続＋任意のUPnP、②同じ直接接続へ手動で到達可能endpointを入力、③無料補助経路のTailscale IP。EOSはこの初版の依存に含めない。登録情報のない外部SDKを仮の認証成功で通さない。

ホスト操作は「部屋を作る」→直接接続/補助ネットワークを選択→招待コードをコピー。UPnPはUIの「ルーターへ一時的な接続設定を作成」をONにした時だけ使う。コード実装の許可と、ユーザーのルーター設定変更の許可を混同しない。

UPnP OFFでもlistenを開始できる。UPnP ONではdiscover(timeout=2000)をworkerで実行し、利用可能ポート27840–27849から選んだUDPポートのマッピングを要求する。既存の別用途マッピングを上書きしないため、競合/既存状態を確認できないgatewayでは自動変更を止めて手動/補助経路を表示する。外部アドレス取得失敗・私設アドレス・CGNAT候補・二重NATでは単体接続成功と表示しない。

UPnPの成功は到達性の証明ではない。相手の認証済み接続が完了して初めて「接続済み」。失敗なら8秒で「接続できません。補助ネットワークを利用」を表示する。同じ経路を無制限に調査し続けない。

Tailscaleはユーザーが両PCへ導入・認証・共有済みであることが外部前提。ゲームはローカルIPv4一覧から100.64.0.0/10候補を表示するが、範囲だけでTailscale接続済みとは判定しない。選択またはIP直接入力でENet接続し、実認証成功で確認する。Tailscale CLIのインストールは製品依存にしない。

## 招待コード・身元・再起動

招待コード形式は`AD2:`＋base64url(UTF-8 JSON)。JSONの固定キーはv=2、match（hex32文字）、host（IPv4/IPv6/hostname）、port、secret（32 random bytesのhex64）、rules（hex64）、map（hex64）。最大2048文字。localhost以外でテスト用secretを使わない。コードの共有操作はユーザーが行う。

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
| 2 | PlayerSnapshot/EntityCorrection | 非確実、snapshot tickで最新採用 |
| 3 | ActionRequest/Result、durable記録/ACK、baseline、history chunk | reliable |

大量履歴は8 KiBごとに制御キューへ戻し、別チャネルのheartbeatを妨げない。1論理messageは32 KiBまで。wire packetへ分割する場合は1120 bytes以下のpayload単位とし、同時assemble最大4件、総量128 KiB、期限3秒。サイズ不正で巨大配列を確保しない。

## パケットの正確な共通形式

little endian。整数は範囲検査し、floatはIEEE754 float32有限値のみ。StringはUTF-8 bytesにu16長を付ける。任意Variantのbytes_to_var、オブジェクト復元、ネットワークからのResource loadは禁止。

| offset | bytes | フィールド |
| ---: | ---: | --- |
| 0 | 4 | magic ASCII `ADU1` |
| 4 | 2 | protocol_version=2 |
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
3. 双方は`session_key=HMAC(secret, "AD2-session" || match || epoch || host_nonce || guest_nonce || host_boot || guest_boot)`を計算。GuestProofは両nonceを含めsession keyでMAC。
4. ホストはGuestProofを検査しAuthenticatedを返す。既存matchならResumeHello、初回ならLobbyへ。3秒で終わらなければ切断。

reconnectごとにhostが未使用epochを保存してから発行する。epochは4章の接続世代で、old_epochを含むRecoveryObservationとの対応を保持する。guestの受け入れ済み最低epoch未満を拒否し、古いpacketを新接続の入力へ流さない。

MAC比較はconstant-time APIを利用。セッションkeyが変わるためpacket seqは新epochで0へ戻せる。非確実配送は下記のmessage/entity単位のseq/tickで旧データを破棄、reliable側は1024件の受信windowで重複拒否。パケット紛失は不正と扱わない。HMACは傍受防止ではないので、この経路にチャット/個人情報を乗せない。

認証前はpacket≤1200、Hello≤1 KiB、peerごと10 packet/s、4枠、3秒期限。認証後は240 packet/s・128 KiB/sを2秒windowで検査し、持続超過は切断する。無効payloadを1回受けたことだけで相手の敗北にしない。

## v1.1 wire契約（protocol 2）

2026-09-08、実装HEAD `0d4f58a`を照合。以下は次の実装向け仕様であり、現行0.1.0の実装済み宣言ではない。上記の共通headerはmagic `ADU1`を維持、versionだけ2。招待は`AD2:`、v=2、KDFラベルは`AD2-session`。旧AD1コードは接続前に「通信版が異なります」、旧version packetは認証処理前に破棄する。自動ダウングレードなし。次の互換性破壊ビルドは0.2.0。rules/map hashはゲーム定数/マップ内容、protocolは通信互換、storeSchemaは保存互換を示し、互いの代用にしない。

全payloadは固定順typed binary。正確なfield順・型・最大配列数は[wire-schema.mjs](wire-schema.mjs)、各typeの正常byte列と不足/余剰byte列は[wire-vectors.json](wire-vectors.json)を本章の一部とする。この参照encoderは設計資料であって製品codecではない。製品側で独立実装し、A03でbyte一致と拒否を検査する。末尾まで消費しないdecodeは失敗。u8 boolは0/1限定。配列はu16 count、文字列/opaque bytesはu16 byte length。型の幅はschemaの名前どおり。f32は有限、Vec3各成分絶対値4096以下、速度成分1024以下。計数/enum/長さを確保前に検査する。opaque record/checkpointも04のschema/サイズ/hash/reducerで検査し、任意Dictionaryのネット復元は禁止。

H=host、G=guest、B=双方向。authは未認証の指定handshake stepのみ、sessionはMACとidentity/epoch検査済み。phase略称: L=Lobby、S=SelectingFirst/Second、C=Countdown、F=Fighting、R=Resolving/Opening、U=Suspended、T=MatchResult/復帰停止。Allはsession内の全phase（StorageErrorでは診断と退出のみ）。未記載typeは予約、送信禁止。payload上限はschemaから算出し、論理message全体32 KiB上限も適用する。

| type / 名称 | ch / 配送 | 方向 | 段階・phase | 現行session.gdとの対応、実装変更 |
| --- | --- | --- | --- | --- |
| 1 GuestHello | 0/R | G→H | auth/Hello | _on_connect/_handshake、名前を除去 |
| 2 HostChallenge | 0/R | H→G | auth/Challenge | _handshake |
| 3 GuestProof | 0/R | G→H | auth/Proof | _handshake |
| 4 Authenticated | 0/R | H→G | auth/Accepted | _handshake/_bind |
| 5 Heartbeat | 0/U | B | session/All | poll/_dispatch |
| 6 LobbyReady | 0/R | B | session/L | _bindの自動開始を両者Readyへ変更 |
| 10 InputBundle | 1/U | G→H | session/F | physics/_dispatch、actionsを分離 |
| 11 PlayerSnapshot | 2/U | H→G | session/C,F | SnapshotCodecの278 byteを採用 |
| 12 EntityCorrection | 2/U | H→G | session/F | 新設、弾と投擲の移動補正 |
| 20 ActionRequest | 3/R | G→H | session/F | physics/_dispatch、独立actionId |
| 21 ActionResult | 3/R | H→G | session/All | 新設、要求の結果だけを通知 |
| 22 GameEvents | 3/R | H→G | session/C,F,R | 自由なevents辞書をtyped batchへ |
| 23 PhaseState | 0/R | H→G | session/L,S,C,F,R,U,T | _publish_phase |
| 24 WorldBaseline | 3/R | H→G | session/C,F,R | _send_baseline、全entityを含む |
| 25 WorldReady | 3/R | G→H | session/C,F,R | 初回/再同期の適用ACK |
| 26 BaselineRequest | 3/R | G→H | session/C,F,R | 新設、再同期要求 |
| 30 DurableRecord | 3/R | H→G | session/L,S,C,F,R,U,T | _commit、1記録ずつ保存 |
| 31 DurableAck | 3/R | B | session/L,S,C,F,R,U,T | _after_ack、record/checkpoint識別 |
| 32 ResumeHello | 0/R | B | session/U,T | _resume_data/_reconcile、terminal bool廃止 |
| 33 HistoryRequest | 3/R | B | session/U | _dispatch、既知prefix |
| 34 HistoryChunk | 3/R | B | session/U | 1recordまたはdone |
| 35 ResumePrepared | 3/R | H→G | session/U | _reconcile、newEpochも照合 |
| 36 ResumePreparedAck | 3/R | G→H | session/U | _commit_recovery、残存側remainingを返す |
| 37 Checkpoint | 3/R | H→G | session/R,U | _after_ack、blob hashを別検査 |
| 39 CheckpointCommit | 3/R | H→G | session/R,U | 現行type39を正式登録 |
| 40 RematchReady | 0/R | B | session/T | rematch、確定終了だけ |
| 41 GracefulLeave | 0/R | B | session/All | close/_lost、明示原因を保持 |
| 42 RematchOffer | 0/R | H→G | session/T | _new_rematch、現行type42を正式登録 |
| 43 StatusRequest | 0/R | B | session/U,T | 新設、終了後も診断認証可 |
| 44 StatusReply | 0/R | B | session/U,T | 新設、04の証拠を返す |
| 45 StatusAck | 0/R | B | session/U,T | 新設、通知保存後ACK |
| 50 ChooseSpawn | 0/R | G→H | session/S | choose_spawn、現行type50を正式登録 |

R=reliable、U=unreliable。非確実packetのreplay判定は1024件windowで行い、採用tickはmessage typeごと（type12はentityごと）に比較する。同tickの複数packetを捨てない。11と12は同channelでも互いを落とさない。fragmentの各packetは独立seq、論理message IDで再構成する。初回認証後、Gがtype4を受け取るより先に別channelのsession-key packetが来る場合は16件/16 KiB/3秒だけ保留し、type4検査後に同じvalidatorへ渡す。保留中にgame stateを変えない。

## enumと意味検査

PhaseはLobby=0,Opening=1,SelectingFirst=2,SelectingSecond=3,Countdown=4,Fighting=5,Resolving=6,Suspended=7,MatchResult=8,Conflict=9,StorageError=10。復帰画面の細分状態は04の別enumで保持し、戦闘phaseと混同しない。
ActionTypeはCancel=0,SwitchWeapon=1,GrenadeToggle=2,UseHeal=3,Reload=4,Interact=5,Melee=6,FirePressed=7,JumpVault=8,SelectHeal=9,SelectGrenade=10,GrenadeRelease=11。ChooseSpawnはtype50だけで送る。ActionStateはIDLE=0,SWITCH=1,RELOAD=2,HEAL=3,GRENADE_READY=4,GRENADE_AIM=5,SWAP=6,VAULT=7。
WeaponKind=NONE0/rifle1/shotgun2/pistol3、PickupKind=weapon1/ammo2/heal3/grenade4、HealKind=health_small1/health_full2/armor_small3/armor_full4、GrenadeKind=frag1/incendiary2、HitKind=body0/head1/explosion2/fire3。
ResultCode=OK0,WRONG_PHASE1,STALE_ROUND2,STALE_ITEM3,OUT_OF_RANGE4,OCCLUDED5,NO_STOCK6,CAP_REACHED7,ACTION_CONFLICT8,INVALID_INPUT9,COOLDOWN10,UNKNOWN_TARGET11,STALE_ACTION12。
DurableType=MatchCreated1/RoundPrepared2/RoundActivated3/RoundClosed4/RecoveryResolved5/CheckpointInstalled6。RecoveryDisposition=close0/keep1/forfeit2/abort3。RecoveryCause=SILENCE0/ENET_DISCONNECT1/GRACEFUL_LEAVE2/LOCAL_STALL3/CLOCK_UNCERTAIN4。

InputBundleは直近3入力までをseq昇順で再送する。axisはi16の-32767..32767（-32768禁止）、yawは[-π,π]、pitchは[-π/2,π/2]。heldはfire bit0,ads1,sprint2,crouch3,interact4,grenadeAim5、他0。100 ms入力不達で全held/軸をneutral化。sampleTickは推定host tick±12以内、受信後の次tickで適用し、過去の命中判定に戻さない。hostはslotを接続から決める。

ActionRequestはround内で単調actionId、元inputSeq、sampleTickを持つ。Gの未結果要求は最大16、Hはround内の直近2048件の結果とaction highwaterを保持。重複IDは保存結果を返し副作用0、cacheより古いIDはSTALE_ACTION、将来roundはSTALE_ROUND。要求はslotあたり120件/秒まで。SwitchWeapon.argument=0/1、UseHeal/SelectHeal=1..4、SelectGrenade=1/2、他0。targetId/revisionはInteractのみ、他0。保持交換は開始actionIdに結び、完了時1回結果、取消はACTION_CONFLICT。内部STALE_ITEM等はResultCodeへ明示変換し文字列をwireに送らない。ActionResultのacceptedTick=処理tick、completeTick=実際の完了または拒否tick。音/世界変化はGameEventsだけで通知する。

ChooseSpawnはround/revision/手番/地点範囲0..5/有効ペア/tick<deadlineを全検査。requestIdの重複はPhaseState再送だけ。失敗も最新PhaseStateを返し進行しない。RematchOfferは双方Ready後だけ受理し、新match/secret、同identity/host役を検査する。

PlayerWireは現在のSnapshotCodecと同じ133 byte、header12＋2人で278 byte。flagsはgrounded bit0,crouched1,sprinting2,vaulting3、他0。slideは独立u16、vaultProgressもu16。recoilとvault座標も有限検査する。slotは順に0,1、hp/armor/armorMaxはmilli単位のi32（現行Replicationと同じ）。hp0..100000、armor0..armorMax、armorMaxはroundの規定値×1000。inventoryは空武器(id/kind/magすべて0)、ID非重複、mag24/6/12以下、reserve120/30/60以下、heal4/2/4/2以下かつ合計12以下、grenade合計2以下、activeSlot=-1/0/1（空なら-1）、選択kind範囲を検査。revisionが古ければinventoryだけ巻き戻さない。

| 失敗 | 処理 |
| --- | --- |
| 不足/余剰byte、非有限、過大count、未知enum、予約bit | decode拒否、状態変更0、理由別counter。1件で敗北にしない |
| MAC/identity/epoch/方向/auth段階違反 | packet破棄。未認証期限3秒、同peer不正10件/2秒で切断 |
| version違い | 接続拒否表示、未認証packetは応答増幅せず破棄 |
| 正しい形式の操作だがphase/round/revision/在庫不適合 | ActionResult。spawnはPhaseState。ゲーム上の拒否で切断しない |
| 古いsnapshot/event/ACK | no-op（永続履歴の同seq別hashは04のConflict） |
| 認証後240 packet/sまたは128 KiB/sを2秒windowで超過 | 接続切断→通常の観測、責任/勝者は04で別判定 |
| fragment矛盾/期限切れ、unknown entity | 前者破棄、後者下記のbaseline要求。推測でHPや得点を変えない |

## entity生成・補正・削除

entity key=(match,round,entityKind,id)、kind=projectile1/grenade2/flame3/pickup4。IDは各kindのround内u32、1始まりで再利用しない。上限projectile128、grenade4、flame8、pickup32。上限に達する生成はホストで拒否し消費しない（通常ルール下の上限到達も試験する）。shotIdはround内u64、散弾pelletIndex=0..7、他0。seed再現をguestへ要求せず、ShotFiredに生成した全projectileを明示する。SpawnProjectileという未登録eventは使わない。

GameEventsはround,firstEventSeq,serverTick,countとEventの列。eventSeq=firstEventSeq+index、round内1始まり、全構造変更は同channel3の連番。Eventはtype:u8,payloadLength:u16,typed payload。schemaのeventTypesが正確な順序を定義する。

| event | 生成/変更/終端の意味 |
| --- | --- |
| 1 ShotFired | shotId,weaponId,owner,recoilPitch/YawとProjectileSpawn配列。rifle/pistol1本、shotgun8本。生成位置/初速/spawnTick/expiryTickを全て載せる |
| 2 ProjectileEnded | id,reason,point,normal。reason=hit1/wall2/expired3、削除しtombstone化 |
| 3 DamageConfirmed | target,amountMilli,hitKind,sourceId。表示通知のみ。HPはsnapshot、得点はdurable |
| 4 InventoryChanged | slot,完全Inventory。revisionが新しい時だけ採用 |
| 5 PickupChanged | 完全Pickup。amount=0で削除、同IDはrevision昇順 |
| 6 GrenadeThrown | 完全GrenadeSpawn、spawn/expiryを含む |
| 7 FlameCreated | 完全Flame、セルは世界座標Vec3最大81。surface gridへの独自逆変換不要 |
| 8 ArmorBroken | slot。音/表示のみ |
| 9 EntityRemoved | kind=grenade2/flame3,id,reason。reason=detonated1/contact2/expired3/noFloor4。fragment爆発はgrenade削除とdamageを同batch、焼夷はgrenade削除→FlameCreated |

正常期限でもホストが削除eventを送る。guestはexpiryTickで表示を隠せるが、権威消滅・damageを確定しない。round終了ではRoundClosed/新roundを境に旧world・event履歴・tombstoneを全部破棄する。

EntityCorrectionはround,tick,requiredEventSeq,最大24件(kind,id,pos,vel)。10 Hz、24超は同tick複数packet、type単位のpacket seqでは分割を落とさずentity単位tickを比較する。静止flame/pickupは送らない。guestの弾表示は初速で積分し、投擲は同じ重力/静的衝突を表示用に積分、補正を50 msで吸収、誤差1 m以上はsnap。hostの当たり判定を呼ばず、表示積分でHP/消費/爆発/炎を発生させない。

| 到着状態 | 受信動作 |
| --- | --- |
| 現round、eventSeq=次番号 | 適用→連番を進める。以後の保留をdrain |
| 適用済みeventSeq | 同内容ならno-op、別内容はPROTOCOL_CONFLICTで停止 |
| 次番号より先のevent | 最大1024件/256 KiB/500 ms保留、欠落継続ならbaseline要求 |
| 補正が生成より先、requiredEventSeq未適用 | 最大128件/1秒保持、必要eventを待つ。超過/時間切れでbaseline要求 |
| tombstone済みIDへの遅延補正/生成 | 無視。ID再利用は不正。tombstoneはround終わりまで保持（下記の生成総数上限内） |
| 既存IDの重複生成 | 内容一致ならno-op、不一致なら再同期。baseline後も不一致ならConflict |
| 前round/前match | 破棄 |
| 未来round | 操作へ適用せずPhaseState/永続round確定を待つ。上限16件/16 KiB/3秒、超過なら再同期 |

WorldBaselineはround,baselineId,tick,cutEventSeq,Player×2,pickups,projectiles,grenades,flames,hash32。hashはhash自身を除くtyped payloadのSHA256。baselineIdはround内単調、作成は物理tick終端の一貫したworldから。cutEventSeq以下を置換で包含し、上のeventだけを適用する。受信側は候補へ全decode/意味/hash検査→旧baselineより新しいこと確認→一括swap→cut以下の保留破棄→cut超のevent再適用→baseline tickより新しいplayer snapshotとentity補正を適用。HP/inventoryを古いsnapshotで巻き戻さない。ACKは適用後にround/id/hashを返す。初回はACK前に操作禁止、再同期中も入力neutral。Hは3秒Ready未着ならSuspendedへ。

BaselineRequestは同時1件、毎秒1回まで、2秒で同requestIdを再送、合計3送信後はRESYNC_UNAVAILABLE表示で停止・接続へ戻る。Hは同IDに同baselineを返し、最新1個をACKまで保持、次要求で置換。Fighting開始時と要求時だけfull baseline、個数変化/2 Hzの暫定全world送信は廃止する。

時系列例: H tick100でShotFired(seq20,pellet1..8)→Gへ補正tick102(required20)が先着し保留→seq20到着で8本生成し補正適用→seq21 ProjectileEnded(id1)→遅延tick101 id1補正を無視。baseline cut22が来た場合は22までを包含したworldへ置換し、既受信seq23だけ再適用。round2へ切替後のround1補正/eventは全破棄。

## 予測・再演算・cameraの処理順

v2の先行予測は移動とADS表示だけ。guestのshot/flash/tracer/銃声/反動はShotFired到着後1回。射撃先行予測は採用しないので、未確定shot IDの採番/rollbackは不要。host発射は即表示。反動はShotFiredの確定offsetとsnapshot tickを対応させ、snapshotに包含済みの反動を再加算しない。音はeventSeqで重複抑止する。

毎physics tick: (1)受信を検証してqueueへ、(2)新roundならring/remote interpolation/camera offsetをclear、(3)自slotの最新snapshotのMovementStateへ戻しproxyを即移動、(4)ackInputSeq以下のringを捨てる、(5)未ACKをseq順に同じfixed dt/MovementSolver/ArenaQueriesで再演算、(6)予測前後差をcamera offsetに加える、(7)今回入力を追加し予測する。再演算はmovement専用でaction queue/武器/消費/音を呼ばない。snapshot action/vault/slideなど移動拘束も開始状態として復元する。

cameraはeye＋offset。offsetを100 msで0へ線形減衰、毎frame corrected eye→表示eyeのcapsule sweepを行い壁を横切るならoffset=0。誤差>=1 m/壁貫通/ring256超はoffset=0、ring破棄、BaselineRequestを実行し適用までneutral。単にoverflowフラグを立てて継続しない。保存履歴にcamera offsetは含めない。

相手はserverTickの6 tick前を補間、最新sampleから最大6 tickだけ外挿して停止、yawは最短経路。32 sample保持。teleport/round/baseline置換で補間をclear。画面上の位置・camera誤差と物理proxy位置を別々に計測する。

## 上限の補足

round内のentity生成累計は各kind8192、到達時は生成を拒否し消費0とする。通常90秒の最大射撃/拾得頻度では届かない防御上限で、tombstoneも各kind8192以下。GameEventsの過去内容比較は最新1024件のSHA256だけ保持し、それ以前の重複seqはno-op。未来保留とは別の上限。batchはcount64以下かつ32 KiB以内で分割し、countだけを満たす巨大batchを作らない。u64の時刻/seq/IDは製品と保存codecの共通範囲0..2^63-1、epoch/IDが上限へ達したらwrapせず接続/新規生成を停止する。

Type34はdone=0ならrecord長>=128、done=1なら長0。Type31はrecord ACK(kind0)でcheckpointHash全0、checkpoint ACK(kind1)で該当hash必須。Type26.reasonはgap1/unknownEntity2/revision3/prediction4/invalidBaseline5。Player.actionKindはactionがHEALなら1..4、GRENADE_READY/AIMなら1..2、それ以外0。expiryTick>spawnTick、projectileは差120、grenadeは差150、flameは差300、pelletはkind2で0..7/他0。ShotFiredのowner/shotIdは全projectileと一致。Pickup.subtypeはkind別にweapon1..3/ammo1..3/heal1..4/grenade1..2、amountはweapon1/削除0または該当cap以内を検査する。

## 配送と保存の境界補足

03の許可phaseは最新の永続roundと受信制御状態で判断し、画面の描画遅延で合法packetを拒否しない。別channelのPhaseStateより先着した同roundのC/F snapshotは16件/16 KiB/3秒の保留枠へ置き、対応制御後に適用する。構造eventのgapがある間に新しいsnapshotを適用した場合、後着InventoryChangedはrevision、DamageConfirmed/ArmorBrokenは通知IDだけで処理し、HPを過去へ戻さない。
