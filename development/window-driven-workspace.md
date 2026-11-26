# ウィンドウ操作でワークスペースを動かす（window-driven workspace）

## 実装状況

- **Phase 0**: 3 択設定と旧 Bool 設定の移行を実装済み。新規設定の既定値は `follow`（旧 Bool 設定があればそれを移行する）。
- **Phase 1a/1b（移動）**: 整列済みの管理ウィンドウをマウスダウンで特定し、WindowServer サンプルと AX 通知でドラッグ中にワークスペースと他ペインを追従させる。同期は間引き、リーダーは同期から除外し、マウスアップ時に最終位置へ再整列する。
  - ワークスペースはリーダーより遅れて動くため、リーダーがワークスペースより手前にある間（WindowServer の重なり順で判定）は
    リーダーのペインの穴を閉じて不透明にする。遅れた部分にはタブバー移動時と同じく灰色の背景が見え、背後のウィンドウは透けない。
    ⌘ ドラッグなどでリーダーが背後にある間は、隠さないよう穴を残す。
- **Phase 2（最大化）**: 開始時に整列していた管理ウィンドウが画面の `visibleFrame` に達したら、ワークスペースも最大化する。
- **Phase 3（リサイズ）**: 整列済み管理ウィンドウの外周エッジをリサイズするとワークスペース枠を、内側エッジをリサイズすると隣接するペイン境界を動かす。通常グリッドはトラック比率、カスタム分割は `PaneLayout` の比率を更新する。曖昧な操作や許容値内のサイズ変化はペインへ戻す。
  - ドラッグ中もライブで適用する。サンプルごとにドラッグ開始時の枠・ペインからの絶対量で適用し直すので、
    途中で向きが変わっても誤差が積み重ならない。丸めの許容値内に戻ったら開始時の形に戻し、分類できないサンプルでは直前の形を保つ。
  - 外周リサイズでは、リーダーのペインのうちドラッグしていない内側の辺を開始時の画面位置に保つ。
    サイズが変わるのはリーダーのペインだけで、2 分割のもう一方のペインは動かない。
  - 押下点の hit-test がリサイズ領域の背面に当たってリーダーが決まらなかった場合も、マウス押下中に届いた
    表示中ウィンドウのリサイズ通知が外周リサイズか境界の移動に分類できれば、そのウィンドウをリーダーとして採用する。
  - 移動の判定はサイズが 2pt 以内のときだけ。片辺だけ少し動いたリサイズは移動とみなさずペインに戻す。
- **Phase 4（最小化）**: `follow` では、表示中のペインのウィンドウを最小化するとワークスペースごと最小化する
  （`windowWillMiniaturize` → `session.suspend()` でほかのウィンドウもしまう）。管理ウィンドウのどれかを Dock などから戻すと
  （`kAXWindowDeminiaturizedNotification`）ワークスペースごと戻す。
- **マウスアップ後の判定**: 移動はマウスアップ時に確定する。リサイズはマウスアップ時の最終フレームで枠・境界を確定し、
  アプリがリサイズを終えるまでリーダーを同期から外す。最大化と、リサイズしたリーダーのはめ直しは、フレームが落ち着いてから
  （最後の AX 通知から約 0.3 秒後）`returnDisplacedWindows()` で判定する。リサイズしたリーダーは
  `WindowSession.expectPaneFrame(for:)` で新しいペインを基準にする。表示中のペインのウィンドウのうち
  `alignedFrames` からずれたものを、`alignedFrames` を開始フレームとして分類器にかける。理由は次のとおり。
  - ダブルクリックや Option + 緑ボタンの最大化はマウスアップ後にフレームが変わる。
  - リサイズ領域はウィンドウの外側にもあるので、押下点の hit-test が背面のタブや別アプリのウィンドウに当たる。
  - アプリのリサイズ完了前にペインへ戻すと、大きいフレームを最小サイズと誤記録して「完全には収まりません」の警告が出る。
  最大化済みのワークスペースで最大化された場合は、ウィンドウをペインに戻す。
- **押下状態**: タブなど WindowDock のボタンをクリックすると、AppKit の追跡ループがマウスアップを消費してローカルモニタに届かない。
  `LeftMousePress`（WindowDockCore）は新しい押下で未終了の押下を置き換え、残っていたリーダーを確定させる。
- **未実装**: マウスを使わないタイル配置や Rectangle の操作は、上記の判定で分類できる場合だけ追従する（1 × 1 の最大化など）。

## 背景

- 現状の WindowDock は「ワークスペース枠が正」。管理ウィンドウを直接移動・リサイズ・最大化すると、マウスアップ後に
  ペインへ戻す（設定 `returnDraggedWindowsToPanes`）。サイズや位置を変えたいときは WindowDock の枠を触る必要がある。
- WindowTabs は「前面ウィンドウが正」。ウィンドウ自体を動かすと、ほかのウィンドウとタブが付いてくるので一体化して見える。
  実際は一体化しておらず、次の仕組みで追従させている。
  - タブストリップを前面ウィンドウの owned window にする（`SetWindowLong(GWL_HWNDPARENT)`）。
  - `EVENT_SYSTEM_MOVESIZESTART` で背面ウィンドウを退避し、`EVENT_SYSTEM_MOVESIZEEND` で整列し直す。
  - 分割表示では `EVENT_OBJECT_LOCATIONCHANGE` を受けて、もう一方のペインをワーカーキューで動かす。
- macOS には他アプリのウィンドウに自分のウィンドウを従わせる手段（owned window 相当）がない。
  また、移動・リサイズの開始/終了イベントもない。そこで、マウスボタンの押下状態と AX の
  `kAXWindowMovedNotification` / `kAXWindowResizedNotification` を組み合わせて同等の判定をする。

## 目的

- 管理ウィンドウそのものを移動・リサイズ・最大化しても、ワークスペース全体が 1 つのウィンドウのように振る舞う。
- 本質的な価値である「枠を動かすと中のウィンドウが付いてくる」「ワークスペースを複数持てる」は維持する。

## 対象外

- 他アプリのウィンドウの埋め込み（macOS では不可能）。
- ネイティブフルスクリーンの挙動変更（現行どおり）。
- 管理ウィンドウをドラッグして別のワークスペースへ移す操作（タブドラッグで行う）。

## 提案

### 提案 1: ドラッグしたウィンドウにワークスペースが付いてくる（移動）

- 管理ウィンドウをタイトルバーでドラッグすると、ワークスペース枠とほかのペインのウィンドウが同じ量だけ動く。
- 同じペインの非選択タブのウィンドウは、マウスアップ後の整列で揃える。
- まずはマウスアップ時にまとめて追従させ（1a）、その後ドラッグ中のライブ追従（1b）に広げる。

### 提案 2: ウィンドウの端をリサイズすると、枠またはペイン境界が動く

- ワークスペースの外周に接する辺を動かした場合は、ワークスペース枠をその方向にリサイズする。
- 隣のペインに接する辺を動かした場合は、そのペイン境界を動かす。
- 文字グリッドへの丸めなどで判定できない小さな変化は無視し、ペインに戻す。
- ドラッグ中もライブで適用し、サイズが変わるのはリサイズしたウィンドウのペインだけにする。分類できない角・複数境界の同時変更は無視する。

### 提案 3: ウィンドウを最大化すると、ワークスペースが最大化する

- タイトルバーのダブルクリックや Option + 緑ボタンなどで 1 枚だけ画面いっぱいになったら、
  ワークスペースの `toggleMaximize()` を呼び、全ペインを整列し直す。
- 判定条件は、直前のフレームが `alignedFrames` と一致していて、新しいフレームが画面の `visibleFrame` とほぼ一致すること。

## 設定

Bool の `returnDraggedWindowsToPanes` を 3 択の `managedWindowMoveAction` に置き換える。

| 値 | 表示名（`L()` キー） | 挙動 |
|---|---|---|
| `follow` | ワークスペースを追従させる | 本プランの挙動 |
| `returnToPane` | ペインに戻す | 現行の `true` |
| `nothing` | 何もしない | 現行の `false` |

- UI は `TabOutsideDropSettings`（`Sources/WindowDock/WorkspaceTabDrag.swift`）と同じサブメニュー形式にする。
  見出しは「ウィンドウを直接動かしたとき」。
- 移行: 新キーが未設定なら旧キーを読み、`true` → `returnToPane`、`false` → `nothing` にする。
  旧キーも未設定の新規ユーザーの既定値は「未決事項」を参照。
- 表示中のペインのウィンドウを最小化すると、`follow` ではワークスペースごと最小化し、`returnToPane` では元に戻し、`nothing` では放置する。
- 新しい文字列は `Localization.swift` に en/zh/ko/es を追加する。README の設定説明も更新する。

## 設計

### 現状のコード

| 処理 | 場所 |
|---|---|
| アプリ単位の移動・リサイズ・フォーカス通知 | `WindowEventObserver`（`Accessibility.swift`） |
| 通知 → 0.3 秒後にペインへ戻す | `windowsChangedOutsideWorkspace()` / `returnDisplacedWindows()`（`WorkspaceController.swift`） |
| 戻す判定（`alignedFrames` との差 1px） | `WindowSession.refitDisplacedWindows()` |
| 全ウィンドウの整列 | `WindowSession.synchronize(...)` / `align(_:to:)` |
| マウスのグローバルモニタ | `AppDelegate`（`App.swift`、マスクは `.leftMouseDown` / `.leftMouseUp` など） |
| マウスアップ時の判定 | `finishLeftMousePress`（`App.swift`） |
| 枠の移動・リサイズ | `WorkspaceWindow.setWorkspaceFrame` / `trackFrameChange`（`WorkspaceBackgroundView.swift`） |
| 枠変更 → 同期 | `windowDidMove` / `windowDidResize` → `syncIfVisible` / `scheduleSettledSync`（`WorkspaceController.swift`） |
| ペイン境界の移動 | `PaneLayout.resizing(divider, by:)`、通常グリッドは `WorkspaceGridView` のトラック幅 |
| サイズ丸めの許容値 | `WindowSession.frameRoundingTolerance`（12 × 20） |

### 処理の流れ（提案 1）

1. `.leftMouseDown` で、ポインタ下の管理ウィンドウを WindowServer のウィンドウ一覧で hit-test し、「リーダー」として記録する。
   同時にリーダーの開始フレームとワークスペース枠を記録する（`WorkspaceController.beginWindowInteraction(leader:)` を追加）。
2. リーダーの移動通知を受けたら、開始フレームとの差分を WindowDockCore の分類器に渡す。
3. 移動と判定されたら、ワークスペース枠を差分だけずらし、リーダー以外を `setPosition` で同期する。
4. `.leftMouseUp` で確定し、リーダーを含めて `realign()` する。

### 自分の移動とユーザーの移動を区別する

- 追従するのは、マウスボタンが押されていて、mouse-down でリーダーが記録済みで、
  リーダーのフレームが `alignedFrames` と異なる場合だけにする。
- WindowDock 自身の `align` が起こした AX 通知は、フレームが `alignedFrames` と一致するかで無視する。
  ずれが残る場合に備え、`synchronize` 中を示すフラグ（既存の `isSynchronizing` など）も判定に使う。
- 枠を動かすときは `WorkspaceWindow.setWorkspaceFrame` を使う。その中の `isApplyingWorkspaceFrame` が
  `windowDidMove` / `windowDidResize` での同期を抑えるので、`onWorkspaceFrameChange` で呼ぶ同期をリーダー除外版にする。

### ドラッグ中はリーダーを動かさない

- `WindowSession.sync` / `synchronize` に `excluding leader: UUID?` を追加する。
  リーダーに `setFrame` を発行すると、ユーザーのドラッグと奪い合いになるため。
- `windowDidMove` / `windowDidResize` は `setWorkspaceFrame` 経由でも必ず `scheduleSettledSync`（0.35 秒後に `realign`）を予約する。
  ドラッグ途中で手を止めるとリーダーが動かされるので、リーダー記録中は `realign` を見送り、マウスアップ時の確定に任せる。
- `returnDisplacedWindows()` はマウス押下中は再試行するだけなので、そのまま使える。
  ただし `follow` のときは戻さずに追従結果を確定させる。

### 遅延対策（1b）

- 移動ではサイズが変わらないので、`align` が使う `setPosition` だけで済ませる。
- 同期は 1 フレーム（約 16 ms）に 1 回までに間引く。
- AX 通知が間引かれる場合に備え、既存の 50 ms タイマー（`pollWindowDrag` / `WorkspaceWindowDragTracker`）で
  WindowServer のフレームを補助的にサンプリングする。
- 必要ならグローバルモニタに `.leftMouseDragged` を加え、マウスの移動量で先回りする。
  ただし画面上端などで OS がウィンドウの位置を補正するため、最終的な位置は AX / WindowServer のフレームを正とする。

### 分類器（WindowDockCore）

`Sources/WindowDockCore/ManagedWindowInteraction.swift` にAppKit に依存しない純粋関数を置く。

```swift
public enum ManagedWindowInteraction: Equatable {
    case move(CGVector)
    case resizeWorkspace(edges: WorkspaceResizeEdges, delta: CGSize)
    case moveDivider(edge: WorkspaceResizeEdges, delta: CGFloat)
    case maximize
    case ignore
}

public enum ManagedWindowInteractionClassifier {
    public static func classify(
        start: CGRect, current: CGRect, pane: CGRect, workspaceContent: CGRect,
        screenVisibleFrames: [CGRect], roundingTolerance: CGSize
    ) -> ManagedWindowInteraction
}
```

- 開始フレームが対象ペインに整列している（原点の差 1pt 以内、サイズの差は丸めの許容値以内）ときだけ分類する。
- サイズの変化が許容値以内で原点だけ変わった場合は `.move`。
- 動いた辺を原点と最大値の変化から求める。外周の辺なら `.resizeWorkspace`、内側の辺なら `.moveDivider`。複数辺のうち内側と外側が混在する場合など、曖昧なら `.ignore`。
- `current` がいずれかの画面の `visibleFrame` とほぼ一致すれば `.maximize`。
- どれにも当てはまらなければ `.ignore`（ペインに戻す）。
- 座標系は AX（左上原点）で統一し、AppKit への変換は `WindowGeometry` を使う。

### 提案 2 の適用

- `.resizeWorkspace` は `WorkspaceResize.resizedFrame` と同じ制約（最小サイズ、画面内）で枠に適用する。
- `.moveDivider` は、カスタムレイアウトなら `PaneLayout.resizing(divider, by:)`、通常グリッドならトラック幅の更新で適用する。
- ドラッグ中はサンプルごとに開始時からの絶対量で適用し直し、マウスアップ時の最終フレームで確定する。
- 外周リサイズの後、リーダーのペインのドラッグしていない内側の辺を開始時の画面位置へ戻す。

### 非マウス操作

- macOS Sequoia のタイル配置（メニュー、`fn + ctrl + 矢印`）や Rectangle などはマウスを使わないため、リーダーを特定できない。
- 案: 1 × 1 のワークスペースでは新しいフレームにワークスペースを合わせ、分割時は現行どおりペインに戻す（未決事項）。
- 画面端へのドラッグによるタイル配置は、マウスアップ直後に OS がもう一度フレームを変える。
  マウスアップから約 0.3 秒以内の変化を最終フレームとみなす。

## リスク

- **AX 通知の遅延・欠落**: ほかのウィンドウが遅れて付いてくる。間引き、`setPosition` だけでの同期、マウスアップ後の `realign` で緩和する。
- **自己移動のループ**: WindowDock 自身の移動で通知が来る。`alignedFrames` との比較とフラグで除外する。
- **サイズを丸めるアプリ**（Terminal、iTerm2 など）: `frameRoundingTolerance` を流用する。
- **最小サイズ制約**: 境界の移動を拒否される。`synchronize` の既存処理（最小サイズの記録、分割の解除）に任せる。
- **AXEnhancedUserInterface が有効なアプリ**: `setFrame` で位置が反映されない。既存の回避策（`WindowAccess.setFrame`）を使う。
- **マルチディスプレイ**: 画面をまたいだドラッグでの座標変換と `visibleFrame` の取り違えに注意する。
- **重なり順**: ドラッグ中もリーダーが最前面で、ワークスペースのウィンドウがその背後にある状態を保つ。

## テスト計画

- **ユニットテスト**（`Tests/WindowDockCoreTests`、`swift test`）
  - 分類器: 移動、丸め込みを伴う移動、各辺の外周リサイズと内側リサイズ、最大化、無視、マルチディスプレイ座標。
- **スモークテスト**（`Tests/WindowDockUITests`、`bash Tests/WindowDockUITests/run-smoke.sh`）
  - `--window-follow-only` を追加する。フィクスチャのウィンドウを 2 枚管理し、マウス押下状態を注入しながら
    リーダーを AX で動かす。ワークスペース枠とほかのウィンドウが追従し、リーダーが上書きされないことを確認する。
  - 設定の移行（旧 Bool → 3 択）。
  - 既存の `--window-drop-only` / `--activation-only` / `--tab-move-only` が通ること。
- **手動確認**: Safari、Terminal、Finder、VS Code、Stage Manager の有効時、マルチディスプレイ、Sequoia のタイル配置。

## 段階

1. **Phase 0**: 設定の 3 択化と移行。`follow` は Phase 1a まで選択肢に出さない。
2. **Phase 1a**: 提案 1。マウスアップ時にまとめて追従する。
3. **Phase 1b**: 提案 1。ドラッグ中のライブ追従。
4. **Phase 2**: 提案 3。最大化でワークスペースを最大化する（実装済み）。
5. **Phase 3**: 提案 2。端のリサイズを枠またはペイン境界の変更にする（ドラッグ中のライブ追従を含めて実装済み）。
6. **Phase 4**: 最小化と復帰にワークスペースを追従させる（実装済み）。

各段階で README（ユーザー向けの挙動のみ）と `Localization.swift` を更新する。

## 未決事項

- 非マウス操作（Sequoia のタイル配置、Rectangle）での移動をどう扱うか。
- 角の複数辺を同時にリサイズしたときは、両方が外周なら枠を変え、内側境界を含む場合は曖昧として元のペインへ戻す。
- タイトルバーのダブルクリックが「しまう」（最小化）に設定されている環境での提案 3 の扱い。
