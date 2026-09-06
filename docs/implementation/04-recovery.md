# 04 永続化・復帰・不一致

## 保証する性質と前提

片方のゲームプロセスだけが終了し、残存側が待機しており、60秒以内に同じhost endpointで認証・履歴照合を完了できる場合を主経路とする。ホスト役は移さない。戦闘位置/弾/炎を巻き戻して再開せず、そのラウンドを切断敗北として決着させる。

乱数seedやhashから通信断の責任を証明できるとはしない。第三者の権威サーバーなしに、両者停止・時計異常・相互不達を常に同じ勝敗へ自動収束させる保証は設けない。D08の例外へ送る。

## 確定イベントとreducer

Score以外の進行情報も保存し、「どのラウンドが始まったか」を曖昧にしない。

| event | 必須情報 | preconditionと結果 |
| --- | --- | --- |
| MatchCreated | identities, rulesHash, mapHash, initialEpoch | 空状態だけ。round=0, score=0, BETWEEN |
| RoundPrepared | nextRound, firstSlot, selectionSeed | BETWEEN、直前が10勝未満。候補roundを保持するが進行番号はまだ増やさない |
| RoundActivated | preparedRound | Preparedの両者保存ACK後にhostが発行。roundを増やしOPENにする |
| RoundClosed | round, winner, reason, closedTick | OPENかつ同roundだけ、加点最大1。10勝ならterminal |
| RecoveryResolved | recoveryId, oldEpoch, newEpoch, interruptedRound, disposition, offender, basedOnSeq/hash | 既処理epoch/IDならno-op。close/keep/forfeit/abortを1イベントで適用し、receiptも同時保存 |
| CheckpointInstalled | coveredSeq/hash, stateHash | 得点を変えない。compaction境界の通知 |

RecoveryResolved.disposition:

- `close`: 現在roundがOPENでoffenderが一意。1−offenderに1点、CLOSEDへ。10勝ならterminal。
- `keep`: 既存RoundClosedを優先して加点しない。未ActivatedのPreparedも破棄し、同じ次roundを準備し直す。
- `forfeit`: 期限切れかつ責任が一意。score不変、winner=1−offender、terminal reason=DISCONNECT_TIMEOUT。
- `abort`: D08が採用された責任不明、または回復不能な合意破損。score不変、winner=-1、terminal reasonを保存。

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
    receipts/<epoch>-<hash>.json
    terminal.json                 # 後日来た復帰を拒否するtombstone
```

durable recordは固定順binary: schema:u16、match16、rules32、seq:u64、prevHash32、eventType:u8、payloadLength:u32、typed payload、SHA256(prefix)32。文字列/整数のcodecは03と共通、浮動小数点を得点履歴へ入れない。レコード最大8 KiB。派生Stateを再計算して合法な遷移を確認する。

save手順は`<seq>.bin.tmp`へ全bytes→FileAccess.flush→close→read-backしてsize/hash検査→**存在しない**`<seq>.bin`へrename→再読込成功で保存完了。既存seqが同hashなら成功扱い、違うならHISTORY_FORK。Windowsの既存ファイル置換保証への依存を減らす。

各appendはメインthreadで直列化し、1seqにwriter1人。rename前のtmpは確定扱いしない。起動時は完結したrecordsだけを順に検証。途中に欠番/破損があればそれ以降を自動採用せずRecoverySyncへ。相手にも有効記録がなければ停止。

session/settings/observationの更新はA/B世代ファイルにgenerationとhashを付けて保存し、両方を読んで有効な最大generationを採用する。片方が壊れても旧世代を選ぶ。両方破損したらsecretを新規生成して旧matchを復元したふりをしない。

FileAccess.flushとrenameのGodot上の挙動はW03で再検証する。書込失敗はStorageErrorに入る。相手へ保存ACKを返さず、戦闘を続けない。停電・物理故障の完全保証は完成条件に含めないが、破損時に誤加点しないことは含める。

## 無制限の引き分けとcompaction

128ラウンドごとのBETWEENでcheckpointを作る。checkpoint stateにはscores、round、previousWinner、terminal、epochHighWater、lastRecoveryEpoch、lastSeq/hashを含む。closed済み古いroundや古いepochをrejectできるため、全receiptの無限保持は不要。

host checkpoint送信→guestが現在履歴から再計算し同state/hashを保存→ACKをhostが保存、の後だけログを整理する。直前/現在の2checkpointと直前checkpoint以降のrecordsを残す。ACK前の元recordsは消さない。整理中の終了もどちらか完全なcheckpoint＋連続suffixで復元する。

初版のセッションは同じ2参加者だけで60秒復帰のため、何時間も前のcheckpointしか持たない第三者参加を受け付ける必要はない。それでも相手が保持窓より古ければ勝手に最新Stateを信頼させずCHECKPOINT_TOO_OLDとして復元不可へ送る。データ量上限を理由に引き分け回数へゲーム上の上限を追加しない。

## 切断検知・期限の保存

heartbeat間隔500 ms、最後の認証済み受信から2000 ms、ENet disconnect、明示leave、ローカル250 ms以上の処理停止を切断の観測トリガーとする。観測した最初の時点を0秒とし、同じoldEpochの期限を延長しない。物理的なケーブル断時刻そのものを正確に測ったと主張しない。

Clockは`Time.get_ticks_usec()`とUTCを同時に記録する。稼働中のdeadlineはmono_start+60秒。wall clockは監視用で、monoとの差が2秒以上急変したらCLOCK_UNCERTAINとして通常勝敗決定を停止する。スリープ/長時間停止はresume時に経過差を検査し、猶予をリセットしない。

observationは開始時と1秒ごとにremaining_ceiling_msを下方更新する。再起動した側に同じ起動の単調時計はないため、自分のUTCだけで期限を延長しない。**残存側のoldEpoch観測を期限の判定者にする**。host再起動ならguestが判定者、guest再起動ならhostが判定者。

両者再起動はD08、片方の時計異常もD08。異なるPCのUTCを減算しない。双方稼働継続の通信断では各自remainingを計算し、小さいremainingを使うが、責任の確定は別表で行う。

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

1. Suspended中も0.5秒おきに同endpointへ接続を試みる。試行が失敗しても元期限は変えない。
2. 認証後にResumeHelloを交換する。terminal tombstoneがあれば旧matchへの再参加を拒否。
3. 既知checkpointとhashを照合し、共通prefixの長い方から不足履歴を送る。古い側へ戻すことはない。forkは即停止。
4. 最新履歴を両者が保存しDurableAckを交換。相手のACKは現在の試行epochに限る。
5. hostは旧接続の責任を表から導き、最新履歴からclose/keepを選びResumePreparedを送る。未Activatedの準備は破棄対象。
6. 残存側は期限内かを再確認し、recovery ID/baseHash/結果が一致した場合だけPreparedAck。判定者がhostならhost自身の時計でも送信/受信時に確認する。
7. hostがRecoveryResolvedを保存し配送。guestも保存し、判定者の時計で期限内にこの記録の保存が終わった時を「復帰完了」とする。60秒ちょうどは失敗。
8. final disk ACKが遅れても、保存済みRecoveryResolvedは取り消さない。未ACK側は再送して照合を続ける。**新しいペナルティや新しい60秒は作らない**。
9. 両者がRecoveryResolvedと新epochを確認後、10勝なら結果、それ以外は次RoundPreparedへ。

step7の直前で判定者が期限切れになった場合は、PreparedAckだけを成功証拠にしない。TIMEOUT観測を保存して操作開放を拒否する。hostが別の結果を保存済みで双方が食い違う場合はConflictとして停止する。通信断のまま最後のACKについて永久に合意できるとの保証を置かない。

残り2000 ms未満でもUIは復帰を試すが「間に合った」と先に表示しない。全手順が期限内に終わった場合だけ成功。59秒にプロセスを起動するだけで必ず復帰できる保証ではない。

## 期限切れ・終了記録

残存hostでguest責任が明確ならRecoveryResolved(forfeit)を保存して結果→接続画面。guestだけ残ってhostが戻らない場合、guestはホストのイベントを捏造せずlocal terminal.jsonに`HOST_UNAVAILABLE_AFTER_DEADLINE`を保存してローカル試合勝利を表示する。後日hostが戻ってもそのmatchを再開しない。

まだhost再起動などの証拠がなく経路断だけなら、残存していると各自が思っていても双方の勝利を表示しない。D08で中断結果にする。勝敗を一意に確定できたケースと、相手が永久に戻らず証拠が得られないケースを区別する。

終了記録にはmatch ID/最後のseq/hash/oldEpoch/理由のみ、戦闘worldなし。直近100試合を保持し、それ以前はmatch ID＋終了フラグだけの小さい拒否リストへ圧縮する。ユーザーがセーブ削除を明示するまで終了済みmatchを同IDで再利用しない。

## 必須の障害注入点

`--test-fault`はdebug/test exportだけで有効。before_write、partial_write、after_flush、after_rename、before_ack、after_ack、before_round_activate、after_round_activate、before_recovery_commit、after_recovery_commit、before_checkpoint_ack、during_compaction。releaseではコマンドを拒否。

各点でhost/guestを終了させ、再起動→照合→期待score/terminal/recovery receiptを検査する。Node試作17件に加え、製品の実時計・自動切断検知・保存期限でA23–A28を実施する。

## 公式仕様との対応

Godotのticksは起動からの単調時計で、system clockは手動変更されうる。[Time公式](https://docs.godotengine.org/en/stable/classes/class_time.html)。このため「保存したticksを別起動でそのまま差し引く」方式を採用しない。
