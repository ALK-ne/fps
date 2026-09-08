# 07 補助仕様：実装可能な受入シナリオ v1.1

本書は[07](07-acceptance.md)のA03/A14–A35を具体化する正本の一部。以下のハーネス拡張は**未実装の契約**。既存integration.ps1のSmoke/FullMatch/Rematch/NetworkFaults/RecoveryRealtime/GuestRecoveryRealtime/ExpiryRealtime/GuestExpiryRealtime/Allとは区別する。設計更新だけでacceptance-run.mdの状態を変更しない。

## ハーネスAPIと共通証拠

追加予定CLI: `tools/integration.ps1 -Suite <Wire|Inventory|Entities|RecoveryMatrix|Product|NetworkMatrix> -Case <caseId|All> -Role <Host|Guest|Both> -Seed 1701 -RunId <unique>`。source testとacceptance exportを同じシナリオrunnerで実行し、製品用設定/保存とは別のrunId別profileを使う。起動待ち120秒はbootstrap予算でありゲームの期限に数えない。PID/role/bootをready通知で確定してから試験開始。

制御はdebug/test専用ローカルIPC（stdout JSON通知＋stdin指令、実装できないOS経路はloopback control socket）でtick barrierを使う。指令は`arm(case,tick,actions)`、`observe(fields)`、`fault(point,recordType,occurrence)`、`continue(token)`。barrierでreadyをstdoutへ出した後、外部ハーネスがkillする。gameplayの60秒はbarrierで凍結せずRealtimeでは本番Clockを使う。FakeClock suiteは別run。試験操作も通常Input/Action経路へ入り、offender/remote score/再接続portを外から教えない。

両endpointからrunId,build/engine/rules/map/protocol/store schema,role,boot,phase,round,tick,seq/hash,scores,inventory revision/各個数,entity ID集合/生成消滅tick,actionId結果,ACK状態,recoveryId/receipt/highwater,timer/block/result/winnerを採る。全状態の毎tickファイル書込は禁止。集計ringをメモリに保持し終了後まとめて出力。秘密鍵/コード/IPは記録しない。

各caseは双方の最終状態を独立の期待表と比較し、片側成功だけではPASSにしない。ネット配送待ちは状態収束期限2秒（baseline再試行のケースのみ6秒）を持つ。通常caseでdeadline越え/stallが発生したら環境失敗として記録し、失敗をリトライで隠さない。

## A03/A20 wireと状態違反

全32typeは[wire-vectors.json](wire-vectors.json)の正常構造・不足・余剰byteを独立製品codecへ投入し、再encodeのbyte一致とエラーを検査する。正常構造vectorのゼロID/空recordは**構造decode用**であり、liveセッション受理の正常例ではない。live正常fixtureは下記に従いMAC/seq/hashと合法payloadを作り、構造vectorと分けて保存する。

- 1–4: 同rules/map、別player/boot、既知nonce、未使用epochを用いた実handshake。5/6は認証後、双方Readyで開始。
- 10–12/20–26: round1 F（初回24/25はC）、HP100/Armor50、空inventoryまたは武器id1/rifle/mag24、ownerに一致するspawn情報、最新revisionと新規input/action/event ID。baseline hashはhash自身以外のbyteから計算。
- 30/31: 空matchからMatchCreated seq1/zero prevHash。次にPrepared seq2/Activated seq3。31は受信側で保存済みseq/hashだけ。
- 32–36: seq3の同prefix、oldEpoch1/newEpoch2、Hのみboot変更/G連続、remaining30000。35はclose/offender0、36は同baseHash。34.done=0は1record、done=1はrecord長0で最後seq/hash。
- 37/39: round128 CLOSEDのreducer stateを16 KiB以内で保存し、同seq/hashとblob SHA。31.ackKind=checkpoint1はそのcheckpointHash、record0ではcheckpointHash全0。
- 40/42: 10勝確定し双方Ready、AD2新match/secret・同host identity。41.reason=GRACEFUL_LEAVE2。
- 43–45: 同oldEpochの認証診断接続、request/notice一致、04のexpired/unresolvedとforfeitの両方を検査。50は現在の先手/後手だけで合法spawn/revision。

各live正常例の**一箇所だけ**を変更して、MAC誤り/別match/epoch replay/送信方向逆/許可phase外/未認証、未知type、予約bitを全typeに交差適用する（適用不可は理由を列記）。payload型ごとにfloat NaN/+Inf/-Inf、整数境界、count最大+1、UTF8不正、opaque blob破損/深さ13/キー追加/重複キーも生成。MACを再計算した形式違反と、MAC自体の破損を分ける。型を持たないmessageへのNaNはN/A。期待は03の拒否表、allocation上限超過0、状態hash/score不変。rateは閾値ちょうどと+1、2秒windowを跨ぐcase。packet lossは不正counterを増やさない。

## A14–A19 共通tickと両役の操作表

単体の時刻比較はFakeClockで999/1000 msを正確に区別。60 Hz実通信は開始tick T、59 tick=983.333 msでは未完了、60 tick=1000 msで完了。999 msを60 Hzのtick59と同一視しない。全caseで操作主体Host/Guestを反転、競合caseはround1/2で優先slotを反転する。

| case | Tからの操作/欠落注入 | 双方の期待 |
| --- | --- | --- |
| A14-hold | 2丁所持、床weapon id100/rev7。TでInteract、T+59で観測、T+60完了、T+61もhold、T+62 release、T+63再press | 59で変更0、60で交換1、61で再拾得0、drop弾倉保持。release後だけ次操作可 |
| A14-revision | 同targetへexpectedRevision=999、world revision=1000。次要求で1000 | 最初STALE_ITEM/変更0、次だけ成功。遅延rev999 eventで巻き戻し0 |
| A14-race | 両slotが同tick同item/同revへ要求、IDを各3回再送 | roundの優先slotだけ取得、後者STALE_ITEM/UNKNOWN_TARGET、消滅1/新drop1、二重所持0 |
| A14-cancel | 完了tick直前に視線逸脱/射程外/死亡/round変更、別々のrun | 交換0、元装備保持（死亡round resetは別検査）、両者revision一致 |
| A15-cap | reserve119/29/59から各ammo箱2取得 | 120/30/60、箱残量1、revision+1だけ。dup requestで増えない |
| A15-reload | mag0、reserve=必要数-1/必要数/必要数+1。開始T、規定duration tick-1/ちょうどで観測 | 完了前移動0、完了時min(不足,予備)だけ移動。取消は消費0、完了event重複で増殖0 |
| A16-duration | heal4種、HP/armorを50だけ不足。T開始、T+224/225、374/375、179/180、299/300で観測 | 225/375/180/300 tickで1消費と規定回復、前tick変更0 |
| A16-cancel | 各種×移動/被弾/死亡/Shift/ADS/既存slide/新規slide、完了と同tick競合も別run | 02の優先順で取消/継続を固定。既存slideは継続、新規slideは拒否、死亡は回復より先。cap4/2/4/2・合計12 |
| A16-wheel | 4短press/release、長hold後release、5–8直選択 | 短押し使用1、長押し選択だけ、選択と使用の二重要求0 |
| A17-input | G短/長→左press→release、releaseを3再送。Esc/武器変更はrelease前に別case | Gだけ消費0、左holdで軌道、releaseで1個、取消0。合計cap2、空在庫NO_STOCK |
| A18-fuse | throw T、149/150 tick、壁反射、capsule最短0/2/4 mと遮蔽、自分/相手 | T+149生存、150消滅1、100/50/0、遮蔽0、自傷半分、damage event重複0 |
| A19-fire | 床/壁初接触、下に床なし、上下階/壁、2field重複、expiry-1/expiry | 連続床だけ最大81セル、床なし削除、15tick毎8×20回/自傷4、1fieldで同tick二重hit0、expiryで消滅 |

欠落試験はproxyのUDP破棄に加え、debug transport hookで指定typeを1回送らないケースを別に持つ。reliableのUDP紛失はENet再送されるため「ゲームeventそのもの欠落」と混同しない。入力bundle1個欠落、ActionResult1個遅延、inventory event遅延、baseline fragment1個欠落をそれぞれ実行し、重複抑止/再送/assemble期限を観測する。

## A21 entityと予測の時系列

fixtureはround1 F、銃3種各1shot（散弾8）、frag1、incendiary1、pickup1交換。G視点とH視点のID/owner/生成tick/expiry/削除reasonを比較する。各entityについてnormal、補正先着200 ms、生成重複、削除後補正、event1個欠落500 ms、baseline cut前後入替、新roundに旧packet到着を実施する。

期待: rifle/pistol1本、shotgun8本が同ID/初速、生成1回、削除後再出現0、frag削除後damage、焼夷削除後flame、pickup同revision一致。baselineは全5配列を含みcut超eventを失わない。期限表示消去だけでdamageを作らない。reliable seq gapは要求1件に集約、1秒より高頻度に要求しない。3送信失敗後は有限停止。

予測fixture: 移動120 tick→100 ms input欠落、snapshot ACK遅延、ring257、壁横で0.2 m補正、開放空間0.2 m/1.0 m補正、round変更、baseline置換。proxyは即補正、0.2 mのcameraは100 msで0、1.0 m/壁/ring257は即snap＋baseline要求。再演算中のweapon/action/audio呼出回数0、消費0。相手補間6tick/外挿最大6tick、停止後速度表示が無限に進まない。

## A23–A28 fault matrixと期待prefix

run IDを`point.role.phase.recordType.occurrence`とし、下表を全展開する。rolesはHost/Guest、phasesはSelectingFirst/SelectingSecond/Countdown/Fighting/Resolving/Opening/RecoverySync/Checkpointing。存在しないhookを無理に発火させず、N/Aとその所有側/理由をmanifestへ出す。

| fault point | 適用するrecord/phase/側 | kill後のローカル有効prefix |
| --- | --- | --- |
| before_write / partial_write / after_flush | 全durable typeを保存する両側、実際の遷移phase。metadata/checkpointにも別case | record rename前は旧seq n、tmpは採用しない |
| after_rename | 同上 | hash正しい新seq n+1を採用、ACK未送信でも消さない |
| before_ack / after_ack | guestの各record保存、host/guestのcheckpoint ACK受信保存 | 新seq n+1。ACK受信側の記録有無も別観測 |
| before_round_activate | host、Opening、Prepared ACK後 | Preparedまで、未OPEN→keep/追加0 |
| after_round_activate | hostのActivated保存後、guestのActivated受信保存後 | 有効prefixにActivatedがあればOPEN→次roundのcloseを1回 |
| before_recovery_commit | host、RecoverySync、PreparedAck受信後 | 復帰未確定。元oldEpoch/remaining、再試行で同ID |
| after_recovery_commit | host/guest、それぞれRecoveryResolved保存後 | receipt/highwater保存済み、再試行は追加点0 |
| before_checkpoint_ack | guest保存後、host ACK確定前を別case | 元records保持、未confirmed候補＋旧confirmedから回復 |
| during_compaction | host/guest、Checkpointing、古record削除を1件した直後 | confirmed2世代＋旧floor以後suffix、同last seq/hashへ回復 |

メモリだけに生成されたrecordは期待prefixへ含めない。両者の最大有効**共通鎖**へ照合した後のOPEN/CLOSEDでペナルティを決める。例: 初期seq1 Created/2 Prepared/3 Activated、scores[0,0]。Fightingで片側kill→30秒後復帰、seq4 RecoveryResolved(close)、offender Hなら[0,1]、Gなら[1,0]、receipt1。同IDを3再送してseq/score不変。その後Prepared5/Activated6でround2へ。RoundClosed4が既に保存済み、Prepared5までならkeepで追加0。Activated6までならround2へのcloseで初めて追加1。死亡で9→10勝となった確定鎖では新roundも追加ペナルティもなし。

各faultは30秒再起動、失敗後に同oldEpochで3再試行、さらに旧timeout/旧ACKを送り、両者seq/hash/scores/round/highwater/receipt一致を検査。before_writeだから必ず両者旧seqとは限らない（相手の完全記録があれば回復する）。期待はmanifestに両側のrename済みrecord bytes/hashを記録し、製品reducerとは別の小さなprefix oracleで算出する。

期限はFakeClock完了59999/60000/60001 ms＋Realtime両役30秒/65秒。65秒では残存側の診断30秒窓で再認証して双方windowClosedへ。残存側も退出、双方再起動、双方blackhole、時計±2秒、sleep、片側の偽offender、履歴forkを独立caseにする。到達不能の再起動側は30秒予算終了でunknown＋戻る導線、勝利0/新猶予0。D08 pendingではunresolved、承認後専用fixtureだけaborted。未承認ビルドでabort有効をPASSにしない。

2000 drawはround数でcheckpoint128間隔、最新corruptで旧世代fallback、両corruptの停止、整理前/中/後のkill、oldEpoch<=highwater、seq<floorの再送を含む。memoryとファイル数をround256/1024/2000で観測し、draw count制限を導入せず保持上限を満たす。

## A29–A31 画面・音の観測手順

A29: 練習開始→rifle/HP100 Armor50の胴10発、初弾hit→致死hit 0.983–1.017秒をHUDと内部hit tickの双方で確認（距離の飛翔時間は初弾到着から測定）。全銃の頭/胴表示、静止/移動標的、致死後120tick respawn、reset/再抽選、退出を実操作。対戦scores保存が変わらない。

A30: 全settingsキーを既定値と異なる有効値へ→保存→プロセス再起動→UI表示/実動作一致。移動/発射をキー再割当して旧キー無効・新キー有効、競合キーの解消、Esc取消、必須操作未割当の保存拒否。感度は一定mouse deltaでyaw差、音量は各bus値と実聴、映像は変更後15秒未確認で旧設定へ。A/B片破損・両破損・旧schemaを別profileで検査しmatch hash不変。

A31: 1280×720/1920×1080それぞれ全画面、4回復ホイール、HUD最大桁、長い復帰文言、設定スクロール、結果を撮影。focus喪失→neutral/capture解除→復帰クリックだけでは発射数0→次のpressで1発。左右5 m/20 mの足音/銃声、遮蔽物、head/body/armor break、自音/相手音を録音して左右/距離減衰と重複0を確認。数値だけで実聴合格を代行しない。

## A32–A35 測定と配布

A32はRTT0/50/100/200 ms×loss0/1/5%の12条件、各30秒warmup＋300秒測定、seed1701/1702/1703、操作役を反転。片道delay=RTT/2、lossは方向ごと独立。duplicate1%/reorder1%（50 ms追加遅延）を加えた12条件も別run。一方向/双方向blackholeはt=120秒から3秒、60秒以上を別runにして通常走行とは分離。時計stalledケースは別suiteで250 ms停止を注入。

A33は配布release/1920×1080/medium、30秒warmup＋600秒。平均FPS=総frame/実経過秒、p95 frame timeはframe全標本をsortしてceil(.95*N)-1、メモリ差はwarmup末30秒中央値と終了前30秒中央値。平均60 FPS/p95<=20 ms/差<=50 MB、entity/voice上限を報告。2000round headlessのメモリは別結果。

A34は100 ms RTT/1% loss、同seed/scriptでH/G操作を反転、30秒warmup＋300秒。補正距離はsnapshot前予測位置とACK再演算後の差、camera表示誤差は別系列、input latencyは入力採取から対応位置/ShotFired初描画まで。p50/p95/maxをsample数付きで保存。平常帯域はMAC/fragment/ENet overheadを含むUDP送信bytesの1秒窓、方向別に平均/p95/max（目標各64 KiB/s以下）。handshake/復帰転送を平常値に混ぜず別報告。補正p95<0.5 m、未達は測定値と動画を残し勝手に目標を書き換えない。

測定ログはメモリring固定長＋1秒集計、flushは測定後。ログON/OFFの同条件control各1回でframe p95差<=1 msかつstall件数増加0を確認し、超過なら計測方式を修正して再測定する。書込失敗を成功扱いしない。

A35: 現行Windows Desktop presetはdebugでもtests/*を除外する。追加する専用`Windows Acceptance`はdebug feature＋tests含有、test-fault/IPCを有効にする。shippingのWindows Desktopはtests除外・release featureで全test引数を明示拒否、誤ってfault文字列だけ消して通さない。source、acceptance export、releaseの3経路で起動/引数拒否を別検査。空profileにZIP install→起動→uninstall→reinstall、manifest外ファイルとuser save保持、同梱hash照合を行う。配布物にNode/editor不要。

A36–A38は外部2家庭/利用者の実評価だけで判定する。設計資料・localhost・画面キャプチャだけで置き換えない。

A27補足: 同roundのkeep反復で1024record閾値へ達するcaseも作り、round数が増えなくてもcheckpointが進むことを確認する。checkpoint ACK欠落中は元recordsを残し、新Preparedを発行しない。
