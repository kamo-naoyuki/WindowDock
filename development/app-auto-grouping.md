# 選択したアプリのウィンドウを自動でグループ化する（app auto-grouping）

## 背景

- 現状の WindowDock は、ウィンドウを手動で追加する（「ウィンドウを追加」シート、空白タブ、ドラッグ）。
  同じアプリのウィンドウを毎回同じワークスペースに入れたい場合でも、開くたびに追加操作が必要。
- WindowTabs には、指定したアプリの新しいウィンドウを自動で既存のタブグループに入れる機能がある。
- 空白タブからアプリを起動して追加する仕組み（`NewTabPage` → `WindowSession.launchWindows` / `fillStartPage`）は
  既にあるが、その後に同じアプリで開いたウィンドウは自動では追加されない。

## 目的

- ワークスペースごとに「自動で追加するアプリ」を登録できるようにする。
- 登録したアプリで新しく開いた通常ウィンドウを、そのワークスペースのタブとして自動で追加する。
- タブの右クリックと空白タブのどちらからでも登録・解除できるようにする。
- 未登録のアプリと既存の手動操作の挙動は変えない。

## 対象外（初版）

- ウィンドウのタイトル、URL、ドキュメントの場所による振り分け。
- 登録したアプリを特定のペインに固定すること（初版はアクティブなペインに追加する）。
- 1 つのアプリを複数のワークスペースへ振り分けること。
- 閉じているワークスペースを自動で開くこと。

## ユーザー向けの挙動

### タブの右クリック

管理中のウィンドウのタブを右クリックしたメニューに、次の項目を追加する。

- `「%@」の新しいウィンドウをこのワークスペースに追加`
  - `%@` はそのタブのアプリ名。チェック付きの項目にし、選ぶたびに登録と解除を切り替える。
- `自動で追加するアプリ` サブメニュー
  - 登録済みのアプリをチェック付きで並べる。選ぶと解除する。
  - 区切り線の後に `アプリを選ぶ…` を置き、`NSOpenPanel` でアプリを複数選べるようにする。
- 空白タブを右クリックした場合は、アプリ名がないので `自動で追加するアプリ` サブメニューだけを出す。

### 空白タブ

`NewTabPage` の「インストール済みのアプリ」（最近使った順の横スクロール一覧）の近くに、`自動で追加するアプリ` セクションを追加する。

- 登録済みのアプリをアイコンで並べ、それぞれに解除ボタンを付ける。
- `アプリを選んで自動追加…` ボタンで、アプリを起動せずに登録する（`NSOpenPanel`、複数選択可）。
- 一覧内の各アプリの右クリックメニューに `このワークスペースに自動で追加` を出す。
  通常のクリック（起動してこのタブに追加）は変えない。
- 復元確認中（`restoration != nil`）はこのセクションを出さない。

### 登録したとき

- 既定では、登録後に開いたウィンドウだけを追加する。
- 登録したアプリに、どのワークスペースにも入っていないウィンドウがあれば確認する。
  - `これから開くウィンドウだけ`（既定）
  - `既存の %d 件も追加`
- そのアプリを別のワークスペースに登録済みなら、
  `「%@」の追加先を「%@」から「%@」に変更しますか？` と確認する。変更しても既存のタブは移動しない。

### 新しいウィンドウを開いたとき

- アクティブなペインにタブとして追加し、そのタブを選択する。
  ペインが分割されている場合は、既存の `WindowSession.add` と同じく空いているペインを優先する。
- ユーザーが開いた直後の前面ウィンドウなので、そのウィンドウを前面に保ったまま、ワークスペースをその背後に揃える。
- 追加先のワークスペースが閉じている、または最小化・非表示中なら追加しない。
- 自動追加したタブを手動で解除したウィンドウは、そのウィンドウが閉じるまで再追加しない。
- 自動追加を解除しても、追加済みのタブはそのまま残す。

## 設計

### 現状のコード

| 処理 | 場所 |
|---|---|
| タブの右クリックメニュー | `WorkspaceChromeView.tabContextMenu(for:)`（`WorkspaceChromeView.swift`） |
| 空白タブ、最近使ったアプリ、アプリの選択 | `NewTabPage.launchActions`（`NewTabPage.swift`） |
| 起動候補の収集 | `InstalledApplications.load`（`InstalledApplications.swift`） |
| 空白タブからの起動と新しいウィンドウの待機 | `WindowSession.launchWindows` / `launchCandidates`（`WindowSession.swift`） |
| 空白タブへの追加 | `WindowSession.fillStartPage` |
| 通常の追加と登録 | `WindowSession.add` / `register` |
| ウィンドウ候補の判定（通常ウィンドウだけ） | `WindowAccess.candidate`（`Accessibility.swift`） |
| アプリ単位の AX 通知 | `WindowEventObserver`（`Accessibility.swift`） |
| 他のワークスペースで管理中かの判定 | `WorkspaceController.isRegisteredElsewhere`（`App.swift` の `addWorkspace` で設定） |
| 最近使ったアプリ | `RecentApplications`、`AppDelegate.frontApplicationChanged` |
| ワークスペースの保存 | `SavedWorkspace` / `SavedLayout`（`SavedLayout.swift`） |

### ルールの保存

`SavedWorkspace` に省略可能な項目を追加する。

```swift
var autoGroupBundleIDs: [String]? = nil
```

- 省略可能にして、既存の `lastWindows` を読み込めるようにする。
- アプリは bundle ID で識別する。bundle ID のないアプリは登録できないようにする。
- 現在の `onSessionChange` はウィンドウがある場合だけ保存するため、ルールだけがある空のワークスペースも保存する。
- ワークスペース名の変更ではルールを引き継ぐ。ワークスペースを削除したらルールも削除する。
- ワークスペースを閉じた場合はルールを保存したまま休止し、復元したときに再開する。

### WindowDockCore

`Sources/WindowDockCore/AutoGroupRules.swift` を追加する。AppKit と AX に依存しない純粋なロジックにする。

```swift
public struct AutoGroupRules: Codable, Equatable {
    public private(set) var workspaceByBundleID: [String: String]

    public func workspace(for bundleID: String) -> String?
    public mutating func assign(_ bundleIDs: [String], to workspace: String) -> [AutoGroupReassignment]
    public mutating func remove(_ bundleID: String, from workspace: String)
    public mutating func renameWorkspace(from old: String, to new: String)
    public mutating func removeWorkspace(_ workspace: String)
}

public enum AutoGroupAdmission: Equatable {
    case add(workspace: String)
    case ignore(reason: AutoGroupIgnoreReason)
}
```

判定関数に渡す入力は、アプリ、ウィンドウの種類、管理中のワークスペース、手動で解除したかどうか、
空白タブから起動中かどうか、追加先が利用できるかどうか。

- 1 つの bundle ID は 1 つのワークスペースだけに登録できる。
- 同じワークスペースへの再登録は何もしない。
- 判定の順序は、通常ウィンドウか、既に管理中か、手動で解除したか、空白タブから起動中か、追加先が利用できるか、の順にする。

### 新しいウィンドウの検出

- `AutoGroupCoordinator` を `App.swift` 以外の新しいファイルに置く。
  スモークテストは `App.swift` を除いてコンパイルするため、`AppDelegate` には接続処理だけを書く。
- 登録されたアプリだけに `kAXWindowCreatedNotification` を購読する。
- `NSWorkspace.didLaunchApplicationNotification` と `didTerminateApplicationNotification` で購読を追加・削除する。
- AX の操作は `WindowAccessClient` に追加して、テストでは偽の実装を使えるようにする。
- 作成直後はタイトルやサブロールが未確定のことがあるため、約 1 秒間だけ再確認してから `WindowAccess.candidate` で判定する。
- 通知の欠落に備え、登録したアプリが前面になったときにも、そのアプリのウィンドウだけを再走査する。

### 既存の追加処理との関係

- 追加には既存の `WindowSession.add` を使い、元の位置・最小化状態の記録と復元処理を共通にする。
- 空白タブから起動したウィンドウは `fillStartPage` が追加する。
  `pendingWindowLaunches` に同じアプリがある間は、自動追加しない。
- 追加の直前に `contains` と `isRegisteredElsewhere` を再確認し、手動追加やドラッグとの二重登録を防ぐ。
- 復元確認中（`restorePrompt`）、ウィンドウ追加シートの表示中、終了処理中は追加しない。
- 自動追加だけではアプリの使用順を変えない。前面になったときは通常どおり使用履歴に反映する。

### 手動で解除したウィンドウ

- `WindowSession` の解除処理で、解除したウィンドウを `AutoGroupCoordinator` に通知する。
- 再追加しない対象は、セッション中だけ CGWindowID（取れない場合は AX 要素）で覚える。
- ウィンドウが閉じたら対象から外す。この情報は保存しない。

### UI の接続

- `WorkspaceChromeView` には、メニューの表示に必要な状態だけを渡す。
  - タブのアプリ名と bundle ID
  - そのワークスペースに登録済みのアプリ
- 登録・解除は `WorkspaceController` の 1 つの処理に集め、右クリックと空白タブの両方から呼ぶ。
- 競合する登録の確認と保存は、すべてのワークスペースを知っている `AutoGroupCoordinator` が行う。
- 新しい文字列は `L()` を通し、`Localization.swift` に en/zh/ko/es を追加する。

## リスク

- **一時的なウィンドウの誤検出**: 保存パネル、設定、通知、補完ポップアップなどを追加しないよう、
  `AXStandardWindow` 以外を除外する。必要ならアプリごとの除外を後で追加する。
- **作成直後の不安定な AX 情報**: タイトルやフレームが遅れて確定する。短い再確認と `WindowAccess.candidate` の判定で緩和する。
- **起動処理との競合**: 空白タブからの起動と自動追加が同じウィンドウを取り合う。`pendingWindowLaunches` を優先する。
- **フォーカスの奪い合い**: 自動追加で別のワークスペースやウィンドウが前面に出ないよう、前面ウィンドウを保つ。
- **複数インスタンスのアプリ**: 同じ bundle ID の別プロセスも同じルールで扱う。必要なら後でアプリの場所を条件に加える。
- **ネイティブタブ**: Safari や Finder のタブは別ウィンドウとして通知されない場合がある。新しいウィンドウだけを対象にする。

## テスト計画

- **ユニットテスト**（`Tests/WindowDockCoreTests`、`swift test`）
  - `AutoGroupRules`: 登録、同じワークスペースへの再登録、別のワークスペースへの変更、解除、
    ワークスペース名の変更・削除、エンコードとデコード。
  - `AutoGroupAdmission`: 通常ウィンドウ、非標準ウィンドウ、管理中、手動で解除済み、空白タブから起動中、
    追加先が閉じている・最小化中。
  - 保存データ: `autoGroupBundleIDs` がない既存の `SavedWorkspace` を読み込めること。
- **スモークテスト**（`Tests/WindowDockUITests`、`bash Tests/WindowDockUITests/run-smoke.sh`）
  - `--auto-group-only` を追加する。
  - 偽の `WindowAccessClient` でウィンドウ作成を通知し、登録したワークスペースにだけタブが追加されることを確認する。
  - 未登録のアプリ、別のワークスペースで管理中、手動で解除したウィンドウが追加されないことを確認する。
  - 空白タブからの起動中に同じウィンドウが二重登録されないことを確認する。
  - 右クリックメニューの項目、チェック状態、無効化状態を確認する。
  - 空白タブのボタンを `accessibilityHitTest` で探し、登録・解除できることを確認する。
  - 既存の `--tab-move-only` / `--window-drop-only` / `--activation-only` が通ること。
- **手動確認**
  - Finder、Terminal、Safari、VS Code で、`⌘N`、Dock のメニュー、アプリの起動直後のウィンドウを確認する。
  - 保存パネルや設定ウィンドウが追加されないことを確認する。
  - 再起動後もルールが残り、閉じたワークスペースでは休止することを確認する。

## 段階

1. **Phase 0**: `AutoGroupRules`、判定関数、保存形式とユニットテストを追加する。
2. **Phase 1**: `AutoGroupCoordinator` で新しいウィンドウを検出して追加する。
   タブの右クリックからの登録・解除を追加する。
3. **Phase 2**: 空白タブのセクション、アプリを起動せずに登録するパネル、アプリ一覧の右クリックを追加する。
4. **Phase 3**: 既存ウィンドウの取り込み、追加先の変更確認、通知文言、README を整える。

各段階で `Localization.swift` を更新する。README には、登録・解除の方法と自動追加される条件だけを書く。

## 未決事項

- 自動追加したときにワークスペースを前面へ出すか、タブだけを追加して前面のウィンドウを維持するか。
- 自動追加したタブを手動で別のワークスペースへ移したら、ルールも移すか。
- 初版で追加先を「アクティブなペイン」にするか、登録時のペインを覚えるか。
- 起動中のアプリの既存ウィンドウを、登録時に毎回確認するか、オプションにするか。
