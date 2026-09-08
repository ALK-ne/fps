# 02 ゲームルールと実行アルゴリズム

数値はspec.json。時間はシミュレーションtick、接続期限だけ別の時計。DamageはHP×1000の整数で計算する。0.5ダメージを途中で丸めて捨てない。

## ラウンド進行の全分岐

| 現在状態 | 入力/条件 | 遷移/副作用 |
| --- | --- | --- |
| Lobby | 両者Ready、版/認証OK、初期保存ACK | MatchCreated→RoundPrepared(1)保存 |
| Opening | RoundPrepared両者保存ACK | RoundActivated保存、まだ選択時計を開放しない |
| Opening | RoundActivated両者保存ACK | SelectingFirst、600 tick期限 |
| SelectingFirst | 先手から有効spawnを受信 | 確定しSelectingSecond、600 tick期限 |
| SelectingFirst | 期限tick到達 | 有効6地点から乱数、同上 |
| SelectingSecond | 後手の有効spawn / 期限 | 制約を適用し確定→Countdown、180 tick |
| Countdown | 期限到達 | Fighting、5400 tick、RoundStateを配信 |
| Fighting | 同tick両死亡 | RoundClosed(winner=-1) |
| Fighting | 同tick片側死亡 | RoundClosed(winner=生存slot) |
| Fighting | 期限、双方生存 | HP+Armor比較、同値winner=-1 |
| Resolving | RoundClosed保存ACK | 10勝ならMatchResult、それ以外RoundPrepared(round+1) |
| 非terminal | 接続断/処理停止 | Suspended。既存の通常決着があれば保存対象から捨てない |
| Suspended | 復帰成功/期限 | 04の決定だけを適用 |
| MatchResult | 両者RematchReady | 旧matchを閉じ、新match IDでLobby→開始 |

地点の確定受理条件は「処理するtick < deadline」。期限tickではタイムアウト抽選が先。途中のPhaseState再送で期限をリセットしない。先手の確定地点だけを相手に送る。loot seed、配置候補の中身、乱数状態は選択画面に送らない。

RoundPreparedは直前ラウンドのwinnerを参照する。winner=-1または初回はCSPRNGから別seedを作り一様に先手を抽選。loot seedと先手seedを分離する。保存・共有するのは抽選結果first_slotだけで、RoundPreparedにselectionSeedを含めない。RoundActivatedで正式なround番号を進め、アーマーはscoresでなくround番号から計算する。

## 1 tickの厳密な処理順

1. 受信済みの合法な入力をslot別に1つ採用する。欠落6 tick（100 ms）で軸/射撃holdを0にする。
2. 既存phaseの期限を判定する。Fightingの期限だけはこのtickの処理後に判定する。
3. 入力コンテキストとキャンセル条件を処理。死亡済み・非Fightingの戦闘入力は拒否。
4. 両プレイヤーの移動を同じ開始状態から計算し、player capsule間の重なりを双方半分押し戻す。静的壁へ再sweepする。
5. 武器/投擲/近接の放出要求を受理。slot0とslot1の要求はどちらもこのtick開始時の生存状態で判定する。
6. 既存＋新規弾をsweep、グレネードを積分、爆風/炎/近接を評価。DamageEventをキューに集める。
7. target単位で全damageを合計しアーマー→HPへ適用。近接はdamageでなくimpulse。全員分のHPを更新して死亡を確定する。
8. 生存者のみ回復/リロード/交換/武器切替の完了を処理。被弾で死亡した者の回復は消費せず中断。
9. 拾得の競合を解決し、所持品revisionを各トランザクション1回だけ増やす。
10. 死亡/時間切れによる決着を判定し、Snapshotと表示イベントを作る。

完了tickと同じtickにダッシュ・武器構えを入力した回復は手順3でキャンセルされる。回復完了と非致死被弾が同tickなら被弾後に回復し、最後のHPで時間切れ比較する。

## 入力と排他状態

入力は移動状態と手の状態を分離する。空中だからHEALを拒否しない。SPRINT+HEALのような禁止組合せだけをrejectする。移動軸は長さ1へ正規化し斜めが速くならない。

同tickの複数新規action優先順: Cancel → 武器slot変更 → 投擲構え/解除 → 回復即使用 → Reload → Swap/Pickup → Melee → Fire。Shift/ADSは先にキャンセル条件として評価。異なる優先の新規actionは1個だけ採用し、残りへACTION_CONFLICTを返す。射撃holdは次tick以降も残るが、半自動の押下は再発行しない。

| 現在action | 許すこと | キャンセル/拒否 |
| --- | --- | --- |
| IDLE | 全入力 | 所持/射線/距離の不適合を拒否 |
| SWITCH | 移動 | 再切替は新しい対象で250 ms再開始、射撃/拾得/使用を拒否 |
| RELOAD | 移動/ADS | Fireは弾が残ればリロード中断して発射、武器変更/HEAL/投擲で中断 |
| HEAL | 歩行/ジャンプ/しゃがみ、開始前のSLIDE | Shift/ADS/Fire/武器変更/投擲で中断、別回復で置換、Reload/拾得/近接は拒否 |
| GRENADE_READY | 移動、左保持でAIM | G短押し/武器変更/Escで解除、回復/リロード/拾得/射撃は拒否 |
| GRENADE_AIM | 歩行/ジャンプ、軌道表示 | 左releaseでthrow、G/Esc/武器変更で解除 |
| SWAP | 歩行/しゃがみ、対象を見続ける | E release/視線/距離/対象revision変化/他actionで中断 |
| VAULT | 乗り越え補間のみ | 射撃/拾得/回復開始/投擲を拒否。障害物で開始位置の安全側へ停止 |

HEAL中の所持品は表示上予約するが、完了までは減らさない。HEAL開始時の武器を一時的に下げ、キャンセル/完了後そのslotへ戻す。素手でも同じ処理。

## 移動ソルバー

CharacterBody3Dを衝突proxyとし、MovementSolverへ明示的stateとfixed dtを渡す。予測再演算時にmove_and_slideを可変フレーム回数で呼ばない。`PhysicsServer3D.body_test_motion`または同等のcapsule sweepをArenaQueries内で使い、最大4回の衝突法線への投影でslideさせる。床snapは0.15 m、最大斜面45°。動く足場なし。

地上は目標水平速度へgroundAccel×dtで近づけ、入力0ではbrakeを適用。空中は水平airAccelで操作し、上限は離陸時水平速度とsprintの大きい方。y速度にはgravityを適用。ジャンプは押下edge＋grounded、長押し連続ジャンプなし。しゃがみ中に立てない場所では立ち状態へしない。

SLIDEはsprintかつgroundedでCtrl押下した場合だけ開始。速度11、水平制動5、最大42 tick、低速3未満/Ctrl releaseで終了。ジャンプでAIRに移っても水平速度を保持。開始直後にHEALを始めても既存SLIDEは停止しない。

Space押下時、前方1 mに0.5–1.2 mの壁上端、壁厚≤1.2 m、着地点の立位capsule空間あり、移動sweepが通るならVAULTをジャンプより優先。18 tickのsmoothstep(t)で位置を補間し、上方に0.15×sin(πt) mの余裕を加える。毎tick静的sweepし、塞がれたら最後の安全位置へ停止。相手を貫通しない。

## 射撃・命中・反動

server simulation timeは`floor(tick*1_000_000/60)` μs。連射間隔110000 μsを毎回7 tickへ丸めない。発射後のnextShotUsへintervalUsを加え、長い非射撃後の最初の発射ではnow+intervalUsにする。1 tick内最大1発、過去の押しっぱなし分を連射して取り戻さない。ライフルの初弾→10発目は約0.99–1.00秒になる。

照準rayはcamera originから弾寿命距離まで静的壁/targetを検査し、その最初の点を狙い点とする。弾の開始位置は銃口（eyeから前0.4 m、右0.18 m、下0.15 m）。eye→銃口が遮蔽されていればその壁で弾を止める。銃口→狙い点の方向に発射し、壁越しにcameraだけ出して撃てない。

散布はホストseed＋shot IDから円錐内一様（cosθを一様、φを一様）、散弾8本は別pellet index。head colliderとbody colliderが両方交差したら距離の小さい方。同距離でhead優先。自分の弾は自分に当たらない。弾は敵・壁いずれか最初で消滅、貫通/跳弾なし。

反動pitchは武器の値、yawはその0.2倍以内の符号付き乱数。ホストがShotFiredに全弾の初期値と確定反動offsetを配信する。guestは確定通知で一度だけ反動を表示し、snapshotに包含済みの反動を再加算しない。反動visual offsetは6°/秒で0へ戻す。次の照準は入力角＋現在反動を使い、画面だけ反動して弾は真っすぐという不一致を作らない。

v2ではguestの銃身flash/tracer/音はShotFired確認後だけ表示する。DamageConfirmedはホストから届いてから表示し、推測で敵HPを減らさない。狙い位置の巻き戻しは初版なし。RTTの命中差はA34で評価する。

## 拾得と消費

視線はeyeから2 m、最前面のitem collider。E pressを1回だけPickup要求へ変換。2丁所持で銃を対象とした場合だけSWAPへ入り1秒hold。hold中の継続をInputFrameでホストが確認する。未確認100 msでcancel。

同じtickで同じitem revisionを狙う要求は`priority_slot=(round-1)%2`の側を優先。先に別要求が確定したら残りへSTALE_ITEMを返す。1回のtransactionでitem削除/残量変更＋inventory変更を行い、中間Snapshotを送らない。

銃交換のdrop位置は足元から前0.7 mを床へraycastし、壁際なら半径0.6 m内の8方向から最初の安全点。全滅なら足元。落とした銃のIDと弾倉を保持し、配置銃の満タン初期化を適用しない。Eを離すまで同じ銃を自動で再取得しない。

回復/投擲は1個ずつ、capなら拒否して地面に残す。弾箱は空き予備だけ移し余りを地面に残す。同種2丁は許可、予備弾は共通。素手状態から銃を拾うとそのslotを自動装備する。

## グレネード・炎・近接

フラグはsphere sweepで積分し、衝突法線に対しv'=v−(1+bounce)(v·n)n。残り移動時間を最大3回処理、静止に近ければその場で起爆を待つ。投擲完了から150 tick、構え中には起爆時計を始めない。

爆風damageはmax(0,100×(1−距離/4))をmilli単位に丸め、遮蔽判定後に自傷×0.5。距離はプレイヤーcapsule表面への最短距離。center/headの2本が両方wallで遮断なら0。壁面に接した爆心は法線方向0.02 mだけ離してrayを開始する。

焼夷は最初の接触時に投擲体を消す。接触面法線が上向きならその床、壁なら接触位置＋法線0.05 mから下5 mを検索。床なしは炎なしで終了。初期マップの床面IDと隣接関係を使い、0.5 mグリッドのflood fillで半径2.5 m・段差0.3 m以下・wall非通過のcellを最大81個生成。これで別階へ漏らさない。

発火15 tick後を最初にし、15 tickごと最大20回8 damage。対象capsuleの足元がcellと重なれば1fieldにつき1回。別投擲によるfieldは加算する。途中死亡で後続damageを次ラウンドへ持ち越さない。最大field数8は所持上限と非再出現の初期配置で超えないことを検査する。

近接は視線方向±30°、1.5 m内、壁越し不可。両者同tickなら両方に水平5 m/s加算。HP/Armorは不変、移動ソルバーで次tickの壁衝突を処理する。

## リセット不変条件

RoundActivatedでHP100、当該Armor最大、武器0、予備弾0、回復0、投擲0、action IDLE、飛翔物/炎/古いaction cacheなし。新roundのentity IDは1から再利用可だが、全参照はroundを伴う。再戦ではmatch IDと認証secretを新規生成する。
