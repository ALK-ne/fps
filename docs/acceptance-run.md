# 受入実行記録

2026-09-07。全条件を満たしていない項目はPASSにしない。PARTIALは一部のサブケースのみ実施、NOT_RUNは未実施。全仕様の正本はimplementation/07-acceptance.md。

| ID | 状態 | 証拠・不足 |
| --- | --- | --- |
| A01 | PASS | 固定hash導入、headless import、debug/release export、各空profile起動成功 |
| A02 | PASS | test_domain: armor、round、terminal、draw境界 |
| A03 | PARTIAL | canonical破損/切断/int64、packet MAC、fragment、snapshot。全message固定形式未完 |
| A04 | PARTIAL | 実ファイルA/B破損・append再生。製品全kill点未実施 |
| A05 | PARTIAL | 履歴hash/改ざん拒否、復帰照合。checkpoint保存/整理と旧世代復元unit成功。全kill点未実施 |
| A06 | PARTIAL | reducer冪等性・terminal receipt、実再起動1点。全境界未実施 |
| A07 | PASS | test_arena: 実capsule gridのBFS・全合法pairのbody sweep、頭胴射線、左右対称、全loot候補、低足場、境界の209検査 |
| A08 | PASS | 直進/斜めの全速度、jump高度、42tick slide、天井、18tick vault、厚さ/高さ制限、相手割込停止、空中/slide射撃、vault入力制限 |
| A09 | PARTIAL | 実弾命中、発射tick[0,7,14,20,27,33,40,47,53,60]。全散布条件未実施 |
| A10 | PARTIAL | 実射撃・中央壁。全銃頭/薄壁/銃口未実施 |
| A11 | PARTIAL | 同時死亡・timeout比較unit。完了同tick全組合せ未実施 |
| A12 | PASS | test_melee: 素手/武器、同時近接の5m/s・damage0、射程/視野外、壁遮蔽/壁停止、sprint中射撃の16検査 |
| A13 | PASS | 1000seed、chance0/1、銃と弾箱対応、全候補の実衝突余裕、次roundの装備/姿勢/弾/投擲reset |
| A14 | NOT_RUN | 999/1000ms・全競合・視線中断通信受入未実施 |
| A15 | PARTIAL | 弾薬上限・残量unit。reload追加試験と通信未全面検査 |
| A16 | PARTIAL | 実装済み。全回復行列・通信受入未実施 |
| A17 | NOT_RUN | 投擲ホイール・全取消入力未実施 |
| A18 | PARTIAL | 150tick起爆・遮蔽・自己半減unit成功。全物理受入未実施 |
| A19 | PARTIAL | 15tick間隔×20回・自己半減・床なしunit成功。全物理受入未実施 |
| A20 | PARTIAL | 実ENet認証、MAC/replay/fragment unit。全peer/版/DoS未実施 |
| A21 | PARTIAL | プレイヤー状態・baseline同期。全entity/予測/100ms欠落未全面検査 |
| A22 | PARTIAL | 実射撃10勝完走。新IDで再戦成功、draw挿入未実施 |
| A23 | PARTIAL | Fightingでhost kill→30秒restart成功。選択/Countdown未実施 |
| A24 | PARTIAL | Fightingでguest kill→30秒restart成功。選択/Countdown未実施 |
| A25 | PARTIAL | Godot期限境界と両役実65秒後の再開拒否・tombstone確認。全手順期限/反復再試行/再起動hostの終了通知表示は未全面検査 |
| A26 | NOT_RUN | 全close/prepare/activate保存ACK点のkill未実施 |
| A27 | PARTIAL | 2000 drawの保存整理・破損旧世代復元unit成功。時計急変/双方再起動の実プロセス試験未実施 |
| A28 | PARTIAL | 責任不明停止・score保持、D08未承認。全fault注入未実施 |
| A29 | PARTIAL | 練習実行・描画、標的コード。全操作・TTK受入未実施 |
| A30 | PARTIAL | 設定UI描画・保存コード・数値折返し修正。全保存/映像復帰/再割当未実施 |
| A31 | PARTIAL | 日本語画像・生成音。2解像度/定位/全focus受入未実施 |
| A32 | PARTIAL | 実proxyで100ms/1%loss・重複/順序入替下の10勝成功。5分ネットワーク行列未実施 |
| A33 | NOT_RUN | 開発GPU GTX1660 SUPER。10分performance/2000round未実施 |
| A34 | NOT_RUN | 100ms/1%の遅延公平性・帯域測定未実施 |
| A35 | PARTIAL | ZIP、Install、起動、Uninstall追加ファイル保持、debug引数拒否。最新版再出力・menu/practice起動・reinstall成功。全配布条件の検査は未完 |
| A36 | EXTERNAL_PENDING | 異なる家庭のPC2台が必要 |
| A37 | EXTERNAL_PENDING | 実家庭回線の切断・復帰・期限超過が必要 |
| A38 | EXTERNAL_PENDING | 利用者本人の操作感合格が必要 |

ログのrun ID・開発中の制限は[実装状況](implementation-status.md)参照。接続コード/secretは公開しない。外部評価時はPC、OS/GPU、解像度、回線、RTT、復帰観測時刻、照合完了時刻、得点前後、両画面、本人評価を追記する。
