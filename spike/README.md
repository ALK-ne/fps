# 通信・復元の小規模試作

Node.js 22以降、標準ライブラリだけで動作。今回の実行環境は24.19.0。

```powershell
node --test --test-concurrency=1 spike/protocol.test.mjs
```

- model.mjs: 履歴検査、得点遷移、復帰と分岐判定。
- store.mjs: 一時ファイル保存・置換、保存障害注入。
- peer.mjs: 2プロセス間のUDP履歴同期、保存ACK、通信障害注入。
- protocol.test.mjs: 実プロセス/実ファイル試験と純粋ロジック試験。

用途は設計の成立範囲を確かめること。ゲーム本体ではない。認証なし・loopback限定で、期限と責任情報は試験側から与える。詳細は [検証結果](../docs/technical-validation.md) と [更新後の設計](../docs/detailed-design.md)。
