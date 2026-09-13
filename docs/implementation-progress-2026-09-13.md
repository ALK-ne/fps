# 実装・検証の継続（2026-09-13）

`implementation_complete=false`、`two_home_verified=false`、`player_accepted=false`。全受入の完了ではない。

## 修正と検証の範囲

- `b60c1d2`: forfeitの共通prefix証明・hostのみの永続記録、entityのSHA履歴と再演算バッファ分離、イベント欠落復元、自主退出期限切れを反映。遅延baselineの再演算履歴が途中で欠けている場合、待機キューを一部変更せず再要求するよう修正。追加の6検査PASS。
- `892d25a`: チェックサム一覧に未記載の同梱ファイルがある場合と重複行をインストール前に拒否。配布試験は実際のZIPを展開し、内容と上記の異常系を検査してからPS5.1インストーラーを実行する。
- 時計の前進・後退1999/2000/2001 msの境界、期限経過と時計異常が同時に起きた場合の優先順位を11検査で確認。時計不明を期限切れ・敗北に変換しない。実OSの時計変更・sleepの通信試験は別途残る。
- `SaveFaults`へguestの記録ACK送信前・送信後を追加。停止通知を観測して対象PIDを終了し、保存済みendpointから再起動する。両者がround2・得点1–0・同一履歴へ復帰した。30秒待機や同oldEpochの3再送を含む全規定障害matrixの代替ではない。

## Windows Acceptanceの実通信結果

全回帰: `artifacts/tests/20260913-174555-624/result.json` PASS。Godot70件（失敗0）、Node17件（失敗0）、設計検査6項目。前回の68件へ物体復元の部分失敗と時計境界の2件を追加した。

実行ファイルは`b60c1d2`。以後の`892d25a`との差は配布スクリプトと時計の単体試験のみ。

| ケース | 結果と証拠 |
| --- | --- |
| A21-gap、両役 | PASS: `artifacts/integration/20260913-174025-483/result.json` |
| GracefulExpiry、host退出 | PASS: `artifacts/integration/20260913-174042-891/result.json` |
| GracefulExpiry、guest退出 | PASS: `artifacts/integration/20260913-174151-438/result.json` |
| SaveFaults、guest before_ack | PASS: `artifacts/integration/20260913-174519-674/result.json` |
| SaveFaults、guest after_ack | PASS: `artifacts/integration/20260913-174534-161/result.json` |

Acceptance PCK SHA256: `4ED1A1E6665B586FBB1C6B11D4DAFB3329A69D7625B79546D6E65E99F45F2D9F`。
前回の全22 runの集計`artifacts/integration/all-f98e4c4.json`も22件・失敗0を再確認。今回の5 runと混ぜて「最新Allを全実行」とは扱わない。

## 配布物

- [ArenaDuel-0.2.1.zip](../release/ArenaDuel-0.2.1.zip)、build commit `892d25a`、protocol2/storeSchema2。
- ZIP SHA256: `71F4BE22DFD13D740166298854A3BA916BDD5C078CB25EB32CECAAD3BBA8E4A0`。
- `artifacts/package/20260913-174345-271/result.json`: ZIP展開、欠落/重複checksum拒否、PS5.1 install、release menu/practice、debug引数拒否、利用者追加fileを保持するuninstall、reinstall、すべてPASS。
- 起動手順は[PLAY.md](../packaging/PLAY.md)。別家庭接続の検証完了を示す配布物ではない。

## 残り

1. 全32typeの実通信正常/違反matrix、取得競合・取消・回復/リロードの全時系列。
2. entityの全到着順/欠落条件、予測補正・遅延・帯域の規定測定。
3. 観測・終了・session等の保存固定フィールドの仕様への完全追従と、時計・保存・最終ACKの残境界。
4. 長時間RTT/loss/seed/両役matrix、release描画性能、画面・入力・音の実観測。
5. A36–A38のみ利用者が後日協力者を募る別家庭PC2台と本人評価待ち。D08は承認済み。

上記1–4は実装・検証を進める項目であり、技術的に解決不能または利用者の再承認待ちではない。
