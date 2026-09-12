# 実装・検証の継続（2026-09-12）

`implementation_complete=false`、`two_home_verified=false`、`player_accepted=false`。全受入の完了ではない。

## 追加実装

- schema1のrecord/checkpointに固定キー・型・範囲・整合性の検査を追加。検証済みの旧得点を読取専用で表示し、旧試合の再開/追記は禁止。全checkpoint破損を空履歴として扱わない。
- 同roundのkeep反復でも1024 recordでcheckpointを開始。round128間隔に加え、記録量での上限を実経路へ接続。
- projectile/grenade/flame/pickupの各kind生成累計8192上限。上限時は消費0。飛翔中の焼夷弾は炎枠を予約し、guest側の既知ID/tombstoneも有界化。
- 散弾の番号重複/異種混在、同packet内の補正対象重複、負のu64時刻、内容が異なる同番号fragmentを拒否。packet seq/epochを上限でwrapしない。
- GameEventsを64件かつ実符号化32KiB以内へ分割。handshakeの受信type計数も追加。
- tickごとの交換観測（固定256件）、3弾種の上限取得、同round keep checkpointの実通信ケースを追加。

## 確認済み

| 対象 | 証拠 |
| --- | --- |
| 全回帰 | `artifacts/tests/20260912-184258-412` Godot63件/Node17件PASS。追加後の物体・通信14件も個別PASS |
| 旧保存 | `test_legacy_store.gd` 20検査PASS、検証済み得点/追記拒否/型破損/全checkpoint破損 |
| A15-cap両役 | `artifacts/integration/20260910-032713-666/result.json` PASS。3種の上限、箱残量1、要求3回再送 |
| A14-hold両役 | `artifacts/integration/20260910-033543-887/result.json` PASS。各役traceも同directory。59未交換/60交換/61再交換なし、drop弾倉11保持、再送副作用0。release62→再press63の厳密時系列は別途残る |
| A27-keeps | `artifacts/integration/20260910-033659-553/result.json` PASS。両者checkpoint1024、round2、得点0–0 |
| 0.2.0既存配布検査 | `artifacts/package/20260910-032545-246/result.json` PASS。commit6c2c4a6、PS5.1 install/menu/practice/debug拒否/uninstall追加file保持/reinstall。以後の変更を再ビルド中 |

## 残っている主要項目

- 全32typeの実通信正常/違反matrix、取得競合・取消・回復/リロードの全時系列。
- entity履歴のSHA比較1024件・baseline再演算用保留との分離、全到着順/欠落matrix。
- hostのforfeit durable recordとguest local certificateの照合境界、GracefulLeave/時計異常/最終ACKの実障害matrix。
- 観測・終了保存の仕様上の固定フィールドへの完全追従と全保存障害点。
- RTT/loss/seed/両役の長時間matrix、releaseの描画性能・遅延計測、画面と音の実観測。

外部待ちはA36–A38（利用者が後日協力者を募る別家庭PC2台・本人評価）。D08は承認済みで、abort-v1は実装・検証済み。途中の各試験PASSを全受入PASSへ読み替えない。
