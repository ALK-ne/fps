# 実装状況

更新: 2026-09-08。実装中。`implementation_complete=false`、`two_home_verified=false`、`player_accepted=false`。

Godot 4.7.2 Standardの公式ハッシュを照合して導入。game/にゲーム本体を追加した。実装仕様の全38受入を完了したという意味ではない。

| 作業 | 状態 | 成果と残り |
| --- | --- | --- |
| W01 | 実装・一部検証済み | 固定版取得、プロジェクト、起動引数、プロファイルロック、テストランナー、Windows release export。debug/release exportの空profile起動検査成功 |
| W02 | 実装・一部検証済み | 型、設定ハッシュ、reducer、選択、10勝、同時死亡、アーマー境界。wire payloadの全固定レイアウト一致は未完 |
| W03 | 実装中 | append-only/A-B保存、read-back、履歴再生、復帰receipt。128ラウンド毎のcheckpointと双方ACK後の履歴整理、2000 draw・最新checkpoint破損からの復元成功。全保存中断点試験は未完 |
| W04 | ローカル受入完了 | A07/A08: 実衝突形状の全合法spawn経路、射線、配置、移動速度/slide/天井/vaultと相手割込を確認 |
| W05 | 実装・一部検証済み | 3銃、弾速、頭胴、反動、リロード、押し返し。実射撃で10勝完走。全命中境界の試験は未完 |
| W06 | 実装・一部検証済み | 独立loot抽選、弾薬・所持上限、回復、長押し交換。全競合・キャンセルの通信試験は未完 |
| W07 | 実装・未全面検証 | フラグ反射、爆風遮蔽、焼夷床探索、炎cell、投擲入力・軌道。全物理受入は未完 |
| W08 | 実装中 | 実ENet、HMAC challenge、epoch、断片化、固定長snapshot、予測、確定履歴ACK、対戦・再戦。remoteの100ms補間/最大100ms外挿と1024件replay窓を追加。全message固定wire形式、悪意入力全検査、全entity同期検査は未完 |
| W09 | 実装・一部検証済み | 両役30秒再起動→第2ラウンド・正しい1点・履歴一致を実証。両役65秒超過も得点不変・再開拒否を実証。全phase/時計/保存ACK境界の試験は未完 |
| W10 | 実装中 | メニュー、設定、練習標的、HUD、ホイール選択、生成WAV、日本語、focus解除。HUD配置・ホイール描画を画像確認し、画質を解像度倍率/MSAAへ適用。音・入力の全受入は未完 |
| W11 | 実装中 | Windows ZIP、Install/Uninstall、利用者追加ファイル保持、release debug引数拒否。障害proxy実装・100ms/1%loss対戦完走。性能・遅延・全配布受入は未完 |
| W12 | EXTERNAL_PENDING | 実2家庭の接続・復帰、利用者本人の操作感評価が必要 |

## 再現コマンド

```powershell
pwsh -NoProfile -File tools/bootstrap.ps1
pwsh -NoProfile -File tools/test.ps1
pwsh -NoProfile -File tools/integration.ps1 -Suite FullMatch
pwsh -NoProfile -File tools/integration.ps1 -Suite RecoveryRealtime
pwsh -NoProfile -File tools/integration.ps1 -Suite GuestRecoveryRealtime
pwsh -NoProfile -File tools/integration.ps1 -Suite Rematch
pwsh -NoProfile -File tools/package.ps1 -Version 0.1.0
```

## 確認できた証拠

- `artifacts/integration/20260908-030446-069/result.json`: 拾得修正後のSmoke成功。両者Fighting・seq3・同hash、最大poll間隔102/97ms。

- `artifacts/tests/20260908-025942-914/result.json`: Godot 35テスト、Node 17テスト、設計検証成功。同revision競合のSTALE_ITEM、E release制御、床投影と壁際drop探索の修正を含む。追加した実物理テスト35検査成功。A14の通信受入は残る。

- `artifacts/integration/20260907-222504-835/result.json`: 移動・近接・初期化修正後のFullMatch成功。両者10–0、seq31、同hash、最終HP一致。最大poll間隔1151/1172ms、250ms超の処理区間なし。

- `artifacts/tests/20260907-222138-208/result.json`: Godot 32テスト、Node 17テスト、設計検証成功。移動・近接・マップ209検査・ラウンドreset・選択seed非共有を含む。

- 最新配布: `release/ArenaDuel-0.1.0.zip`、製品commit `fa312fc`、SHA256 `db206bb3ba4e9443d72cf5555674ae75abad5f7833478895a80a4c256634e868`。移動・近接・初期化・拾得の修正を収録。
- `artifacts/package/20260908-030636-439/result.json`: 最新配布のPS5.1 install、menu/practice起動、debug引数拒否、追加ファイル保持uninstall、reinstallがすべて成功。
- 旧製品commit `c93fce7` の配布検査: `artifacts/package/20260907-215731-189/result.json` でinstall、menu/practice、debug引数拒否、追加ファイル保持uninstall、reinstall成功。

- `artifacts/integration/20260907-215137-174/result.json` / `20260907-215405-188/result.json`: 両役の65秒後再起動を拒否しscore0–0を保持。hostが再起動するケースは継続guestのtombstoneで再開を拒否するが、再起動hostは相手に到達できず待機表示のまま。guest再起動ケースは両者がtombstoneを保存し停止。
- 通信/補間/Sessionの8テスト指定実行成功。相手の期限終了をチェックサム付きで保存すること、保存先をファイルで塞いだ実書込失敗時にStorageErrorになることを含む。

- `artifacts/debug-export/20260907-215001-523/result.json`: Windows debug exportと空profile起動成功。
- `artifacts/integration/20260907-163522-074/result.json`: 認証完了前のチャンネル跨ぎ先着記録を保留する修正後、100ms/1%loss対戦10勝完走・両者同hash。
- `artifacts/integration/20260907-163655-983/result.json` / `20260907-214831-327/result.json`: 認証変更後もhost/guest各30秒後復帰、正しい1点、同hash、第2ラウンド開始成功。

- `artifacts/integration/20260907-163038-891/result.json`: 最新FullMatch成功、10–0、HP一致、seq31・同hash。最大poll間隔host643ms/guest593ms、250ms超の処理区間なし。
- `artifacts/tests/20260907-162710-960/result.json`: 補間を含むGodot 23テスト、Node 17テスト成功。追加した1024件replay窓は通信/補間6テストを指定実行し成功。

- `artifacts/package/20260907-162222-649/result.json`: commit `3368313` のrelease版でPS5.1 install、メニュー/練習起動、debug引数拒否、追加ファイル保持uninstall、reinstall成功。ZIP SHA256 `64fa196fba69d23413c7116e2271ed475b636c460df61d39993713057e495dbb`。
- `artifacts/integration/20260907-162315-197/result.json`: 最新Smoke成功、両者Fighting・seq3・同hash。

- `artifacts/tests/20260907-160159-894/result.json`: Godot 22テスト・Node 17テスト成功。2000 drawの保存履歴数制限、hash一致、最新checkpoint破損時の旧世代復元を含む。

- `artifacts/integration/20260906-214410-775/result.json`: 実2プロセスで認証・地点選択・戦闘開始、履歴一致。
- `artifacts/integration/20260907-110152-328/result.json`: 実射撃で10勝決着、両者10–0・勝者0・seq31・同hash。このrunでは最終HP表示が古く残り、その後コード修正した。
- `artifacts/integration/20260907-110647-738/result.json`: ホスト終了→30秒後再起動、第2ラウンド、0–1、seq6・同hash。
- `artifacts/integration/20260907-110903-897/result.json`: ゲスト終了→30秒後再起動、第2ラウンド、1–0、seq6・同hash。
- `artifacts/integration/20260907-111213-975/result.json`: 10勝後に双方再戦、新match ID・0–0・第1ラウンドの戦闘開始成功。
- `artifacts/integration/20260907-111732-659/result.json`: UDP proxyで片道50ms・1%loss・duplicate/reorderを注入し10勝完走。最終HPも一致。5分×全行列の代替ではない。
- `artifacts/visual/`: エンジンが描画したメニュー・設定・練習画像。設定の数値折り返しを修正・再描画済み。
- `artifacts/release-start.stderr.log`: export版の空専用profile起動、exit0。
- `artifacts/release-hook.stderr.log`: export版のscenario引数拒否、exit1。初期化失敗時の未接続UIリークは後続修正済み。

統合試験にはloopbackでもheartbeat timeoutを検出した失敗runがある。追加診断で試験レポート書き込みの10秒停止を検出し、一時ファイルからの差替え、読み取り側のFileShare.ReadWrite/Delete、状態変化時だけのstdout出力へ修正した。起動待ちもホスト/ゲスト各120秒へ分離した。通信の2秒/復帰60秒は変更していない。追加診断の毎フレームstdoutも遅延を増幅し得るため、最大処理時間のメモリ集計へ置き換えた。暗号オブジェクト再利用の差は200回で約1msで、数秒停止の主因とは判断しない。全障害行列の合格を意味しない。

## 次に進める内容

残存する通信・保存・物理の未実装/未検査項目を順に埋める。配布ZIPは製品commit `fa312fc`。拾得/交換の通信受入、reload/回復の全行列、entity同期と保存中断点検査が残る。D08の責任不明切断はユーザー回答待ちで、現時点では得点不変の停止・記録保持。
