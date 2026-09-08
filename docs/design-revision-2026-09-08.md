# 残設計の改訂記録 — 2026-09-08

対象: 提供資料`docs/design-handoff.md`のS01–S07。調査した実装HEAD: `0d4f58a`。製品コード・既存試験結果・配布物は変更せず、実装仕様v1.1を更新した。

| 課題 | 決定と実装先 | 正本 |
| --- | --- | --- |
| S01 entity同期 | 明示的な全弾生成、投擲/炎削除、ID寿命、補正先着、cut付きbaseline、表示積分とdamage分離 | [03](implementation/03-protocol.md)、[01](implementation/01-architecture.md) |
| S02 wire互換 | 全32type/9eventのschema、channel/方向/phase/認証表、構造golden vectors、protocol2、旧版拒否、操作失敗と切断の区別 | [03](implementation/03-protocol.md)、[schema](implementation/wire-schema.mjs)、[vectors](implementation/wire-vectors.json) |
| S03 期限と診断 | 証拠→timer/block/result→保存→通知→UI、両役65秒、到達不能の有限試行、終了後の認証診断 | [04](implementation/04-recovery.md)、[05](implementation/05-product.md) |
| S04 D08 | 未承認時の停止/記録保持と、明示採用後のabortを分離。承認状態はpendingのまま | [04](implementation/04-recovery.md)、[08](implementation/08-decisions.md) |
| S05 保存上限 | schema2、first_slot、ACK39、2checkpointとsuffix、最新receipt＋highwater、旧記録保護、終了index | [04](implementation/04-recovery.md) |
| S06 予測 | movement snapshot→ACK除去→replay→camera、壁/1 m/256ring、共有baseline requester、射撃表示は確定後 | [02](implementation/02-gameplay.md)、[03](implementation/03-protocol.md) |
| S07 実行できる試験設計 | 操作tick、両役、fault/phase適用表、期待prefix、実時間、UI/音、測定方法、acceptance export | [07](implementation/07-acceptance.md)、[シナリオ](implementation/acceptance-scenarios.md) |

実装開始は[README](implementation/README.md)→[06のR1–R6](implementation/06-execution.md)。新規クラスと既存編集ファイル、依存順、完了判定を明示した。今回追加した予定CLI/クラスは製品側へまだ実装されていない。

## 調査で訂正した認識

現行world同期は存在し、player20 Hz＋inventory/個数変化/投擲中約2 Hzのbaselineという暫定方式だった。receiptは現行reducerですでに1件に制限されており、無制限増加と断定しない。RoundPreparedは実装がseedを除去してfirst_slotを保存する方向なので仕様を一致させた。通信type39に加え42/50も現行に存在する。

host65秒再起動後の待機が終わらない原因は、再起動側に連続時計の権威がなく、残存guestは終了して通常resumeを拒否する一方、再起動host側に有限の診断終了状態がないこと。UTCから期限超過を推測する修正は採らず、認証した終了通知とunknown時の退出を設計した。

## 今回の検証と限界

設計用encoderで全32messageと9eventのfield順/byte例を生成し、snapshotが278 byteであることを検査する。各messageに不足/余剰byteの拒否例を含む。これは構造codecの比較fixtureであり、live認証・合法な履歴blobを含む全経路の合格を意味しない。実装時のlive正常/不正fixtureの作り方は07のシナリオに固定した。

`node tools/validate-design.mjs`を実行し、リンク/定数/依存/配置を含む6分類すべてに合格した。ゲーム定数のspecVersionは1.0.0のままで、文書の改訂版1.1とは別。製品の通信・実時計復帰・画面・音・性能試験は今回実行しない。既存implementation-status.mdとacceptance-run.mdのPASS/PARTIAL/NOT_RUNは更新しない。D08未承認、A36–A38外部待ちは維持する。

分類: S01/S06は既定方式への実装追従と具体化、S02/S05は実装と文書の矛盾解消および互換性判断、S03は復帰条件の具体化、S07は試験実行設計。S04だけが利用者のルール判断。

設計fixtureは別decoderで正常32件・不足/余剰64件・event9型を照合し、すべて期待どおりだった。検査対象は設計資料のbyte列であり、製品codecのPASSではない。
