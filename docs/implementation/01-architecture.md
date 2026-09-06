# 01 実装構成・型・境界

## リポジトリと依存

既存のdocsとspikeは保持する。製品はgame/へ追加する。Node試作をGodotから起動したり、ゲーム実行時にNodeを要求したりしない。

```text
game/
  project.godot                    # main_scene=app/app.tscn, 60 Hz
  export_presets.cfg               # Windows Desktop x86_64
  app/{app.tscn,app.gd,app_context.gd,launch_options.gd}
  core/{ids.gd,clock.gd,game_config.gd,canonical_codec.gd,result.gd}
  domain/{match_state.gd,match_event.gd,match_reducer.gd,round_director.gd}
  simulation/{world_state.gd,simulation.gd,input_frame.gd,movement_state.gd}
  simulation/{movement_solver.gd,action_system.gd,damage_system.gd}
  simulation/{weapon_system.gd,pickup_system.gd,healing_system.gd,grenade_system.gd}
  world/{arena.tscn,arena_builder.gd,arena_queries.gd,spawn_graph.gd,loot_builder.gd}
  actors/{player_body.tscn,player_body.gd,avatar.tscn,avatar.gd,target.gd}
  client/{input_router.gd,prediction.gd,remote_interpolator.gd,presentation_events.gd}
  net/{transport.gd,enet_transport.gd,packet_codec.gd,session.gd,auth.gd}
  net/{replication.gd,action_cache.gd,network_faults.gd,connection_route.gd}
  recovery/{recovery_coordinator.gd,recovery_store.gd,history_sync.gd,checkpoint.gd}
  persistence/{atomic_files.gd,profile.gd,settings_store.gd,instance_lock.gd}
  ui/{connection.tscn,selection.tscn,hud.tscn,pause.tscn,results.tscn,settings.tscn}
  ui/{connection.gd,selection.gd,hud.gd,pause.gd,results.gd,settings.gd,wheel.gd}
  presentation/{toon.gdshader,audio_bank.gd,audio_events.gd,effects.gd}
  practice/{practice_director.gd,practice_hud.gd}
  data/{game_config.json,arena.json,input_defaults.json}
  tests/{run.gd,assertions.gd,fixtures.gd,test_*.gd,scenario_runner.gd}
tools/
  validate-design.mjs              # 今回作成
  bootstrap.ps1                    # 以下はW01以降に作る
  sync-spec.ps1
  test.ps1
  integration.ps1
  package.ps1
packaging/{Install.ps1,Uninstall.ps1,PLAY.md,THIRD_PARTY_NOTICES.md}
```

標準GDScriptのみ。外部テストアドオンを導入せずtests/run.gdをSceneTreeとして実行し、ケースごとのPASS/FAILをJSONと標準出力へ出す。エラーでexit code 1。テスト関数はtest_で始め、登録漏れをrun.gdが検査する。

## 初期化順

AppContextは唯一のcomposition root。Autoloadに状態を散らさない。起動順はLaunchOptions → InstanceLock → Profile/Settings → Config検査 → Clock → Storeの読み取り → UI → Session/Simulation。ゲーム画面の表示前にセーブ破損と版不一致を処理する。

`--profile <name>` は `[a-zA-Z0-9_-]{1,32}` のみ、任意パスを許可しない。通常はdefault、試験はhost/guest。保存ルートはuser://profiles/<name>/。project.godotのcustom_user_dir_nameはArenaDuelで固定する。

同一profileの同時起動を防ぐためInstanceLockが127.0.0.1の専用TCPポートをlistenする。通常27830、テストは`--instance-lock-port`で別々に指定。取れなければ「同じプロファイルが使用中」と表示して終了。既存プロセスを強制終了しない。これはファイルの二重writer防止で、接続認証に使わない。

## 状態の型

GDScriptのRefCountedに型付きプロパティを置き、複製は明示的clone()。wire用Dictionaryをそのままゲーム状態として持たない。全IDは符号なしで扱える範囲を検査し、u64の上限はGDScript intの正領域2^63−1とする。

| 型 | 必須フィールド |
| --- | --- |
| MatchState | match_id:16 bytes, rule_hash:32 bytes, players:[PlayerIdentity×2], host_slot=0, round:u32, prepared_round:u32(0=なし), scores:[u8×2], phase:Phase, round_status:UNOPENED/PREPARED/OPEN/CLOSED, previous_winner:i8(-1/0/1), match_winner:i8, terminal_reason:enum, last_seq:u64, last_hash:32 bytes, epoch_high_water:u32, last_recovery_epoch:u32, recovery_receipts:Set<id>（保持窓のみ） |
| PlayerIdentity | player_id:16 bytes, display_name:String≤24 Unicode文字, slot:u8 |
| RoundState | round:u32, phase_revision:u32, phase_start_tick:u64, deadline_tick:u64, first_slot:u8, selected_spawn:[i8×2], loot_seed:u64（ホスト専用、選択中は送らない） |
| PlayerState | slot, position:Vector3, velocity:Vector3, yaw/pitch:float, movement:MovementState, hp_milli:i32, armor_milli:i32, inventory:Inventory, action:ActionState, last_input_seq:u64 |
| Inventory | revision:u32, weapon_instances:[WeaponInstance?×2], active_slot:i8, reserve:[u16×3], heals:[u8×4], grenades:[u8×2], selected_heal:u8, selected_grenade:u8 |
| WeaponInstance | entity_id:u32, kind:u8, magazine:u16, next_shot_us:u64 |
| ActionState | kind:IDLE/SWITCH/RELOAD/HEAL/GRENADE_READY/GRENADE_AIM/SWAP/VAULT, action_id:u64, begin_tick:u64, end_tick:u64, target_id:u32, expected_revision:u32, selected_kind:u8 |
| MovementState | mode:GROUND/AIR/SLIDE/VAULT, crouched:bool, sprinting:bool, slide_remaining_ticks:u16, vault_start/end:Vector3, vault_progress_ticks:u16, grounded:bool |
| InputFrame | seq:u64, sample_tick:u64, axes:Vector2, yaw/pitch:float, held_buttons:u16, action_refs:Array<u64> |
| ProjectileState | id:u32, owner:u8, kind:u8, position/velocity:Vector3, spawn_tick:u64, expiry_tick:u64, shot_id:u64, pellet_index:u8 |
| PickupState | id:u32, revision:u32, kind:u8, subtype:u8, amount:u16, position:Vector3, weapon_instance:optional |
| RecoveryObservation | match_id, old_epoch:u32, observed_round:u32, last_seq/hash, own_boot_id, peer_boot_id, cause, start_mono_us, start_utc_ms, remaining_ceiling_ms, terminal:bool |

enumの数値はcanonical_codec.gdに1か所だけ定義し、wire/保存/テストで共有する。辞書の列挙順にhashを依存させない。モデルにNode、Resource path、Callableを含めない。

## 公開APIの契約

以下は実装するシグネチャ。`Result`はok/value/error_code/details（表示文はUIで変換）を持つ。

```gdscript
# domain/match_reducer.gd: I/Oも乱数も時刻取得もしない
func apply(state: MatchState, event: MatchEvent) -> Result
func armor_for_round(round_number: int) -> int
func decide_round(players: Array[PlayerState], time_expired: bool) -> int

# domain/round_director.gd: ホストだけが呼ぶ
func begin_round(state: MatchState, seed: int) -> MatchEvent
func accept_spawn(slot: int, spawn_id: int, revision: int, tick: int) -> Result
func step(tick: int) -> Array # PhaseChanged/RandomSpawnSelected

# simulation/simulation.gd: 固定tick、同じ処理を練習とホストで利用
func reset_round(config: GameConfig, round_state: RoundState) -> void
func step(inputs: Array[InputFrame], tick: int) -> Array # 表示イベント/決着候補
func capture_snapshot() -> WorldState

# world/arena_queries.gd: Godot物理との唯一の境界
func sweep_body(state: MovementState, delta: Vector3) -> Result
func first_bullet_hit(from: Vector3, to: Vector3, exclude_slot: int) -> Result
func pickup_target(slot: int, distance: float) -> Result
func grenade_sweep(from: Vector3, to: Vector3, radius: float) -> Result
func explosion_visible(origin: Vector3, slot: int) -> bool

# net/transport.gd
func listen(endpoint: Dictionary) -> Result
func connect_to(endpoint: Dictionary) -> Result
func poll_nonblocking(max_events: int = 64) -> Array
func send(peer: int, channel: int, bytes: PackedByteArray, reliable: bool) -> Result
func close() -> void

# recovery/recovery_store.gd: 書込完了前に成功を返さない
func load_match(match_id: PackedByteArray) -> Result
func append_transaction(events: Array[MatchEvent]) -> Result
func persist_observation(observation: RecoveryObservation) -> Result
func save_receipt(epoch: int, hash: PackedByteArray) -> Result

# recovery/recovery_coordinator.gd
func on_link_lost(cause: int) -> void
func on_authenticated_resume(hello: Dictionary) -> void
func step(monotonic_us: int, utc_ms: int) -> Array
func can_enter_gameplay() -> bool
```

副作用を呼ぶ向きはUI→Session→Domain/Simulation→表示イベント。SimulationがUIやファイルへ直接書かない。DomainがTransportへ直接送らない。Storeがルールを決めない。

## Collision layerの固定

World=bit0、PlayerBody=bit1、DamageHitbox=bit2、Pickup=bit3。PlayerBodyの移動maskはWorld|PlayerBody、弾/爆風rayはWorld|DamageHitbox、拾得rayはWorld|Pickup、投擲sphere sweepはWorld|PlayerBody。視線と爆風の遮蔽判定ではPickupを遮蔽物にしない。

DamageHitboxは頭/胴の判定専用で物理押し戻しを行わない。Projectile/Flameの表示meshはcollisionなし、判定はSimulationだけ。所有者のbody/hitbox RIDを射撃rayから除外する。頭と胴の重複は02の最初の衝突規則で解決し、同じdamageを2回出さない。

Scene treeの表示順とentity IDを関連付けない。wireのtarget IDはWorldStateの管理表から引き、存在しないIDをNodePathへ変換しない。

## フレームとスレッド

`_physics_process`でSessionの入力確定→Simulation.stepを1回、`_process`で非ブロッキング受信/描画。受信コマンドはキューへ入れ、物理tick境界でだけ状態へ適用する。ホストとゲストの物理状態を別プロセスで持つ。

UPnPのdiscoverだけWorkerThreadPoolで実行し、結果をメインへ渡す。ENetConnection/SceneTreeはメインのみ。保存は数KBの確定境界で同期実行し、戦闘中毎tickにflushしない。書込が250 msを超えた時はStorageError/Suspendedを優先し、遅延した入力で戦闘を早送りしない。

`max_physics_steps_per_frame=4`。1フレーム250 ms以上の停止を検知したら通信の停止観測へ進み、描画落ち中に数十tickをまとめて処理しない。試験では固定Clock/FakeArenaQueriesを注入可能とする。

## 例外とログ

Result.error_codeはCONFIG_INVALID、VERSION_MISMATCH、AUTH_FAILED、PORT_IN_USE、NETWORK_TIMEOUT、ACTION_REJECTED、STORE_CORRUPT、STORE_WRITE_FAILED、HISTORY_FORK、CLOCK_UNCERTAIN、RECOVERY_EXPIRED。未処理例外で対戦を続けない。

診断はuser://profiles/<name>/logs/のJSONL、5 MB×3本。UTC時刻、boot IDの先頭8文字、phase、round、event ID、codeを記録。秘密鍵・参加コード・認証MAC・完全なIPを記録しない。テストログだけは期待結果とseedを持てる。
