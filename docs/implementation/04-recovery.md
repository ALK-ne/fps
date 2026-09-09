# 04 永続化・復帰・不一致

承認状態更新（2026-09-09）: D08のabort-v1は利用者が明示承認済み。本章の「採用後」分岐を新規実装へ適用する。pendingの記載は旧ビルド・旧記録の扱いとして読む。旧記録を自動確定しない。[承認記録](08-decisions.md)参照。

## 保証する性質と前提

片方のゲームプロセスだけが終了し、残存側が待機しており、60秒以内に同じhost endpointで認証・履歴照合を完了できる場合を主経路とする。ホスト役は移さない。戦闘位置/弾/炎を巻き戻して再開せず、そのラウンドを切断敗北として決着させる。

乱数seedやhashから通信断の責任を証明できるとはしない。第三者の権威サーバーなしに、両者停止・時計異常・相互不達を常に同じ勝敗へ自動収束させる保証は設けない。D08の例外へ送る。

## 確定イベントとreducer

Score以外の進行情報も保存し、「どのラウンドが始まったか」を曖昧にしない。

| event | 必須情報 | preconditionと結果 |
| --- | --- | --- |
| MatchCreated | identities, rulesHash, mapHash, initialEpoch | 空状態だけ。round=0, score=0, BETWEEN |
| RoundPrepared | nextRound, firstSlot（抽選結果のみ） | BETWEEN、直前が10勝未満。候補roundを保持するが進行番号はまだ増やさない |
| RoundActivated | preparedRound | Preparedの両者保存ACK後にhostが発行。roundを増やしOPENにする |
| RoundClosed | round, winner, reason, closedTick | OPENかつ同roundだけ、加点最大1。10勝ならterminal |
| RecoveryResolved | recoveryId, oldEpoch, newEpoch, interruptedRound, disposition, offender, basedOnSeq/hash | 既処理epoch/IDならno-op。close/keep/forfeit/abortを1イベントで適用し、receiptも同時保存 |
| CheckpointInstalled | coveredSeq/hash, stateHash | 得点を変えない。compaction境界の通知 |

RecoveryResolved.disposition:

- `close`: 現在roundがOPENでoffenderが一意。1−offenderに1点、CLOSEDへ。10勝ならterminal。
- `keep`: 既存RoundClosedを優先して加点しない。未ActivatedのPreparedも破棄し、同じ次roundを準備し直す。
- `forfeit`: 期限切れかつ責任が一意。score不変、winner=1−offender、terminal reason=DISCONNECT_TIMEOUT。
- `abort`: D08が明示採用された責任不明。履歴forkはabortで隠さず停止。score不変、winner=-1、terminal reasonを保存。

復帰完了receiptを終端判定より先に同じイベント内で記録する。10勝になったのでreceiptが保存できず、後着要求で再実行するバグを防ぐ。oldEpoch以下の全packetを以後の接続から拒否する。

初稿の「ラウンド番号だけのペナルティID」は製品に流用しない。IDはSHA256(match ID || oldEpoch || "recovery")の先頭16 byte。同じ切断期間は最初のoldEpochで固定し、新しい接続試行epochを発行しても新ペナルティを作らない。

## 開始と決着の保存境界

通常決着→RoundClosed保存→guest保存ACK→RoundPrepared保存/ACK→RoundActivated保存/ACK→選択時計開始。

RoundClosed直後からRoundActivated前の切断では`keep`。したがって死亡で1点入った直後、まだ新ラウンドを正式に開始していないホストの再起動へ追加点を付けない。RoundActivatedが保存済みなら選択画面を相手がまだ描画していなくても新ラウンドとして扱う。これが二重得点を判定する明確な境界になる。

通信遅延中のOpening/Resolvingでは「同期中」。選択時間の10＋10＋3秒はSelectingFirstに入ったserver tickから計算し、Openingのdisk/通信待機を選択時計へ加算しない。ゲーム全体で追加の固定待ち時間を設けない。

## ファイル配置と正規化

```text
user://profiles/default/
  identity.json
  settings.json
  pending-invitation.json
  current-match.json
  matches/<matchhex>/
    session.json                  # endpoint/secret/identities、外へ共有しない
    records/0000000000000001.bin   # append-only、既存を上書きしない
    records/0000000000000002.bin
    checkpoints/<seq>.bin
    observations/<old-epoch>.json
    receipts/                      # schema1残存のみ、新規作成しない
    terminal.json                 # 後日来た復帰を拒否するtombstone
```

durable recordは固定順binary: schema:u16、match16、rules32、seq:u64、prevHash32、eventType:u8、payloadLength:u32、保存専用canonical payload（後述schema 2）、SHA256(prefix)32。外枠の整数は03と共通、payloadは保存canonicalの型tag付き表現。浮動小数点を得点履歴へ入れない。レコード最大8 KiB。派生Stateを再計算して合法な遷移を確認する。

save手順は`<seq>.bin.tmp`へ全bytes→FileAccess.flush→close→read-backしてsize/hash検査→**存在しない**`<seq>.bin`へrename→再読込成功で保存完了。既存seqが同hashなら成功扱い、違うならHISTORY_FORK。Windowsの既存ファイル置換保証への依存を減らす。

各appendはメインthreadで直列化し、1seqにwriter1人。rename前のtmpは確定扱いしない。起動時は完結したrecordsだけを順に検証。途中に欠番/破損があればそれ以降を自動採用せずRecoverySyncへ。相手にも有効記録がなければ停止。

session/settings/observationの更新はA/B世代ファイルにgenerationとhashを付けて保存し、両方を読んで有効な最大generationを採用する。片方が壊れても旧世代を選ぶ。両方破損したらsecretを新規生成して旧matchを復元したふりをしない。

FileAccess.flushとrenameのGodot上の挙動はW03で再検証する。書込失敗はStorageErrorに入る。相手へ保存ACKを返さず、戦闘を続けない。停電・物理故障の完全保証は完成条件に含めないが、破損時に誤加点しないことは含める。

## 無制限の引き分けとcompaction

128 CLOSEDラウンドまたは1024recordの早い方のBETWEEN/CLOSEDでcheckpointを作る（詳細は後述）。checkpoint stateにはscores、round、previousWinner、terminal、epochHighWater、lastRecoveryEpoch、lastSeq/hashを含む。closed済み古いroundや古いepochをrejectできるため、全receiptの無限保持は不要。

host checkpoint送信→guestが現在履歴から再計算し同state/hashを保存→ACKをhostが保存、の後だけログを整理する。直前/現在の2checkpointと直前checkpoint以降のrecordsを残す。ACK前の元recordsは消さない。整理中の終了もどちらか完全なcheckpoint＋連続suffixで復元する。

初版のセッションは同じ2参加者だけで60秒復帰のため、何時間も前のcheckpointしか持たない第三者参加を受け付ける必要はない。それでも相手が保持窓より古ければ勝手に最新Stateを信頼させずCHECKPOINT_TOO_OLDとして復元不可へ送る。データ量上限を理由に引き分け回数へゲーム上の上限を追加しない。

## 切断検知・期限の保存

heartbeat間隔500 ms、最後の認証済み受信から2000 ms、ENet disconnect、明示leave、ローカル250 ms以上の処理停止を切断の観測トリガーとする。観測した最初の時点を0秒とし、同じoldEpochの期限を延長しない。物理的なケーブル断時刻そのものを正確に測ったと主張しない。

Clockは`Time.get_ticks_usec()`とUTCを同時に記録する。稼働中のdeadlineはmono_start+60秒。wall clockは監視用で、monoとの差が2秒以上急変したらCLOCK_UNCERTAINとして通常勝敗決定を停止する。スリープ/長時間停止はresume時に経過差を検査し、猶予をリセットしない。

observationは開始時と1秒ごとにremaining_ceiling_msを下方更新する。再起動した側に同じ起動の単調時計はないため、自分のUTCだけで期限を延長しない。**残存側のoldEpoch観測を期限の判定者にする**。host再起動ならguestが判定者、guest再起動ならhostが判定者。

両者再起動はD08、片方の時計異常は期限権威を失うため後述のuncertainへ。異なるPCのUTCを減算しない。双方稼働継続の通信断では各自remainingを計算し、小さいremainingを使うが、責任の確定は別表で行う。

## 責任判定の決定表

証拠は認証したResumeHelloと保存済み前bootの差分から作る。相手が勝手に申告するoffenderを受け取らない。

| host boot変更 | guest boot変更 | 明示証拠 | outcome |
| --- | --- | --- | --- |
| true | false | guestが同oldEpochで連続待機 | hostのラウンド敗北 |
| false | true | hostが同oldEpochで連続待機 | guestのラウンド敗北 |
| false | false | 一方だけ認証済みGracefulLeave | そのslotのラウンド敗北 |
| false | false | 一方のアプリが検出し保存したlocal停滞、双方がその証拠に一致 | そのslotのラウンド敗北 |
| true | true | 任意 | 責任不明、D08 |
| false | false | heartbeat不達だけ、または両者とも停滞 | 責任不明、D08 |
| 任意 | 任意 | 履歴fork、他player、版不一致 | 復元拒否。新しいscoreを作らない |

再起動しない片側Wi-Fi切断は両者から見た相互不達になりうる。「普通の切断だからguest敗北」と推測しない。誰の責任か不明なケースを片側切断成功の試験へ混ぜない。

## Resumeの全手順

1. Suspended中の試行は後述の有限予算に従う。失敗しても元期限は変えない。
2. 認証後にResumeHelloを交換する。終了記録があれば旧matchへのgameplay再参加を拒否し、診断経路へ分岐。
3. 既知checkpointとhashを照合し、共通prefixの長い方から不足履歴を送る。古い側へ戻すことはない。forkは即停止。
4. 最新履歴を両者が保存しDurableAckを交換。相手のACKは現在の試行epochに限る。
5. hostは旧接続の責任を表から導き、最新履歴からclose/keepを選びResumePreparedを送る。未Activatedの準備は破棄対象。
6. 残存側は期限内かを再確認し、recovery ID/baseHash/結果が一致した場合だけPreparedAck。判定者がhostならhost自身の時計でも送信/受信時に確認する。
7. hostがRecoveryResolvedを保存し配送。guestも保存し、判定者の時計で期限内にこの記録の保存が終わった時を「復帰完了」とする。60秒ちょうどは失敗。
8. final disk ACKが遅れても、保存済みRecoveryResolvedは取り消さない。未ACK側は再送して照合を続ける。**新しいペナルティや新しい60秒は作らない**。
9. 両者がRecoveryResolvedと新epochを確認後、10勝なら結果、それ以外は次RoundPreparedへ。

step7の直前で判定者が期限切れになった場合は、PreparedAckだけを成功証拠にしない。TIMEOUT観測を保存して操作開放を拒否する。hostが別の結果を保存済みで双方が食い違う場合はConflictとして停止する。通信断のまま最後のACKについて永久に合意できるとの保証を置かない。

残り2000 ms未満でもUIは復帰を試すが「間に合った」と先に表示しない。全手順が期限内に終わった場合だけ成功。59秒にプロセスを起動するだけで必ず復帰できる保証ではない。

## 復帰判定と診断状態（v1.1）

戦闘phase、再開を止めるinterlock、期限証拠、勝敗を別々に保存する。`Conflict`に全失敗を集約しない。TimerStatus=unknown0/running1/expired2/uncertain3、ResumeBlock=none0/windowClosed1/policyPending2/historyConflict3/storeError4/legacySchema5/uncertain6、ResultStatus=unresolved0/forfeit1/aborted2/tenWins3。03のStatusReplyと同じ値を使う。期限超過だけでは勝者は決まらない。

期限の権威は「旧epochから同bootで連続観測し、時計異常がないプロセス」。再起動側のremainingMsは`0xffffffff`（unknown）、continuous=0。保存remainingやUTCから60000を作り直さない。連続側は0..60000かつ保存ceiling以下、期限ちょうどでexpired。remaining unknownをmin計算へ入れず、有効な連続側がなければ通常復帰を開始しない。CLOCK_UNCERTAINは別bootと同様に期限決定の資格を失う。

| 証拠 | 保存する状態 | 認証後応答 | 画面文言・操作 |
| --- | --- | --- | --- |
| 片側だけboot変更、他方が連続観測、remaining>0、同一履歴 | observation + 従来RecoveryResolved close/keep | ResumeHello→履歴照合→Prepared/ACK→record | 「復帰処理中 残り…秒」。戻るで操作を止められるが元期限は保持 |
| 連続側のdeadline到達、責任証拠あり | windowClosed/expired/forfeit、winner=1-offender、証拠 | StatusReply。hostはforfeit record、guestはlocal certificate | 「復帰期限が過ぎました。切断による試合終了」。結果/接続へ戻る |
| 連続側のdeadline到達、責任証拠なし | windowClosed/expired/unresolved、winner=-1、D08 pending | StatusReply（勝者なし、未確定） | 「復帰期限が過ぎました。勝敗は未確定です」。記録保持/接続へ戻る/状態を確認 |
| 自分に有効な終了記録 | 既存interlock/resultを保持 | 認証だけ許しStatusReply、gameplay拒否 | 保存理由に対応した終了/未確定表示 |
| 相手に有効な終了記録、再認証で取得 | remote noticeをhash付き保存、gameplay禁止。履歴不一致ならhistoryConflict | StatusAckは保存後だけ | 証拠と整合した終了/未確定表示。到達しただけで勝者申告を信用しない |
| 再起動側で相手へ到達できない、終了記録なし | unknown/none/unresolved + 診断待ち。再開許可はfalse | 試行終了後に送信停止 | 「相手に確認できず、再開できません」。再確認/接続へ戻る。期限超過/勝利と表示しない |
| 両者boot変更、または双方の期限権威なし | unknown/policyPending/unresolved（時計異常ならuncertain/uncertain） | StatusReply、Prepared拒否 | 「復帰条件を確認できないため停止しています。勝敗は未確定です」。記録保持/接続へ戻る |
| 同seq別hash、identity不一致、矛盾する確定終了 | historyConflict/unresolved、双方証拠保持 | StatusReply、記録上書きなし | 「保存履歴が一致しないため再開できません」。記録の場所/接続へ戻る |
| 保存失敗/両世代破損 | storeError/unresolved | 保存ACKを返さず、可能なら診断応答 | 「記録を保存・読み込みできません」。再試行/接続へ戻る |

責任証拠は、旧両bootを照合した一方だけのboot変更＋相手の連続観測、認証済み一方のGracefulLeave、または双方が一致した一方のlocal stall。SILENCE/ENet disconnect/相手が帰ってこない事実だけではoffenderを確定しない。GracefulLeave受信をENET_DISCONNECTへ潰さない。双方の矛盾した自己申告も証拠にしない。MACはこのmatchの通信相手との照合であり、悪意ある当事者に対する第三者証明ではない。

guestだけ残った場合も、責任証拠と自身の有効deadlineがそろって初めてlocal forfeit certificateを保存できる。hostのDurableRecordをguestが代筆しない。証拠なしならwindowClosed/unresolved。後日hostが戻ったときboot差分で責任証拠を得られ、保存された連続観測の期限超過と整合する場合は同oldEpochのcertificateを確定させる。過去のscoreは変えず試合winnerだけを確定する。既存のRecoveryResolved成功と衝突したら自動上書きせずhistoryConflict。

## 終了通知を取得する通信経路と有限の退出

復帰ブロックのあるmatchでも、保存済みsecret/identityを使う診断専用handshakeは受け付ける。_bindは「新規試合」「通常resume候補」「診断のみ」に分岐する。診断では5/32/41/43/44/45だけ許可し、入力・Ready・Prepared・worldを一切受理しない。新epochを保存してから使い、oldEpochは切断単位のまま固定する。

StatusRequestはrequestId/oldEpoch/最後のseq/hash。StatusReplyは同requestId、noticeId、oldEpoch、observerBoot、最後のseq/hash、round、timer/block/result/winner、evidence bitmask、offender、保存observationのSHA256。証拠bitはcontinuous1,peerBootChanged2,gracefulLeave4,agreedStall8,deadlineElapsed16,durableTerminal32,authenticatedNotice64。未定義bit拒否。winner!=-1を受理するにはforfeitなら責任とdeadline証拠、tenWinsなら保存済み履歴の10勝、abortedならD08承認が必要。hashだけを完全な証拠とせず、ResumeHelloの旧boot照合とローカル保存履歴・通知内容の整合も検査する。通知はnoticeId=SHA256(match||oldEpoch||result||observationHash)先頭16byte。再送は同ID、StatusAckは同notice/epochを永続化した後だけ返す。

連続側は元60秒まで通常復帰を待つ。expired移行時に保存し、さらに30秒間だけ背景で診断を継続（Hはlisten、Gは保存endpointへ500 ms間隔で接続）。画面の「接続へ戻る」はいつでも利用可で、背景診断を待つ必要なし。同じmatchの終了記録を消さない。プロセスを閉じれば背景も停止する。

再起動側/手動「状態を確認」は1接続8秒、失敗間隔500 ms、操作1回あたり合計30秒で打ち切る。既にexpiredの対戦を通常復帰へ戻さない。30秒は画面の試行予算であり60秒の代替ではない。未達なら上表のunknown表示へ必ず遷移。自動で30秒試行を無限に開始しない。再確認操作は診断だけを再試行し、元observation/oldEpoch/ceilingを更新しない。

65秒後H再起動の再現: Gが約2秒で観測→約62秒でexpired保存→92秒まで診断outbound→65秒でHがlistenし再認証→GのStatusReplyをHが保存→両者操作禁止・同じ終了可否表示。Gも既に終了していた/診断窓を過ぎていたケースはHが30秒でunknownへ移る。相手の不在から勝利を作らない。G再起動も役を逆にして同じ終端を検査する。

## D08：未承認時と採用後

現時点はpolicy=`pending`を固定し、利用者設定で変えられない。責任不明はgameplayを止め、winner=-1/score不変、observationとinterlockを保持する。`unresolved`であり試合が正式abortになったとは保存しない。共通期限権威が残り、新たな認証証拠で責任を一意に解決でき、元期限内なら通常resumeへ戻せる。windowClosed/時計不明/双方restartのブロックを新しい接続だけで解除しない。

利用者が「責任不明は勝者なし・得点不変で試合中断」を明示承認した場合だけpolicy=`abort-v1`をビルド定数・rules hashへ反映する。共通prefixに合意できる場合はhostがRecoveryResolved(abort)、双方保存ACK、winner=-1/score不変/result=aborted、接続へ戻る/新matchの再戦。到達不能なら各側のlocal abort certificateだけで旧matchを閉じ、host履歴の偽造や合意済み表示はしない。履歴forkはabortで隠さずhistoryConflictのまま。採用前に作られたpending記録を自動移行して勝敗を確定しない。

必要な利用者判断は上記例外を採用するかの1点。通常の片側再起動、通信codec、有限退出、診断・保存・試験の実装を待たせない。

## 保存schema 2と保持の実装契約

現行schema1のrecord payload/checkpoint/A-BはCanonicalCodec形式である。v2はrecord外枠を維持してschema=2、payloadは以下の固定キーだけを許すcanonical value（キー順はCanonicalCodecのソート、整数64bit、float禁止）。ネット側はopaque長付きblobとして運び、保存専用validatorで余分/不足キー・型・値・hash・遷移を検査する。世界状態/任意objectをdeserializeしない。

| DurableType | payloadの固定キー（実装のsnake_case） |
| --- | --- |
| MatchCreated | players（16byte×2）, map_hash（32byte）, initial_epoch（u32）。match/rulesは外枠 |
| RoundPrepared | round（u32）, first_slot（0/1）。seedを共有/保存しない。host抽選済みの結果をreducerにも保持 |
| RoundActivated | round（prepared_roundと一致） |
| RoundClosed | round, winner（-1/0/1）, reason（death0/draw1/time2）, closed_tick（u64） |
| RecoveryResolved | recovery_id（16byte）, old_epoch, new_epoch, interrupted_round, disposition（03 enum）, offender（-1/0/1）, base_seq（u64）, base_hash（32byte） |
| CheckpointInstalled | covered_seq（u64）, covered_hash（32byte）, state_hash（32byte）。checkpoint保存ACKの代替ではない |

checkpointはschema2/stateのcanonical bytes＋SHA256、最大16 KiB。stateはmatch_id,rules_hash,map_hash,players,round,prepared_round,first_slot,scores[2],round_status,previous_winner,match_winner,terminal_reason,last_seq,last_hash,epoch_highwater,last_recovery_epoch,recovery_receipts（最新1 ID→true）。型は上記と同じ、round_status=BETWEEN0/PREPARED1/OPEN2/CLOSED3、terminal_reason=none0/tenWins1/disconnectTimeout2/abort3。phaseは保存しない（起動時RecoverySyncへ）。スコア0..10、first_slot0/1、winner-1/0/1、ID/hashは固定幅。covered seq/hashはstate lastと一致しreducerから再計算する。

| ファイル群 | schema/世代・上限 | 削除・破損時 |
| --- | --- | --- |
| identity/settings/current-match/pending-invitation | envelope schema2,generation:u64,value,hash。A/B各1、各64 KiB以下 | 最大の有効generation。identity両破損は旧match拒否、settingsは05のdefault。current/pending各1matchのみ |
| matches/id/session | 同A/B。match,rules,map,protocol2,storeSchema2,secret,endpoint,players,old_boots,epoch_highwater | epochを発行前保存。active1＋詳細終了100件に限る |
| records/seq.bin | schema2、8 KiB以下、immutable、hash鎖 | .tmpは非確定。存在済みseq別hashはfork。rename済み完全記録だけ採用 |
| checkpoints/seq.bin + seq.ack | checkpoint2、confirmed2世代＋未ACK候補1、ACKはseq/hash/checkpointHashを含む | hostがguest ACKを保存→39送信→guestが確認保存した後それぞれ整理。古い方以後のsuffixを残す |
| observations/oldEpoch.a/b | schema2、各64 KiB。旧boot2つ、観測者boot、cause、startMono/UTC、ceiling、timer、evidence、offender | active1＋直近解決済み2 epoch。monoは同boot内だけ。残りはreceipt highwater確認後削除 |
| terminal.a/b（互換名terminal.json.a/bでも可） | schema2、各64 KiB。match,seq/hash,oldEpoch,timer,block,result,winner,offender,evidence,observationHash,noticeId,policy | 勝敗と禁止理由を分離。片世代fallback、両破損はstoreError。新secretで再開しない |
| receipts | 新規独立ファイルは作らない。現行reducerも既に最新1件に制限 | checkpoint/state内のlast_recovery_epoch＋最新receiptで十分。既存未参照ファイルは移行時archiveへ |
| closed-index | schema2、match ID＋block/resultを4096件/segment、各hash付きimmutable、manifest A/B | 詳細終了100件より古いsecret/recordsを削除する前にindex保存。照会はsegment単位、RAM最大1segment |

同じrecordをappend_transactionで連続保存しても複数recordの原子性はない。1recordごとにACKし、RoundPrepared/Activated境界で有効prefixからreducerを再実行する。checkpointは128個のCLOSED roundごと（引き分けも含む）、古いconfirmed checkpoint以後の最大256 round分のsuffix＋進行中1 roundを保持する。checkpoint ACK待ちでは新round開始を保留し無限に未整理suffixを増やさない。最新候補が壊れていれば旧confirmed＋連続suffixで同stateへ復元する。

compact済みseq以下の重複recordを存在しないファイルとの比較でHISTORY_FORKにしない。seq==checkpoint floorならhash一致でCOVERED、seq<floorはSTALE_HISTORYとして副作用0、必要なsuffixを要求する。古いRecoveryResolvedはreducerのterminal判定より先にoldEpoch<=lastRecoveryEpochでno-op。floor以前を最新stateへ盲目的に上書きしない。共通checkpointを示せなければCHECKPOINT_TOO_OLD、gameplay停止。

終了IDの正確な永久拒否を、有限ディスクで無制限件数に対して保証することはできない。closed-indexの総ディスクは試合数に比例するがRAMと各ファイルは有界。空き不足では新試合を開始せずStorageErrorにする。引き分け回数のゲーム上限、誤判定を持つBloom filter、古いID再利用は導入しない。詳細が消えた旧IDは再開拒否だけ可能で、認証した過去勝者の通知はできない。

既存schema1は読み取り専用で保持し、自動でschema2のhash鎖へ書き換えない。未完了試合はLEGACY_SCHEMAで再開不可・得点表示は旧readerの検証済み履歴のみ。「旧版の記録です。新しい試合を開始してください」。新matchは別ID/schema2へ。設定/identityはキー検証後に元A/Bを残してschema2へコピー可、secret/未完了勝敗は推測移行しない。prototype/main製品の保存先混用を避ける。

保存canonical整数はsigned64のため、u64表記も0..2^63-1に制限する。schema2 envelopeのhashはhash自身を除くcanonical bytesのSHA256を末尾32byteとして保持する。active/pending/terminalのvalueは表の固定キーのみ。旧終端詳細の削除はclosed-index read-back成功後だけで、cleanupは再実行可能にする。

復帰keepを何度も挟む場合のrecord数上限も必要なため、checkpoint条件は「128 CLOSED round」または「前confirmed以後1024 record」の早い方とする。1024に達したら次のCLOSED/BETWEENでcheckpointを確認するまで新Preparedを発行しない。2世代suffixは最大2048 record＋現在の遷移最大4record、ACK待ちで新規recordを増やさない。引き分けの回数を制限するものではない。試験に同roundのkeep反復を追加する。

checkpoint/stateのreceiptキーはrecovery_idの小文字hex32、最大1件。sessionはold_host_boot/old_guest_boot、profile identityはplayer_id（16byte）、current-matchはmatch_id（16byte）、pending-invitationはmatch_id/secret（32byte）/host（UTF8最大253byte）/port（1..65535）/rules_hash/map_hash/protocolの固定キー。settingsのvalueは05の既定キーだけを許す。observationの固定キーはold_epoch/round/observer_boot/old_host_boot/old_guest_boot/cause/start_mono_us/start_utc_ms/remaining_ceiling_ms/timer_status/evidence/offender。未知期限のceilingはunknown sentinel、monoはobserver_boot一致時だけ使用する。terminalのキー表記はmatch_id/seq/hash/old_epoch/timer_status/resume_block/result_status/winner/offender/evidence/observation_hash/notice_id/policyに統一し、summary等の任意文字列を勝敗判定に使わない。
