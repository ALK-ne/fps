# 06 実装の実行指示

## 開始

本パッケージを読み、`node tools/validate-design.mjs`と既存`npm test`を実行。既存変更を消さず、成果を作業単位でGit commitする。リモート公開は含めない。下記のgame/とスクリプトはこれから実装する成果物であり、今回存在するとの意味ではない。

## 作業順と出口

| ID | 依存 | 成果物 | 完了条件 |
| --- | --- | --- | --- |
| W01 | なし | bootstrap、project.godot、App、LaunchOptions、test runner、export preset | A01 固定版headless/Windows出力起動 |
| W02 | W01 | 型、config、codec、MatchReducer、RoundDirector | A02/A03 ルール/直列化境界 |
| W03 | W02 | AtomicFiles、Store、Observation、Checkpoint、復帰pure model | A04–A06 実ファイル中断/照合/冪等性 |
| W04 | W02 | ArenaBuilder/Queries、spawn graph、player、MovementSolver | A07/A08 配置/移動 |
| W05 | W03/W04 | InputRouter、WeaponSystem、弾、DamageSystem、ADS/反動/近接 | A09–A12 射撃/頭/同tick/押し返し |
| W06 | W05 | LootBuilder、Inventory、Pickup/Swap/Healing、回復ホイール | A13–A16 配置/競合/中断/上限 |
| W07 | W06 | 投擲/軌道/反発/炎/ホイール | A17–A19 全投擲挙動 |
| W08 | W07 | ENet/Auth/Session/Replication/Prediction、選択/結果 | A20–A22 全同期/10勝/再戦 |
| W09 | W03/W08 | 自動再接続/認証/期限/起動復帰/照合/tombstone/待機UI | A23–A28 実時計/終了点/例外 |
| W10 | W08 | Practice/Settings/全UI/shader/音/hit/focus | A29–A31 製品機能 |
| W11 | W09/W10 | test/integration/package、Install/Uninstall、PLAY | A32–A35 障害/負荷/遅延/配布 |
| W12 | W11＋利用者2PC | acceptance-runに環境/実測/評価を保存 | A36–A38 外部接続/復帰/本人評価 |

1担当が順番に完遂できる。並列エージェントの起動はこの文書では要求しない。W12の外部条件がなくてもW11までを完成させる。ネット成功をmockで返して進めない。

## W01の具体的手順

1. 公式4.7.2本体とtemplateをtools/cacheへdownloadしspecのSHA256照合。異なれば停止し、最新版へ黙って変更しない。
2. tools/godot/4.7.2、tools/templates/4.7.2へ展開。export presetのcustom template pathを実行時生成。global editor設定へ書き込まない。
3. Compatibility、60 Hz、Godot Physics、custom user dir、最低1280×720を設定。
4. headless import→runner→Windows debug export→空profile起動。初期メニューを表示。
5. 再実行はhash一致のcacheを再利用。巨大binaryをGitへ登録しない。

## 作成するコマンド

```powershell
pwsh -File tools/bootstrap.ps1
pwsh -File tools/sync-spec.ps1
pwsh -File tools/test.ps1
pwsh -File tools/integration.ps1 -Suite All -Seed 20260906
pwsh -File tools/integration.ps1 -Suite RecoveryRealtime -Seed 20260906
pwsh -File tools/package.ps1 -Version 0.1.0
```

sync-specはspec/arena/input既定値をgame/dataへ生成してhash manifestを更新。testはheadless import、GDScript unit/physics、Node試作のexit codeをすべて伝播する。ログはartifacts/tests/<run-id>/にJSON/標準出力/失敗画像/seed/build hash。

integrationはhost/guestを別profile、別instance-lock-port、同じ保存endpointで起動。UDP proxyが実ENet packetを損失/遅延させる。finallyで自分のPIDだけを止め、既存Godotを名前で一括終了しない。

debug起動契約は`-- --profile test_host --role host --endpoint 127.0.0.1:27840 --scenario <id> --seed <n> --instance-lock-port 27831`。guestは別profile/27832。releaseはscenario/fault/injected clockを拒否する。

## 障害注入

UDP proxyはNodeのテスト専用ツールとして作ってよい。両方向delay/jitter/drop/duplicate/reorder/blackholeをseedで固定する。ゲーム本体へNode依存を入れない。fault point通知はdebug stdoutのJSONで受け、ハーネスがPIDを終了。sleepだけで保存中断のタイミングを推測しない。

再起動時は新portをハーネスが教えず、保存endpointから再接続させる。期限unitはFakeClockで59999/60000/60001 ms。本番ClockのRealtime suiteは、切断観測後30秒の再起動成功と65秒後の再起動拒否を必須とする。59秒台は全照合の完了時刻を測り、起動開始だけで成功扱いしない。

## 失敗時の固定分岐

| 失敗 | 次の行動 |
| --- | --- |
| Godot取得/hash | 原因/URLを記録。取得不要の実装を続ける。別版は変更記録が必要 |
| ENet local接続 | API/port/firewallを診断、loopbackで再現。mockで合格しない |
| UPnP/到達性 | 8秒timeoutのUIを確認しTailscale経路へ。独自NAT越えを追加しない |
| 補助ソフト未認証 | 配布物/手順を完成しA36以降だけEXTERNAL_PENDING |
| 時計/責任不明 | D08へ。新しい60秒を発行しない |
| 保存失敗 | append-only/A-BとACK境界を修正。メモリだけへ退化させない |
| FPS不足 | shadow/particles/draw callを削減、60 Hzルール維持 |
| 操作感NG | 委任されたspec値を調整→影響試験→再配布 |

## 証拠と完了宣言

docs/implementation-status.mdにW01–W12状態/commit、docs/acceptance-run.mdにA01–A38のPASS/FAIL/EXTERNAL_PENDINGとログを記載する。未実行はPASSにしない。配布ZIP/hash/実行方法/制限をroot READMEから辿れるようにする。

implementation_completeはW01–W11の全コード・ローカル試験・配布検査が成功し、主要経路にTODO/仮成功/空メソッドがない時。two_home_verifiedとplayer_acceptedは別判定。ユーザーの評価をエージェントの好みで代行しない。
## v1.1残実装の順序（既存Wを補う）

確認基準HEADは`0d4f58a`。下記は既存Wの残作業であり、完了済み実装を最初から作り直す指示ではない。現行の暫定canonical wireと全world定期送信を残したまま、typed pathだけ追加して完成としない。

| 順序 / 対応 | 編集対象と完了させる処理 | 依存 / 確認 |
| --- | --- | --- |
| R1 / S02,W02 | packet_codec/session、追加message_codec/message_policy。protocol2/AD2、全32typeと9event、278byte snapshot、方向/auth/phase、ActionResult/ChooseSpawn | 最初。wire-vectors＋live全type、A03/A20 |
| R2 / S05,W03 | match_state/reducer/round_director、recovery_store/checkpoint/atomic_files。first_slot、schema2 validator、旧schema読取専用、ACK39/2世代/floor/highwater/終了index | R1の30/31/37/39。A04–06/A26/A27 |
| R3 / S01,W08 | weapon_system/grenade_system/simulation/replication、追加entity_replica/baseline_requester。生成完全情報・削除9・補正12・cut baseline・ID寿命 | R1、R2のround境界。A14–19/A21 |
| R4 / S06,W08 | prediction/remote_interpolation/world_view/session。移動再演算、camera offset/wall判定、ring overflow、確定shotのみ | R3のrequester。A21/A34 |
| R5 / S03,S04,W09–10 | recovery_coordinator/recovery_store/session、追加recovery_status、duel_ui。証拠表、有限retry、診断43–45、D08 pending/承認後分岐 | R1/R2。R3/R4と独立に実装可。A23–28 |
| R6 / S07,W11 | tools/integration.ps1、game/testsのscenario/fault harness、export_presets。tick IPC、全fault matrix、測定ring、acceptance export | R1からcaseを段階実行し最後に全体。A03/A14–35 |

各R完了ごとに関連試験とGit commit。最後に生成物のhash、release ZIP、implementation-status/acceptance-runを実行証拠で更新する。設計時点の仕様version1.1、実装予定protocol2/store2、現行ビルド0.1.0を混同しない。ゲーム定数は変更しないため今回spec.jsonは維持、実装時にprotocol/store manifestを独立追加する。D08採用時だけrules hashへpolicyを反映する。

予定CLIとfixture/期待値は[acceptance-scenarios](acceptance-scenarios.md)に固定した。未存在CLIを実行可能と報告しない。A36–38とD08だけを明示的な外部/判断待ちとし、それ以外は上記順序で最後まで実装可能。
