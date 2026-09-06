# 08 決定事項・外部条件・変更記録

## 実装を止めないための決定

| ID | 決定 | 根拠/失敗時 |
| --- | --- | --- |
| D01 | Godot 4.7.2 Standard/GDScript/Compatibility/Godot Physics | 2026-09-06に公式release/asset digestを取得。取得hash不一致なら導入だけ停止、版を黙って変更しない |
| D02 | 通信はENetConnectionの独自小アダプター、手書きtyped binary | service(0)で非ブロッキング処理。RPC/Spawnerとの二重同期を避ける |
| D03 | 単体直接接続/任意UPnPを先行、難しい回線ではTailscale | 要件の「ゲーム単体を優先・補助ソフト許容」を維持。EOSアカウント/拡張を初版の必須依存にしない |
| D04 | ホスト権威、移動予測/再演算、相手補間、過去命中巻き戻しなし | 02/03の時刻・位置を統一。遅延体験はA34/A38で評価 |
| D05 | append-only確定record＋A/B補助保存＋checkpoint | Nodeの旧/新置換試験から製品の保存境界を具体化。Godotで再試験が必要 |
| D06 | RoundPreparedとRoundActivatedを分離 | 死亡直後の切断と次ラウンド切断を区別し、追加加点の境界を定義 |
| D07 | RecoveryResolvedに結果とreceiptを一括保存 | 通常決着後・10勝到達・古い期限通知で再実行しない |
| D08 | 責任不明はscoreを動かさず中断する例外案 | **ユーザー回答未取得、未承認**。次節参照 |
| D09 | 幾何学map/avatar、生成音、Windowsの日本語SystemFont | 外部素材アカウント不要。日本語欠落時だけライセンス付きfontを追加 |
| D10 | 内部名ArenaDuel、初版0.1.0、ZIP＋ユーザー領域Install | ゲーム名未定でもファイル/保存名を固定して実装可能 |
| D11 | 38受入項目とW01–W12を固定 | 実装中の追加質問は外部条件/確定要件変更に限定 |

これらは委任された実装判断であり、承認済みの10勝/90秒/60秒/装備cap等を変更しない。

## D08の扱い

質問済みの内容は「2台だけでは責任を判定できない両者同時切断・通信経路断を、勝敗なしで終了に統一してよいか」。まだ具体的な回答はない。設計作業の続行指示を、このルール変更の承認と読み替えない。

実装可能な既定の安全動作は`Conflict/Suspended`でgameplay停止、score不変、記録保持、接続画面へ戻る導線。提案するリリース動作はRecoveryResolved(abort)で「通信状態を判定できなかったため試合中断」、winner=-1。これを選ぶための利用者向け設定や隠しhost勝利ボタンは作らない。

実装担当はexception handlerとA28まで作れる。正式採用前にD08の承認状態だけを更新する。ユーザーが別方針を選んだ場合、04の責任表/例外のreducerとA28の期待値を変更する。通常の片側再起動は常に従来の切断側敗北で、D08を理由に削除しない。

## 外部条件と担当

| 条件 | 誰が必要か | なくても進める範囲 |
| --- | --- | --- |
| 固定版Godot取得 | 実装エージェント、network許可が必要な場合のみ利用者 | source/config/unit設計は続行 |
| UPnP/Firewall変更の許可 | 対象PC/ルーターの利用者 | 自動変更せずloopback/許可済み経路で実装 |
| Tailscale導入/認証/PC共有 | 両PCの利用者 | W11まで、導線/手順は製品へ実装 |
| 異なる家庭のWindows PC2台 | 利用者と友人 | ローカル全受入/配布まで |
| D08の例外採用 | 利用者 | handler/試験まで、承認済みと記録しない |
| 操作感と友人PC性能の合格 | 利用者/友人 | 開発PCで目標測定、A38は代行しない |

依存サービスのアカウントを勝手に作らない。単体接続が難しいことを実際の接続失敗と経路条件で説明し、補助経路を使った完成は要件の許容範囲として記録する。

## 公式情報の確認記録

2026-09-06にagent-reachのGitHub CLI/Jina Readerで以下を取得した。取得は互換性や外部通信の実証とは区別する。

- [Godot 4.7.2公式release](https://github.com/godotengine/godot/releases/tag/4.7.2-stable)。Windows ZIPとexport templateのasset名/SHA256はspec.engineへ固定。最新追従せずこの版を使う。
- [ENetConnection](https://docs.godotengine.org/en/stable/classes/class_enetconnection.html)。create_host/create_host_bound/connect_to_host/service(0)とイベント配列の仕様を確認。
- [ENetMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)。UDPを使うことを確認。製品では低レベルアダプターへ統一する。
- [UPNP](https://docs.godotengine.org/en/stable/classes/class_upnp.html)。discover/port mapping/external address、既存mappingに対する注意を確認。
- [Time](https://docs.godotengine.org/en/stable/classes/class_time.html)。起動ごとの単調時間と、変更されうるsystem clockを区別。
- [Tailscale導入](https://tailscale.com/kb/1015/install)。利用者が導入/認証する補助経路。無料枠条件はtechnical-plan.mdの先行調査を参照し、実際の採用時に最新条件を再確認する。

## v0.2から変えた点

候補列挙を実装仕様へ置き換えた。固定版/配布hash、ファイル一覧とAPI、型、tick順、競合表、byte format、認証/再接続、永続化/整理、mapの座標、全画面、音、練習、設定、インストール、作業順、試験期待値を追加した。

未確認事項を「後で適当に決める」にせず、担当/検査/失敗時の分岐へ変えた。物理・外部接続・60秒全経路・プレイ評価は未実装/未実証のままであり、この文書の完成からゲームの完成を推論しない。

## 静的検証で修正した箇所

spawn前壁の長さ2.5 mではcapsuleの半径と0.5 mグリッドを考慮した出口に探索ノードが残らず、全spawnが孤立した。前壁を2.0 mへ短縮し、実際の出口幅1.25 mを確保した。さらに近すぎる地点の閾値を20 mへ固定し、同じ側の隣接地点（経路16 m）を除外する。最終可否行列と距離は[検証結果](design-validation.json)に保存する。
