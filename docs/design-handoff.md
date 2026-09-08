# 残設計の洗い出し・別セッションへの引き継ぎ

作成: 2026-09-08。確認した実装HEAD: `0d4f58a`（製品コード `fa312fc`）。
この文書は設計課題の一覧であり、提案の採用・実装完了・受入合格を意味しない。

## 最初に読む文書

- [既存設計の入口](implementation/README.md): 01–08、spec.json、arena.jsonが実装仕様。
- [通信設計](implementation/03-protocol.md): 認証、チャネル、wire形式、entity同期、予測。
- [保存・復帰設計](implementation/04-recovery.md): 期限、責任判定、保存ACK、終了記録。
- [決定事項](implementation/08-decisions.md): D01–D11。D08だけは利用者回答未取得・未承認。
- [受入仕様](implementation/07-acceptance.md)、[実行記録](acceptance-run.md)、[実装状況](implementation-status.md)。未完了と未検証を混同しない。

基本設計が存在しないわけではない。前セッションの「設計が必要」という説明は広すぎた。
多くは既存設計への実装追従であり、以下は実装前に不整合を解消するか、具体化すべき部分。
優先度P0は関連実装より先、P1は当該受入を完了するまでに決める。

## S01 P0: entity同期のイベント契約を一本化する

関連: W08、A21/A32/A34、03「payloadの固定定義」「列挙値と入れ子データの固定」。
コード: `game/net/session.gd`、`replication.gd`、`game/simulation/weapon_system.gd`、`grenade_system.gd`、`game/presentation/world_view.gd`。

既定方針はホスト権威、reliableの生成/変更イベント、非確実の弾位置補正、未知ID時のbaseline要求。再設計は不要。
現実装は20Hzのplayer snapshotに加え、inventory revision・投擲/炎の個数変化、および投擲/炎がある間の約2Hzでworld全体を送る暫定経路。
「entityは一切同期されない」ではないが、設計通りの個別イベント・移動補正にはなっていない。

設計書の具体的な不足・不整合:

- ProjectileWireの説明は`SpawnProjectile`でspawn/expiry/shot IDを初回送信とするが、GameEventTypeは8種類でSpawnProjectileがない。
- ShotFiredだけから散弾8本のID・初速・期限を復元するのか、生成イベントへ全弾情報を載せるのか未統一。
- WorldBaselineのメッセージ表はprojectilesを省略し、後段の構造説明は含めている。
- FlameCreated/GrenadeThrownはあるが、投擲・炎の削除をどのtypeで表すか、期限と接触消滅の対応を明文化する必要がある。

決めること:

1. 各entityの生成・更新・削除・期限のtype/byte列/所有者/ID範囲を確定する。
2. 別チャネルの先着補正、重複生成、削除後の遅延更新、round変更を処理する受信状態表を作る。
3. baseline要求の重複抑制・頻度上限と、受信済みeventとの前後関係を決める。
4. 飛翔物の表示側積分・補間と、権威damageを分離する。予測を採用する範囲も明記する。

成果物: 03の矛盾のないwire表と時系列図、S02と共通のversion方針、A21の実通信テスト仕様。
完了条件: 全3銃・散弾・フラグ・焼夷・拾得の生成から消滅まで、遅延/重複/順序入替/round跨ぎの期待値が定義される。

## S02 P0: wire仕様・実装の対応表と互換性を確定する

関連: W02/W08、A03/A20。コード: `game/net/session.gd`、`packet_codec.gd`、`snapshot_codec.gd`、`replication.gd`、`game/core/canonical_codec.gd`。

既定方針はlittle endianのtyped binary、有限float、個数上限、MAC、認証したpeerからslotを決定。
現実装は固定snapshotと共通packetに加え、多くの制御payloadが汎用canonical Dictionary。設計表と同一ではない。
例: ActionRequestがInputFrame型のactions配列を送り、GameEventが自由なevents配列を送る。コードにはtype39の送信もあるが03のメッセージ表にない。

決めること:

1. 全messageについて仕様type・実装送受信箇所・channel・方向・許可phase・認証段階・payload上限を対応付ける。
2. S01の追加/変更eventを反映し、未定義typeをなくす。既存文書はenum追加時にprotocol version更新を要求している。
3. 旧0.1.0ビルドとの接続拒否方法、protocol version、保存データのschema/hashを別々に扱う移行方針を記載する。
4. parserでの拒否、操作単位のActionResult、接続切断の境界を表にする。不正payload一件を即敗北へ変換しない。
5. ActionResultのactionIdと、STALE_ITEMなど現在の内部eventを対応させる。内部表現をそのままwire enumへ追加しない。

成果物: 完全な対応表、byteレイアウト、各messageの正常/異常golden vector、互換性判断。
完了条件: 配列確保前の上限検査、NaN/Infinity、未知enum、余剰/不足byte、送信者/phase違反、rate制限の期待結果を定義。
認証方式を新規考案する課題ではなく、既定の方式を全経路へ適用する課題。

## S03 P0: 期限終了・到達不能・勝敗の状態を区別する

関連: W09/W10、A25/A28。コード: `game/net/session.gd`のresume/`_stop_conflict`、`game/recovery/recovery_coordinator.gd`、`recovery_store.gd`、`game/ui/duel_ui.gd`。

確認済み: guestを残してhostを65秒後に再起動する試験では、guestはtombstoneを保存して再開を拒否する。
再起動hostは相手へ到達できずSuspendedの待機表示が残る。逆役の試験では終了通知を受けて両者停止する。

設計上の注意:

- 04は再起動側のUTCだけで復帰期限を延長せず、残存側を期限判定者にする。保存ticksを別起動で引いてはいけない。
- したがって前セッションの「保存期限だけで再開不可を確定できる」という説明は条件不足。ローカルtombstoneがある場合と、期限の確かな証拠がない場合を分ける必要がある。
- 04の「guestだけ残りhostが戻らない場合はローカル勝利」と、その直後の「経路断だけなら双方勝利を表示しない」は、適用に必要な証拠を明示しないと実装が分岐する。

決めること:

1. 自分/相手の終了記録あり、残存判定者との再認証成功、判定者に到達不能、双方再起動、時計異常の状態表を作る。
2. 「期限超過を確認」「再開可否を確認できない」「保存不整合」「責任確定済みの終了」をUI・保存理由で区別する。
3. 到達不能時の再試行終了と接続画面へ戻る操作を定義する。接続の試行時間を勝敗判定の60秒に置き換えない。
4. 終了通知を認証して取得する経路と、取得できなくてもゲームを再開しない条件を決める。再接続で新しい猶予や二重ペナルティを作らない。
5. 誰の責任か明確なforfeitとD08の中断を分離する。

成果物: 証拠→保存状態→通信応答→画面文言→可能な操作の表、A25/A28の両役テスト仕様。
完了条件: 相手から応答がないことを勝利・期限確定の証拠にせず、待機表示が終わらないケースにも退出導線がある。

## S04 P0（方針判断）: D08の責任不明切断

関連: 04「責任判定の決定表」、08「D08の扱い」、A28。
未承認の提案: 勝者なし・得点不変で試合中断し、終了記録を保持する。
現状: Conflict/Suspendedで停止し、得点を操作せず証拠を保持する。ユーザーの「続けて」や今回の設計依頼は提案への承認ではない。

設計担当は、提案採用時のabortと、未確定のまま停止する場合の保存・画面・再接続条件を具体化する。
利用者のルール判断が必要な点を一つに整理する。片側再起動が明確な通常復帰は従来どおり切断側敗北であり、削除しない。
S01/S02および既定条件の実装はこの判断を待つ必要がない。

## S05 P1: 保存データの上限と仕様差分を整理する

関連: W03/W09、A04–A06/A26/A27。コード: `game/recovery/recovery_store.gd`、`checkpoint.gd`、`game/domain/match_state.gd`、`round_director.gd`。

既定方針は128roundごとのcheckpoint、双方ACK後だけ整理、2世代保持。2000drawと最新checkpoint破損時の復元は検証済み。
追加確認が必要な設計差分:

- 04のRoundPrepared必須情報にselectionSeedがあるが、実装は共有payloadからseedを除外しfirst_slotを保存している。共有不要な乱数を漏らさず、再生に必要な情報を定義して文書を揃える。
- 04は古いrecovery receiptの無限保持不要とする。実際のreceipt/epoch整理を監査し、保持数と古い要求拒否の不変条件を具体化する。無限増加を確認済みと扱わない。
- 終了記録100試合＋古いmatchの拒否リスト、旧データとの互換性について実装との差を確認する。

成果物: 各保存ファイルのschema・世代・上限・削除条件、旧データ読み込み方針、hash対象の定義。
完了条件: receiptを整理しても重複加点しないことを証明できるテスト条件がある。ゲームの引き分け回数へ上限を追加しない。

## S06 P1: 予測・表示補正の未追従箇所を具体化する

関連: W08、A21/A34。コード: `game/client/prediction.gd`、`remote_interpolation.gd`、`game/net/session.gd`、`game/presentation/world_view.gd`。

既定値は入力ring256、相手100ms補間/最大100ms外挿、cameraの補正100ms、1m以上/壁貫通/ring溢れは即補正とbaseline要求。
移動再演算と相手補間はあるが、これら全条件の実装追従・受入は未完。
新しい遅延方式を選び直す必要はない。physics位置とcamera offsetの責務、補正の閾値判定、baseline要求との接続を実装箇所単位で整理する。
S01の予測shot/反動のIDと連携し、再演算時に音・弾・消費を二重実行しない条件を明記する。

成果物: 権威受信→再演算→衝突更新→camera表示の順序と、各異常時のテスト表。

## S07 P1: 未実施の受入を実行可能なテスト仕様へ分解する

ゲームルールの新規設計ではなく、試験ハーネスの設計。既存02/05/06/07の期待値を使う。

| 対象 | 追加する試験仕様 |
| --- | --- |
| A14–A19 | 両役の操作時刻、入力欠落、対象revision、999/1000ms等の境界、両端末の在庫/HP/entity一致。ローカル35検査の合格を通信受入へ流用しない |
| A23–A28 | 04に列挙された全保存fault点×host/guest×選択/Countdown/Fighting等の適用phase。開始状態、kill点、restart条件、期待seq/hash/score/receiptを表にする |
| A29–A31 | 練習TTK、設定保存/映像rollback、キー再割当/focus、2解像度、音の定位などの観測方法 |
| A32–A34 | 既定のネットワーク行列・継続時間・性能目標に対する測定区間、ウォームアップ、集計方法、ログ量。試験自体のI/O停滞をゲーム性能と混同しない |
| A35 | releaseの全起動/配布条件、debug専用fault harnessの実行方法。現在のdebug exportからtestsが除外される点も要確認 |

成果物: 既存acceptance IDに紐づく具体的なケースと実行コマンド/追加予定harness。未実施の結果欄は空欄かNOT_RUN。
A36–A38は実家庭2台と本人評価が必要。ローカルで合格に変更しない。

## 別セッションへの依頼文

> D:\CodexTable\fps の docs/design-handoff.md を入口に、残設計を完成させてください。まず現在のHEADとコードを再確認し、S01–S07を「既存仕様への実装追従」「文書の矛盾解消」「利用者のルール判断」に分類してください。関連する docs/implementation/01–08 の正本を更新し、別冊に提案だけを置いて正本との矛盾を残さないでください。特にentityのイベント定義・wire互換性・到達不能時の復帰状態表を先に確定してください。D08は未承認のまま提案と採用状態を区別してください。成果物には実装対象ファイル、依存順、受入条件を含め、テスト未実施を合格にしないでください。今回の担当範囲は設計ドキュメントで、製品コードの変更は別作業です。

推奨順: S01/S02 → S03/S04 → S05/S06 → S07。S04の利用者回答待ちは他の設計を止めない。
このセッションでは別タスクの作成・送信はしていない。上の依頼文を利用者が渡せる状態にしている。
