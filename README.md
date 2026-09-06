# 1対1アリーナFPS

現在は要件・実装仕様と、通信/復元の小規模技術試作まで。ゲーム本体は未実装。

実装は **[実装仕様v1.0](docs/implementation/README.md)** から開始する。ファイル/API、ルール、通信/復元、画面、配布、12作業単位、38受入項目を定義している。

- [承認済み要件](docs/requirements.md)
- [詳細設計 初稿v0.1](docs/detailed-design-v0.1.md)
- [詳細設計v0.2（背景資料）](docs/detailed-design.md)
- [技術検証結果と制限](docs/technical-validation.md)
- [試験実行ログ](docs/spike-test-results.tap)
- [技術候補・実装準備](docs/technical-plan.md)
- [試作の実行方法](spike/README.md)

`npm test` で17試験を実行。依存パッケージのインストールは不要。

`node tools/validate-design.mjs` で設計の値・依存順・受入対応・リンク・マップの経路と射線を確認する。
