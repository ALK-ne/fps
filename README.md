# 1対1アリーナFPS

Godot 4.7.2のゲーム本体を実装中。練習、実ENet対戦、10勝決着、両役の30秒再起動復帰をローカルで検証しています。全受入の完了ではありません。

- [実装状況と残りの作業](docs/implementation-status.md)
- [最新の実装・検証ログ（9月13日）](docs/implementation-progress-2026-09-13.md)
- [38項目の受入実行記録](docs/acceptance-run.md)
- [起動・操作・接続方法](packaging/PLAY.md)

開発起動は `tools/godot/4.7.2/Godot_v4.7.2-stable_win64.exe --path game`。エンジンの取得は `pwsh -File tools/bootstrap.ps1`。Windows配布物は `pwsh -File tools/package.ps1 -Version 0.2.1` で生成します。

検証済み配布物: [ArenaDuel-0.2.1.zip](release/ArenaDuel-0.2.1.zip)。SHA256は `71F4BE22DFD13D740166298854A3BA916BDD5C078CB25EB32CECAAD3BBA8E4A0`。全仕様の受入は継続中です。

実装は **[実装仕様v1.1](docs/implementation/README.md)** から開始する。ファイル/API、ルール、通信/復元、画面、配布、12作業単位、38受入項目を定義している。

- [承認済み要件](docs/requirements.md)
- [詳細設計 初稿v0.1](docs/detailed-design-v0.1.md)
- [詳細設計v0.2（背景資料）](docs/detailed-design.md)
- [技術検証結果と制限](docs/technical-validation.md)
- [試験実行ログ](docs/spike-test-results.tap)
- [技術候補・実装準備](docs/technical-plan.md)
- [試作の実行方法](spike/README.md)

`npm test` で17試験を実行。依存パッケージのインストールは不要。

`node tools/validate-design.mjs` で設計の値・依存順・受入対応・リンク・マップの経路と射線を確認する。
