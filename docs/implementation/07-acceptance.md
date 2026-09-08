# 07 受け入れ仕様

これは実装後に実行する38項目の定義であり、今回38試験を実行したとの意味ではない。U=純粋ロジック、P=Godot物理、I=実2プロセス、V=画面/音/配布実機、E=外部2家庭/本人評価。各項目内の全サブケースに合格して初めてPASS。

期待値はrequirements.mdの確定値とspec.jsonを使う。両者のscore/round/terminal/hashを比較し、ローカル画面の表示だけでネット同期を合格にしない。計測時のseed、engine/build/spec hash、日時、設定を記録する。

| ID | 種別・テスト名 | 操作/初期条件 | 期待値 |
| --- | --- | --- | --- |
| A01 | V bootstrap_export | 固定hashでdownload、headless import、debug/releaseを空profile起動 | 4.7.2固定、parse errorなし、メニュー表示、editor/Nodeなしでrelease起動 |
| A02 | U match_boundaries | round1/3/4/7/8/11/12、引き分けを挿入。9勝から勝利/引き分け | Armor50/50/75/75/100/100/125、draw得点なしで番号+1、10勝後開始拒否 |
| A03 | U codec_validation | 全message/record往復。欠損/余分bytes、NaN、過大長、異版、hash破損 | byte一致、整数精度保持、不正入力を状態変更なしで拒否。配列上限超過で巨大確保なし |
| A04 | I store_crash_points | tmp途中/flush後/rename後/ACK前に各peer終了 | tmpは未確定、完全recordだけ回復。ACKは保存後のみ。A/B片方破損は有効世代 |
| A05 | U/I history_reconcile | 同prefixの新旧、同seq別勝者、長い別枝、checkpointとsuffix | 新しい共通prefixへ収束、巻き戻しなし、fork停止、破損を成功表示しない |
| A06 | U recovery_idempotency | 同oldEpochで復帰を3回、通常決着済み、完了後の古いtimeout | closeは1点だけ、keepは0追加、古いepoch/receiptはno-op、10勝でもreceipt保存 |
| A07 | P arena_constraints | 6spawn全組、head/body ray、BFS、全loot候補、低足場、境界 | 各先手に後手1以上、有効ペア射線なし、到達可能、左右対称、item壁埋まりなし |
| A08 | P movement_modes | 直進/斜め、sprint、jump、slide、crouch、vault、天井/壁際 | 斜め加速なし、jump高度約1.33 m±0.1、slide42 tick、vault18 tick、貫通なし、空中/slide射撃可 |
| A09 | U/P rifle_ttk | 距離0相当の飛翔時間分離fixture、HP100/Armor50、胴10発、射撃hold | 1発15、10発で死亡、初弾→10発目0.983–1.017秒。空中hip半角2倍、ADS半角/倍率一致 |
| A10 | P bullet_head_wall | 全3銃、頭/胴、薄壁、camera/銃口の片方が遮蔽、散弾 | 弾速140/100/120、sweepで壁通過なし、head倍率1.5/1.25/1.5、pellet二重hitなし |
| A11 | U/P simultaneous_timeout | 同tick致死、片側死亡、90秒HP+Armor同値/差、同tick回復完了 | 同時死亡/同値draw、非同値大きい側、死亡優先、非致死被弾→回復後に時間比較 |
| A12 | P melee_sprint | 素手/武器で近接、壁越し/範囲外、同tick双方、sprint中Fire | damage0、合法時だけ水平5 m/s、壁停止、Fireでsprint解除して発射 |
| A13 | U/P loot_generation | 1000seedとchance0/1 fixture、各候補生成、次round reset | 各spawn銃あり、独立抽選、箱対応、候補範囲内、ラウンド中respawnなし、次round装備0 |
| A14 | U/I pickup_swap | 2丁状態でE999/1000 ms、視線逸脱、同item同tick競合、drop再拾得 | 999無交換、1000で1回、round優先slot、drop弾倉保持、releaseまで再取得なし |
| A15 | U/I ammo_reload | 弾倉不足/予備不足、cap直前箱取得、reload中断/完了重複 | 24/6/12、上限120/30/60、余りは箱、reload完了でのみ移動、弾数増殖なし |
| A16 | U/I heal_matrix | 各healの時間/上限、4短長押し/5–8、移動/被弾/死亡/Shift/ADS/既存slide | 3750/6250/3000/5000 ms、上限4/2/4/2・合計12、完了消費だけ、既存slide可/新規不可 |
| A17 | U/I grenade_input | G短/長、左press/release、Esc/武器変更、2種合計cap | Gだけでは投げない、軌道はhold中、releaseで1消費、取消0消費、合計最大2 |
| A18 | P/I frag_damage | 壁反射、149/150 tick、遮蔽、capsuleから0/2/4 m、自傷 | 150 tick起爆、100/50/0 damage、遮蔽0、自傷半分、owner/remote結果一致 |
| A19 | P/I incendiary | 床/壁初接触、床なし、別階/壁向こう、field重なり、寿命 | 床なし消滅、連続床内だけ、15 tickごと20回×8、1field同tick1回、自傷4 |
| A20 | I auth_transport | 別profile ENet、誤secret/異player/異版、第三peer、replay、fragment欠落 | 正しい2者だけbind、認証前入力無効、replay拒否、3秒assemble破棄、UI固まらない |
| A21 | I prediction_all_entities | 両者移動/全銃/拾得/回復/投擲、100 ms不達、補正/再演算 | score/HP/inventory一致、入力neutral、二重音/消費なし、ring溢れbaseline、全要素同期 |
| A22 | I full_match_rematch | 自動scriptで地点選択→戦闘→drawを含む10勝→双方再戦 | 選択期限10+10+3、無効地点拒否、seed非漏洩、全reset、新match/secret、host役維持 |
| A23 | I host_restart_realtime | 選択/Countdown/Fightingでhost kill、30秒後再起動 | 保存endpointから自動接続、guestは同起動、60秒内照合、host敗北1回、次選択 |
| A24 | I guest_restart_realtime | 同じphase集合でguest kill、30秒後再起動 | host継続、guest敗北1回、全world reset、残り期限リセットなし |
| A25 | U/I expiry_boundary | fake59999/60000/60001、実65秒後復帰、再試行反復 | 完了が期限未満だけ成功、超過は終了/tombstone、架空10点へ変更なし、旧match再開拒否 |
| A26 | I close_open_crash | RoundClosed→Prepared→Activatedの各保存/ACK境界で切断 | Activated前はkeep/追加0、後は新round敗北、9勝→10勝で結果。旧round要求が新roundを閉じない |
| A27 | I clock_checkpoint | 2000 draw、checkpoint/整理中kill、UTC±変更、sleep、双方restart | メモリ/履歴保持が無限増大しない、共通checkpoint回復、時計不明は勝手に期限延長しない |
| A28 | I ambiguous_disconnect | 双方向blackhole、両boot変更、食い違う期限/履歴、偽offender | D08の未承認状態を区別し、推測加点なし。Conflictで保存証拠保持、正常を偽装しない |
| A29 | V practice | メニュー→練習、全操作、固定/移動標的、reset/再抽選、退出 | 反撃なし、TTK/頭胴hit表示、2秒respawn、設定保持、対戦scoreなし |
| A30 | V settings_persistence | 全設定変更→再起動、キー競合、映像未確認、破損/旧schema | 保存保持、未割当防止、15秒復帰、壊れたmatchへ波及なし、感度反映 |
| A31 | V product_ui_audio | 1280×720/1920×1080、日本語、focus/AltTab、左右の足音/銃声 | 文字欠け/重なりなし、全画面戻れる、captureクリックで誤射なし、敵視認/音距離/hit区別 |
| A32 | I hostile_network | RTT0/50/100/200 ms×loss0/1/5%、duplicate/reorder、一方向blackhole | 誤score/消費/復活なし。5分走行で例外なし。不達は待機へ移行し無限射撃なし |
| A33 | V soak_performance | 開発PC1920×1080 medium、release、10分移動射撃。2000round headless | 平均60 FPS以上、p95≤20 msを開発側目標、memory差≤50 MB（warmup後）、entity/voice上限内 |
| A34 | I/V latency_fairness | 100 ms RTT/loss1%で同入力経路、補正距離/入力遅延/帯域を計測 | p95表示補正<0.5 m、平常送信各64 KiB/s以下を初期目標。未達は数値と操作評価を報告 |
| A35 | V install_package | 空profile、release ZIP、Install→起動→Uninstall→再install | 開発ツール不要、hash一致、user data保持、manifest外削除なし、debug hook拒否 |
| A36 | E two_home_connect | 異なる家庭2台、単体経路を先行し失敗時補助経路、10勝→再戦 | 実経路/回線/PC/RTT/結果を記録して完走。LANの成功で代替しない |
| A37 | E two_home_resume | 両役で切断/再起動、60秒内/期限超過、9勝時も試す | 実endpoint維持/再認証、正しい得点と終了、同じhost役、外部画面2つの証拠 |
| A38 | E player_acceptance | ユーザーが移動/射撃/視認/音/回復/投擲/遅延/設定を操作 | 本人の合格回答を記録。不満を委任値へ反映し影響試験と再評価 |

## 要件への対応表

| requirements.md | 対応する検査 |
| --- | --- |
| §1 Windows/予算/役割 | A01、A35、A38。外部有料サービス必須にしない |
| §2 試合/選択 | A02、A11、A22、A26 |
| §3 map/移動/見た目/音 | A07、A08、A12、A31 |
| §4 銃/弾/拾得/近接 | A09、A10、A12–A15 |
| §5 HP/Armor | A02、A09、A11 |
| §6 回復 | A16、A21 |
| §7 グレネード | A17–A19、A21 |
| §8 接続/復帰 | A04–A06、A20、A23–A28、A36、A37 |
| §9 練習/設定 | A29、A30 |
| §10 完成条件 | A21、A22、A35–A38 |
| §11 未確定事項 | 08の決定と外部条件。A33/A34は開発目標、友人PC合格の捏造なし |

## 試験の独立性

unitは独立した期待値（例: armor境界、cap、deadline）を持ち、関数出力を同じ関数で再計算して正解としない。Iは実プロセス/実ENet/実保存を使い、手動でportやoffenderを注入しない。fault注入以外の復帰フローは本番と同じものを通す。

試験結果には開始状態→操作→両者の観測→期待値を残す。エラーを握り潰し`ok=true`を返すコードを検査する。主要経路のTODO/empty implementationはW11で不合格にする。

## 外部評価の記入欄

docs/acceptance-run.mdを実装時に作り、run ID、build hash、PC/OS/GPU、解像度/画質、回線、接続経路、RTT、切断観測時刻、再認証/照合完了時刻、score前後、双方画面の記録、ユーザーの評価を埋める。個人の公開IPやsecretは記録しない。

A33/A34は開発側が置く性能目標で、要件の未確定最低動作環境を勝手に承認済みにしたものではない。A36–A38を実行できない場合でもA01–A35のコード/配布成果は完成させ、その3件だけ外部待ちとして報告する。
## v1.1の具体的な実行仕様

[acceptance-scenarios.md](acceptance-scenarios.md)は本章の規範的な補助仕様。A03の全type vector、A14–19の操作tick/欠落/両役、A21のentity/replay、A23–28のfault×role×phaseと期待prefix、A29–31のUI/音操作、A32–34の測定窓、A35のtest/release exportを実装時にそのままcaseへ起こす。既存の受入ID38件は維持し、各IDの全適用caseで合格して初めてPASS。

[wire-vectors.json](wire-vectors.json)は設計用encoderの出力であり、Godot codecの試験実行結果ではない。A25の「超過は終了」はwindowClosedを意味し、責任証拠なしにforfeitを意味しない。A28は04のunknown/policyPending/historyConflictを区別する。保存状態の整合を確認しただけで利用者のD08承認にしない。
