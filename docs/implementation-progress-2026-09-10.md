# 実装継続ログ（2026-09-10）

`implementation_complete=false`。この文書は進行中のコードと確認済み証拠を記録する。作業完了・全受入合格・配布更新を意味しない。

## 接続済みの変更

- protocol 2 / AD2。全送信payloadはMessageCodec/SnapshotCodec経由で、SessionのCanonicalCodec wire fallbackを削除。認証完了前の他チャネル到着を有界に保留し、bind後に方向・phaseを再検査。
- Type20/21を入力・操作台帳・実シミュレーションへ接続。対応inputSeq待ち、操作優先順、拒否結果、重複結果、交換完了通知。ChooseSpawn/PhaseStateとLobbyReadyもtyped経路。
- record/checkpointのschema 2、保存payload固定キー・型・範囲検査、先攻slot保存、checkpoint ACKのseq/hash/blob hash、整理済み履歴floor。schema 1の追記・復帰を拒否。
- ShotFired全弾、ProjectileEnded、GrenadeThrown、FlameCreated、EntityRemoved、InventoryChanged/PickupChanged。Type12補正、cut付きbaseline、Type26の有限再試行。個数変化/2Hzの全world送信を削除。
- 自分のカメラ補正100ms、1m/壁/ring overflowで即補正とbaseline要求。客側の物体表示積分はdamage/消費を実行しない。
- D08 abort-v1をrules hashに反映。両者再起動時はhostの中断記録を双方保存。終了証拠・期限・勝敗を分離し、診断専用43–45と30秒の有限試行を追加。
- 終了IDの4096件単位インデックス、A/B manifest、旧世代tailの保持。終了IDの招待による再利用を拒否。
- 検証用状態採取をloopback制御ソケットへ変更。入力arm、保存faultの外部停止地点通知を追加。

## 確認済み証拠

| 検証 | 結果・ログ |
| --- | --- |
| 保存形式2を含む全回帰（当該時点） | Godot47 / Node17 PASS。`artifacts/tests/20260909-183132-245` |
| 新typed entity経路の10勝 | PASS。`artifacts/integration/20260909-183749-277/result.json` |
| host30秒後再起動 | PASS。0–1、round2、履歴一致。`artifacts/integration/20260909-184747-062/result.json` |
| host65秒後再起動 | PASS。双方終了通知保存、再開なし。`artifacts/integration/20260909-184856-596/result.json` |
| guest65秒後再起動 | PASS。双方同一notice ID、aborted、expired、score0–0。`artifacts/integration/20260910-014122-298/result.json` |
| 両者再起動 | PASS。双方seq4・同hash、中断、winner=-1、score0–0。`artifacts/integration/20260910-014526-625/result.json` |
| 相手不在 | PASS。30秒で送信停止、unknown、得点/期限を推測しない。`artifacts/integration/20260910-014704-935/result.json` |
| 制御socket Smoke | PASS。`artifacts/integration/20260910-014839-644/result.json` |
| 100ms/1%loss対戦 | PASS。10–0、HP/残弾/履歴一致。`artifacts/integration/20260910-015043-723/result.json`。性能基準の合格とは別 |
| A14-empty両役・要求3回再送 | PASS。二重取得/追加revision/結果重複なし。`artifacts/integration/20260910-015240-261/result.json` |

最新のentity到着順/改ざん/再試行試験9件、status/index/終了保存試験6件も個別実行PASS。途中で見つかったイベント参照共有を修正し、同seq別内容をConflictにする回帰を追加済み。

## 続行する項目

- 全32typeのlive正常/違反matrixと、全操作・交換/回復/投擲の通信ケース。
- 保存中断点matrix、checkpoint/終端通知ACK境界、旧schemaの読取検査強化、詳細終了100件・観測履歴の保持整理。
- entity保留byte上限、baseline再適用時の通知重複/古い補正・tombstone整合の追加検査。
- forfeit durable recordとlocal certificateの境界、既確定復帰ACK遅延、clock stall/GracefulLeave証拠の全ケース。
- 性能/遅延matrix、acceptance export、UI実操作、最新版ZIP/インストール検証。現在のZIPは旧版0.1.0のまま。

外部待ちは、利用者が後日協力者を募る別家庭PC2台でのA36–A38。D08の再承認は不要。

## 追加証拠（02:15時点）

- 全回帰再実行: Godot53件・Node17件PASS、`artifacts/tests/20260910-021205-486`。
- SaveFaults: before_write/partial_write/after_flushをHost/GuestでPASS（`20260910-015648-930`から`20260910-015813-363`）。after_renameもHost `20260910-020041-606` / Guest `20260910-020056-091` PASS。
- 途中の`20260910-015828-196`はfault到達前の通信断でFAIL。そこで判明した「中断確定後に旧CountdownがFightingへ戻す」不具合を修正し、terminalのphysics/PhaseState拒否の回帰を追加。
- Checkpoint実通信: `20260910-020314-703`はguestのRoundClosed phase未更新によりACK待ちFAIL。修正後`20260910-020656-299`で双方checkpointSeq385、129ラウンドへ進行PASS。
- 終了詳細100件保持は実テスト専用ディレクトリで検証し、保存IDの永久拒否インデックスを残す整理を製品経路へ接続。
- Windows Acceptanceのdebug exe/PCKを出力済み。最初の起動検証`20260910-020906-513`は公式templateがmain-pack引数を拒否してFAIL。隣接PCK自動読込へ修正し再検証中。release ZIPはまだ更新していない。
- 診断/物体保留の上限、ID寿命、保存sessionの固定キー検査を追加。Entitiesの最初の通信試験`20260910-021151-825`は、採取時刻の違う報告を即比較してFAIL。仕様の2秒収束待ちへ修正し再検証中。
