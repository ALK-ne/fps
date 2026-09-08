# 05 マップ・製品画面・練習・設定・配布

## マップの生成

arena.jsonを配置の正本とする。yが上、前方は−z。floor中心[0,−0.25,0]、size[40,0.5,28]。外周はx=±20、z=±14に厚さ0.5、高さ4 mの壁。spawnのfeetはy=0.05。

spawn IDは左側z=−9/0/9が0/1/2、右側が3/4/5。xは±16、yawはleft=−90°、right=90°。各spawnの前壁はx=±13、z=spawn.z、側壁はx=±16.5、z=spawn.z±2.5。sizeはarena.pocketsを使う。出入口は前壁のz方向の両端に残す。

obstaclesを順にBoxMesh＋StaticBody3Dとして生成する。高壁3 m、腰壁/低足場1 m。壁/床/足場の表面にsurface IDを割り当て、焼夷の床cell接続を静的に構築する。装飾meshはcollisionなし。

spawn可否は0.5 m gridで障害物をcapsule半径0.35 mだけ膨張させ、4近傍BFSの歩行距離≥20 mかつ開始時のhead/bodyへ直接射線が通らない組を有効とする。対称行列、対角false、各行に1以上。同じ側の隣接地点は歩行距離16 mなので除外する。設計validatorは5本の代表rayで解析的に確認し、Godotではcollider全体に対する射線と経路を再確認する。

武器は各spawnから内側へ1 mの6候補と追加4候補に必ず1丁。種類の重みは40/25/35。各銃のz+0.7 mに独立50%で弾箱。回復8候補は各75%、種類35/15/35/15。投擲4候補は各75%、種類50/50。全候補は独立抽選、所持数不足を理由に戦闘途中で補充しない。

床へraycastしてitem最下点を床+0.1 mに置く。拾得collider半径はweapon0.3 m、その他0.2 m。揺れる表示meshと固定colliderを分離する。IDは候補順から固定し、選択画面にはloot seedも配置中身も送らない。

## 見た目と人型

背景#111827、床#26344D、壁#465875、ローカル青#41D9FF、敵橙#FFB45B、回復#63E6A6、炎#FF714B、文字#F4F7FB。どちらのPCでも自分=青/相手=橙。色をslot識別の唯一の根拠にしない。

avatarはcapsule胴、sphere頭、boxの腕/脚で構築する。head collider半径0.18 m、feetから1.62 m。body colliderは半径0.3 mで頭と分離。しゃがみでは頭と胴を同じ姿勢へ下げる。輪郭は可視fragmentのみ、壁越し表示なし。銃はbox/cylinderで3種が分かる形状を作り、不可視placeholderにしない。

toon shaderは明/中/影の3段階、roughness1、金属なし。Compatibilityで動く処理のみ。手持ち銃はcamera子mesh、近接壁では表示上だけ下げる。world側の銃口/判定は02のまま。カメラclipで照準が壁を貫通しないことを試験する。

照準は白4本線、ADSでは短縮、ばらつきに応じ開く。確定hitは白×80 ms、headは黄、armor breakは青flash＋固有音。敵HPの常時表示なし。

## 画面と戻り先

基準1920×1080、stretch canvas_items、最小1280×720、通常文字18 px以上。日本語はSystemFontでYu Gothic UI→Meiryo→sans-serif。日本語欠落はA31不合格とし、ライセンス付きフォント同梱で修正する。全表示文字列は日本語辞書へ集約する。

| 画面 | 必須要素 | 戻る/異常 |
| --- | --- | --- |
| メイン | 対戦、練習、設定、終了。未終了matchがあれば「復帰」を最上段 | 破損を明示、旧matchを黙って上書きしない |
| 接続 | ホスト/参加、表示名、経路、endpoint、招待コード、コピー、status、Ready | 8秒timeout→再試行/補助経路。秘密をエラーにechoしない |
| 選択 | 簡略map、6地点、相手確定位置、先手/後手、残り秒、無効理由 | Escは離脱確認。item非表示 |
| HUD | HP/Armor、score/round/time、crosshair、武器/弾、回復4種/投擲2種、拾得とhold進捗 | Suspendedでは操作遮断 |
| 回復ホイール | 4分割、名前/所持/時間、無所持は灰色 | releaseは選択だけ、短押しとの二重発火なし |
| 投擲ホイール | フラグ/焼夷、所持 | G releaseは選択だけ |
| ポーズ | 続行、設定、離れる | オンライン世界は止めない。ローカル入力neutral |
| 復帰待機 | 残り秒、接続/認証/照合、接続画面へ | 期限延長なし。離れるならGracefulLeave |
| 結果 | 勝者/中断理由/score、再戦同意2人分、戻る | 相手不在で再戦不可 |
| 設定 | 入力/表示/音タブ、適用、既定値、戻る | 未適用値は破棄、映像は15秒で復帰 |

mouse captureはFighting/Practice。Alt+Tabでreleaseしholdを消し、戻った最初のクリックはcaptureだけ。ホイール/文字入力中はゲームhotkeyへ漏らさない。Esc連打でダイアログを積まない。オンラインポーズ中もdamageを受ける旨を表示する。

## キーとホイール

WASD移動、Spaceジャンプ/乗り越え、Shift sprint、Ctrl crouch/slide、左fire、右ADS、R reload、E interact、1/2 weapon、V melee、4 heal選択/使用、5–8 heal即使用、G grenade選択/構え、Esc pause。

200 ms未満を短押し、以上を長押し。単調時計で測り、frame数で判定しない。G短押しは構え/解除、左pressで軌道、左releaseでthrow。所持0なら通知だけ。4長押しreleaseは種類選択のみ。UIで処理したreleaseが銃や投擲へ伝播しない。

キー設定はphysical keycode＋modifier。競合時は相互交換する確認画面を表示し、必須操作を未割当にしない。Escは閉じる操作として予約。toggle ADS/crouchは同じInputFrame heldへ正規化する。

## 音と演出

初版はコード生成PCMをW10でWAV化し同梱する。48 kHz/mono/16 bit、seed固定。ライフル70 ms高域noise＋120 Hz、shotgun160 ms低域noise、pistol90 ms noise＋220 Hz、足音80 ms低域noise、hitは1000→600 Hz/50 ms、armor breakは800/1200/1600 Hzを140 msで減衰。無音の仮実装は禁止。

AudioStreamPlayer3Dで銃40 m、足音20 m、拾得/近接10 m。自分のhit確認は2D優先。地上移動距離ごとに歩行1.8 m、sprint2.2 m、crouch2.4 mで足音、crouchは−8 dB。AIR中なし、着地1回。最大32 voice、超えたら遠い古い足音から終了。Master/SFX busを分離。

event IDごと1回だけ音を再生。復帰baselineで過去の発射音を再生しない。足音/銃声の方向と距離、hit/armor breakの区別をA31で確認する。

## 練習

PracticeDirectorは無期限、対戦score/復帰なし。同じ移動/武器/拾得で素手から開始。固定標的[0,0,−6]、移動標的の中心[0,0,6]、x=±4往復2 m/s。HP100/Armor50、反撃なし。命中形状はplayer同等、撃破2秒後respawn。最初のhitから撃破までの時間、head/body hit数を表示。

Resetでplayer/target/lootを同seedで再初期化。「配置再抽選」だけ新seed。練習から戻っても設定は保持し、対戦セーブには触れない。

## 設定

既定値はspec.settings。感度0.01–1.0°/px、ADS係数0.1–2、縦FOV55–100、volume0–1。解像度はOSが報告するもの、window/borderless/fullscreen。FPSは30/60/90/120/144/165/240/unlimited。

low=影OFF/particles16、medium=影1灯1024/particles32、high=影1灯2048/particles64。FXAA/OFFのみ、重いscreen-space effectなし。映像適用から15秒で確認がなければ前設定へ戻して保存。未知schemaはバックアップして既定値起動、matchへ影響させない。

## 配布

ZIPはArenaDuel.exe、ArenaDuel.pck、Install.ps1、Uninstall.ps1、PLAY.md、THIRD_PARTY_NOTICES.md、build-info.json、SHA256SUMS。release export、Node/Godot editor不要。debug console exeは除外。

Install.ps1は現在ユーザーのLocalAppData/Programs/ArenaDuel/<version>/へコピーし、Start Menu/デスクトップshortcutを作る。管理者不要。旧版起動中は案内し、強制終了しない。Uninstallはinstall manifest記載ファイルだけを対象にし、最終絶対パスがinstall root内か確認して削除する。user://設定/セーブは残す。

配布用Install/UninstallはWindows標準PowerShell 5.1互換で記述する。開発用pwshやNodeを利用者に要求しない。PLAY.mdに`powershell.exe -NoProfile -File .\Install.ps1`の実行方法と、端末の実行ポリシーで拒否された場合は利用者の管理方針に従うことを記載する。端末全体のExecutionPolicyをインストーラーが変更しない。

補助ソフトは同梱せず公式導入手順をPLAYへ。Windows Firewallの許可は利用者操作として案内。署名証明書は購入しない。実際のWindows表示をA35に記録する。

build-infoにgame/engine/spec version、rules/map hash、Git commit、UTC build time、release=true。ZIPのhashを作り、空profileでインストール→起動→アンインストールを確認する。
## 復帰画面のv1.1適用

復帰UIは[04の証拠・保存・画面表](04-recovery.md)を直接使用する。「接続・復帰を待っています」の単一表示で全状態を隠さない。期限が確かな連続側だけ残り60秒を表示し、再起動側の未知remainingは秒数表示なし。「相手に確認できず、再開できません」と「復帰期限が過ぎました」を区別する。

復帰/診断画面は常に「接続へ戻る」を持ち、保存済み勝敗/oldEpoch/期限を変えない。退出確認で勝利や新matchを自動作成しない。再確認は診断だけ、30秒で必ず終わる。未確定D08は「勝敗は未確定です」とし、通常の勝者表示・再戦同意画面へ流さない。利用者は接続画面から別IDの新matchを開始できる。StorageErrorは保存処理再試行を別ボタンにし、状態確認だけで保存成功としない。

cameraはPredictionのeye＋offset、壁越しoffsetを禁止。v2 guestの発砲音/flash/反動は確定通知後に一度だけ再生する。操作感はA34/A38で測り、先行射撃表示を暗黙に追加しない。
