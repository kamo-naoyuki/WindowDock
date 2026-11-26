import Foundation
import WindowDockCore

/// UI strings are keyed by their Japanese text (the source language).
/// The language follows the OS preferred-language list; unsupported languages fall back to English.
enum Localization {
    enum Language: Int { case en = 0, zh, ko, es }

    static let current: Language? = {
        switch UILanguage.resolve(preferred: Locale.preferredLanguages) {
        case .ja: return nil
        case .en: return .en
        case .zh: return .zh
        case .ko: return .ko
        case .es: return .es
        }
    }()
}

/// Returns the localized string for a Japanese key, formatting with `args` (%@ / %d) when given.
func L(_ key: String, _ args: CVarArg...) -> String {
    var text = key
    if let language = Localization.current, let row = translations[key] {
        text = row[language.rawValue]
    }
    return args.isEmpty ? text : String(format: text, arguments: args)
}

// Order: en, zh-Hans, ko, es
private let translations: [String: [String]] = [
    "タブを移動できませんでした。移動先と対象ウィンドウを確認してください。": [
        "Could not move the tab. Check the destination and target window.",
        "无法移动标签页。请检查目标工作区和窗口。",
        "탭을 이동하지 못했습니다. 이동 대상과 창을 확인하세요.",
        "No se pudo mover la pestaña. Compruebe el destino y la ventana.",
    ],
    "%@に失敗しました（Accessibility: %d）。権限や対象アプリの状態を確認してください。": [
        "%@ failed (Accessibility: %d). Check the permission and the state of the target app.",
        "%@失败（Accessibility：%d）。请检查权限和目标应用的状态。",
        "%@ 실패(Accessibility: %d). 권한과 대상 앱의 상태를 확인하세요.",
        "Error en %@ (Accessibility: %d). Compruebe el permiso y el estado de la app.",
    ],
    "%@の取得": ["getting %@", "获取%@", "%@ 가져오기", "obtener %@"],
    "%@の変更": ["changing %@", "更改%@", "%@ 변경", "cambiar %@"],
    "%@の操作（このウィンドウは非対応）": [
        "performing %@ (unsupported by this window)", "执行%@（此窗口不支持）",
        "%@ 실행(이 창은 지원하지 않음)", "ejecutar %@ (no compatible con esta ventana)",
    ],
    "ウィンドウ位置の取得": ["getting the window position", "获取窗口位置", "창 위치 가져오기", "obtener la posición de la ventana"],
    "ウィンドウ位置の変換": ["converting the window position", "转换窗口位置", "창 위치 변환", "convertir la posición de la ventana"],
    "ウィンドウサイズの変換": ["converting the window size", "转换窗口大小", "창 크기 변환", "convertir el tamaño de la ventana"],
    "拡張UI状態の取得": [
        "getting the Enhanced UI state",
        "获取增强 UI 状态",
        "향상된 UI 상태 가져오기",
        "obtener el estado de interfaz de usuario mejorada"
    ],
    "拡張UI状態の変更": [
        "changing the Enhanced UI state",
        "更改增强 UI 状态",
        "향상된 UI 상태 변경",
        "cambiar el estado de interfaz de usuario mejorada"
    ],
    "対象アプリの取得": ["getting the target app", "获取目标应用", "대상 앱 가져오기", "obtener la app de destino"],
    "最小化状態の取得": ["getting the minimized state", "获取最小化状态", "최소화 상태 가져오기", "obtener el estado minimizado"],
    "ウィンドウの前面表示": ["bringing the window to front", "将窗口置于前台", "창을 맨 앞으로 가져오기", "traer la ventana al frente"],
    "名称未設定": ["Untitled", "未命名", "제목 없음", "Sin título"],
    "移動中ウィンドウの検出": ["detecting the dragged window", "检测被拖动的窗口", "이동 중인 창 감지", "detectar la ventana arrastrada"],
    "移動したウィンドウのアプリの取得": [
        "getting the app of the dragged window", "获取被拖动窗口的应用", "이동한 창의 앱 가져오기",
        "obtener la app de la ventana arrastrada",
    ],
    "移動したウィンドウの一覧取得": [
        "listing the dragged app's windows", "获取被拖动应用的窗口列表", "이동한 앱의 창 목록 가져오기",
        "listar las ventanas de la app arrastrada",
    ],
    "移動した通常ウィンドウの特定（「＋」から追加してください）": [
        "identifying the dragged regular window (add it with \"+\" instead)", "识别被拖动的普通窗口（请改用“+”添加）",
        "이동한 일반 창 식별(\"+\"로 추가하세요)", "identificar la ventana arrastrada (añádala con «+»)",
    ],
    "タイトルの取得": ["getting the title", "获取标题", "제목 가져오기", "obtener el título"],
    "ウィンドウ一覧の変換": ["converting the window list", "转换窗口列表", "창 목록 변환", "convertir la lista de ventanas"],

    "アップデートを確認…": ["Check for Updates…", "检查更新…", "업데이트 확인…", "Buscar actualizaciones…"],
    "設定": ["Settings", "设置", "설정", "Ajustes"],
    "タブをワークスペースの外にドロップしたとき": [
        "When dropping a tab outside a workspace", "将标签页拖放到工作区外时",
        "탭을 작업 공간 밖에 놓을 때", "Al soltar una pestaña fuera de un espacio de trabajo",
    ],
    "ワークスペースを作成": ["Create Workspace", "创建工作区", "작업 공간 생성", "Crear espacio de trabajo"],
    "何もしない": ["Do Nothing", "不执行任何操作", "아무것도 하지 않기", "No hacer nada"],
    "タブを解除するときにウィンドウも閉じる": [
        "Close windows when releasing tabs", "解除标签页时同时关闭窗口", "탭을 해제할 때 창도 닫기",
        "Cerrar las ventanas al liberar las pestañas",
    ],
    "Control+Tabでワークスペースのタブを切り替える": [
        "Use Control+Tab to switch workspace tabs", "使用 Control+Tab 切换工作区标签页",
        "Control+Tab으로 작업 공간 탭 전환", "Usar Control+Tab para cambiar entre pestañas del espacio de trabajo",
    ],
    "ウィンドウをドラッグしてワークスペースに追加する": [
        "Add windows to a workspace by dragging", "通过拖动窗口将其添加到工作区",
        "창을 드래그하여 작업 공간에 추가", "Añadir ventanas al espacio de trabajo arrastrándolas",
    ],
    "移動・最大化・最小化したウィンドウをペインに戻す": [
        "Return moved, maximized, or minimized windows to their panes", "将移动、最大化或最小化的窗口放回窗格",
        "이동·최대화·최소화한 창을 패널로 되돌리기",
        "Devolver a su panel las ventanas movidas, maximizadas o minimizadas",
    ],
    "フルスクリーンのウィンドウもペインに戻す": [
        "Also return full-screen windows to their panes", "也将全屏窗口放回窗格",
        "전체 화면 창도 패널로 되돌리기", "Devolver también a su panel las ventanas a pantalla completa",
    ],
    "空になったワークスペースを自動的に削除する": [
        "Automatically delete workspaces when they become empty", "自动删除变为空的工作区",
        "비게 된 작업 공간 자동 삭제", "Eliminar automáticamente los espacios de trabajo cuando queden vacíos",
    ],
    "新しいワークスペースではタブバーを自動的に隠す": [
        "Automatically hide the tab bar in new workspaces", "在新工作区中自动隐藏标签栏",
        "새 작업 공간에서 탭 막대 자동으로 숨기기", "Ocultar automáticamente la barra de pestañas en espacios de trabajo nuevos",
    ],
    "WindowDock を終了": ["Quit WindowDock", "退出 WindowDock", "WindowDock 종료", "Salir de WindowDock"],
    "タブ": ["Tabs", "标签页", "탭", "Pestañas"],
    "「%@」のタブを復元": ["Restore Tabs in “%@”", "恢复“%@”的标签页", "‘%@’의 탭 복원", "Restaurar pestañas en «%@»"],
    "前回のタブに一致するウィンドウが選択されています。復元するウィンドウを確認してください。": [
        "Windows matching your previous tabs are checked. Choose which windows to restore.",
        "已勾选与上次标签页匹配的窗口。请选择要恢复的窗口。",
        "이전 탭과 일치하는 창이 선택되어 있습니다. 복원할 창을 선택하세요.",
        "Se han marcado las ventanas que coinciden con sus pestañas anteriores. Elija cuáles restaurar.",
    ],
    "%d件を復元": ["Restore %d", "恢复 %d 项", "%d개 복원", "Restaurar %d"],
    "表示": ["View", "视图", "보기", "Ver"],
    "ウィンドウを追加…": ["Add Window…", "添加窗口…", "창 추가…", "Añadir ventana…"],
    "選択中のタブを解除": ["Release Selected Tab", "解除所选标签页", "선택한 탭 해제", "Liberar pestaña seleccionada"],
    "タブバーを自動的に隠す": [
        "Automatically Hide Tab Bar", "自动隐藏标签栏", "탭 막대 자동으로 숨기기", "Ocultar automáticamente la barra de pestañas",
    ],
    "タブバーの位置": ["Tab Bar Position", "标签栏位置", "탭 막대 위치", "Posición de la barra de pestañas"],
    "タブが収まらないときは2段にする": [
        "Wrap crowded tabs into two rows", "标签页放不下时分为两行", "탭이 모두 들어가지 않으면 두 줄로 표시",
        "Usar dos filas cuando no quepan las pestañas",
    ],
    "タブを解除": ["Release Tab", "解除标签页", "탭 해제", "Liberar pestaña"],
    "ウィンドウを閉じる": ["Close Window", "关闭窗口", "창 닫기", "Cerrar ventana"],
    "選択中のタブのウィンドウを閉じる": [
        "Close Selected Tab’s Window",
        "关闭所选标签页的窗口",
        "선택한 탭의 창 닫기",
        "Cerrar la ventana de la pestaña seleccionada"
    ],
    "他のタブのウィンドウをすべて閉じる": [
        "Close All Other Tabs’ Windows",
        "关闭其他所有标签页的窗口",
        "다른 모든 탭의 창 닫기",
        "Cerrar las ventanas de las demás pestañas"
    ],
    "右側のタブのウィンドウを閉じる": [
        "Close Windows of Tabs to the Right",
        "关闭右侧标签页的窗口",
        "오른쪽 탭의 창 닫기",
        "Cerrar las ventanas de las pestañas de la derecha"
    ],
    "左側のタブのウィンドウを閉じる": [
        "Close Windows of Tabs to the Left",
        "关闭左侧标签页的窗口",
        "왼쪽 탭의 창 닫기",
        "Cerrar las ventanas de las pestañas de la izquierda"
    ],
    "すべてのタブのウィンドウを閉じる": [
        "Close All Tabs’ Windows",
        "关闭所有标签页的窗口",
        "모든 탭의 창 닫기",
        "Cerrar las ventanas de todas las pestañas"
    ],
    "他のタブをすべて解除": ["Release All Other Tabs", "解除其他所有标签页", "다른 탭 모두 해제", "Liberar todas las demás pestañas"],
    "右側のタブを解除": ["Release Tabs to the Right", "解除右侧标签页", "오른쪽 탭 해제", "Liberar pestañas a la derecha"],
    "左側のタブを解除": ["Release Tabs to the Left", "解除左侧标签页", "왼쪽 탭 해제", "Liberar pestañas a la izquierda"],
    "すべてのタブを解除": ["Release All Tabs", "解除所有标签页", "모든 탭 해제", "Liberar todas las pestañas"],
    "次のタブ": ["Next Tab", "下一个标签页", "다음 탭", "Pestaña siguiente"],
    "前のタブ": ["Previous Tab", "上一个标签页", "이전 탭", "Pestaña anterior"],
    "最小化": ["Minimize", "最小化", "최소화", "Minimizar"],
    "最大化 / 復元": ["Maximize / Restore", "最大化 / 还原", "최대화 / 복원", "Maximizar / Restaurar"],
    "列数を1 / 2に切替": ["Toggle Columns 1 / 2", "切换列数 1 / 2", "열 수 1 / 2 전환", "Alternar columnas 1 / 2"],
    "行数を1 / 2に切替": ["Toggle Rows 1 / 2", "切换行数 1 / 2", "행 수 1 / 2 전환", "Alternar filas 1 / 2"],
    "カスタム": ["Custom", "自定义", "사용자 지정", "Personalizado"],
    "ペイン": ["Pane", "窗格", "패널", "Panel"],
    "ペインを固定": ["Pin Pane", "固定窗格", "패널 고정", "Fijar panel"],
    "固定中": ["Pinned", "已固定", "고정됨", "Fijado"],
    "ペイン %d": ["Pane %d", "窗格 %d", "패널 %d", "Panel %d"],
    "左右に分割": ["Split Left and Right", "左右分割", "좌우로 분할", "Dividir a izquierda y derecha"],
    "上下に分割": ["Split Top and Bottom", "上下分割", "상하로 분할", "Dividir arriba y abajo"],
    "ペインを閉じる": ["Close Pane", "关闭窗格", "패널 닫기", "Cerrar panel"],
    "ペインの配置を変更できませんでした。": [
        "Could not change the pane layout.", "无法更改窗格布局。",
        "패널 배치를 변경하지 못했습니다.", "No se pudo cambiar la disposición de los paneles.",
    ],
    "%d行%d列 · ": ["Row %d, Col %d · ", "第%d行第%d列 · ", "%d행 %d열 · ", "Fila %d, col. %d · "],
    "システム設定 → プライバシーとセキュリティ → アクセシビリティで WindowDock を許可し、もう一度追加してください。": [
        "Allow WindowDock in System Settings → Privacy & Security → Accessibility, then add the window again.",
        "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 WindowDock，然后重新添加。",
        "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 WindowDock을 허용한 후 다시 추가하세요.",
        "Permita WindowDock en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad y vuelva a añadir la ventana.",
    ],
    "システム設定を開けませんでした。アクセシビリティ設定を手動で開いてください。": [
        "Could not open System Settings. Please open the Accessibility settings manually.",
        "无法打开系统设置。请手动打开辅助功能设置。",
        "시스템 설정을 열 수 없습니다. 손쉬운 사용 설정을 직접 여세요.",
        "No se pudieron abrir los Ajustes del Sistema. Abra los ajustes de Accesibilidad manualmente.",
    ],
    "キー・マウス監視を開始できませんでした。アクセシビリティ権限を確認し、WindowDock を起動し直してください。": [
        "Could not start key/mouse monitoring. Check the Accessibility permission and relaunch WindowDock.",
        "无法启动键盘/鼠标监控。请检查辅助功能权限并重新启动 WindowDock。",
        "키/마우스 감시를 시작할 수 없습니다. 손쉬운 사용 권한을 확인하고 WindowDock을 다시 실행하세요.",
        "No se pudo iniciar la supervisión de teclado/ratón. Compruebe el permiso de Accesibilidad y reinicie WindowDock.",
    ],
    "追加にはアクセシビリティ権限が必要です。システム設定で現在の WindowDock を許可してください。": [
        "Accessibility permission is required to add windows. Allow the current WindowDock in System Settings.",
        "添加窗口需要辅助功能权限。请在系统设置中允许当前的 WindowDock。",
        "창을 추가하려면 손쉬운 사용 권한이 필요합니다. 시스템 설정에서 현재 WindowDock을 허용하세요.",
        "Se requiere permiso de Accesibilidad para añadir ventanas. Permita la WindowDock actual en Ajustes del Sistema.",
    ],
    "ウィンドウの位置・サイズが変わったため追加できませんでした。もう一度移動して離してください。": [
        "The window's position or size changed, so it could not be added. Drag it and release again.",
        "窗口的位置或大小已改变，无法添加。请重新拖动并松开。",
        "창의 위치나 크기가 바뀌어 추가할 수 없습니다. 다시 이동한 후 놓으세요.",
        "La posición o el tamaño de la ventana cambió y no se pudo añadir. Arrástrela y suéltela de nuevo.",
    ],
    "このウィンドウは既に登録されています。": [
        "This window is already registered.", "此窗口已注册。", "이 창은 이미 등록되어 있습니다.", "Esta ventana ya está registrada.",
    ],
    "一部のウィンドウを元に戻せませんでした": [
        "Some windows could not be restored", "部分窗口无法还原", "일부 창을 원래대로 되돌리지 못했습니다",
        "No se pudieron restaurar algunas ventanas",
    ],
    "終了": ["Quit", "退出", "종료", "Salir"],
    "戻って再試行": ["Go Back and Retry", "返回并重试", "돌아가서 다시 시도", "Volver y reintentar"],

    "ワークスペース": ["Workspaces", "工作区", "작업 공간", "Espacios de trabajo"],
    "ワークスペース %d": ["Workspace %d", "工作区 %d", "작업 공간 %d", "Espacio de trabajo %d"],
    "前回のワークスペースを復元": [
        "Restore Previous Workspaces", "恢复上次的工作区", "이전 작업 공간 복원", "Restaurar espacios de trabajo anteriores",
    ],
    "復元するワークスペースを選んでください。": [
        "Choose the workspaces to restore.", "请选择要恢复的工作区。", "복원할 작업 공간을 선택하세요.",
        "Elige los espacios de trabajo que restaurar.",
    ],
    "復元": ["Restore", "恢复", "복원", "Restaurar"],
    "復元しない": ["Don't Restore", "不恢复", "복원 안 함", "No restaurar"],
    "新規ワークスペース": ["New Workspace", "新建工作区", "새 작업 공간", "Nuevo espacio de trabajo"],
    "ワークスペース名を変更…": ["Rename Workspace…", "重命名工作区…", "작업 공간 이름 변경…", "Renombrar espacio de trabajo…"],
    "ワークスペース名を変更": ["Rename Workspace", "重命名工作区", "작업 공간 이름 변경", "Renombrar espacio de trabajo"],
    "ワークスペースを削除…": ["Delete Workspace…", "删除工作区…", "작업 공간 삭제…", "Eliminar espacio de trabajo…"],
    "ワークスペース「%@」を削除しますか？": [
        "Delete workspace “%@”?", "要删除工作区“%@”吗？", "작업 공간 “%@”을(를) 삭제할까요?", "¿Eliminar el espacio de trabajo «%@»?",
    ],
    "閉じるだけでは前回の構成に残ります。削除すると次回の復元候補からも外れます。": [
        "Closing alone keeps it in the saved layout. Deleting also removes it from the restore candidates.",
        "仅关闭会保留在上次的配置中。删除后也会从下次的恢复候选中移除。", "닫기만 하면 이전 구성에 남습니다. 삭제하면 다음 복원 후보에서도 제외됩니다.",
        "Cerrar solo lo mantiene en la configuración guardada. Eliminar también lo quita de los candidatos de restauración.",
    ],
    "ワークスペースの操作": ["Workspace actions", "工作区操作", "작업 공간 작업", "Acciones del espacio de trabajo"],
    "閉じているワークスペース": ["Closed Workspaces", "已关闭的工作区", "닫힌 작업 공간", "Espacios de trabajo cerrados"],
    "開く": ["Open", "打开", "열기", "Abrir"],
    "同じ名前のワークスペースが既にあります。": [
        "A workspace with that name already exists.", "已存在同名工作区。", "같은 이름의 작업 공간이 이미 있습니다.",
        "Ya existe un espacio de trabajo con ese nombre.",
    ],
    "削除": ["Delete", "删除", "삭제", "Eliminar"],
    "ワークスペースを閉じる": ["Close Workspace", "关闭工作区", "작업 공간 닫기", "Cerrar espacio de trabajo"],
    "%d個のウィンドウ": ["%d windows", "%d 个窗口", "창 %d개", "%d ventanas"],
    "このウィンドウは別のワークスペースに登録されています。": [
        "This window is registered in another workspace.", "此窗口已注册到其他工作区。",
        "이 창은 다른 작업 공간에 등록되어 있습니다.", "Esta ventana está registrada en otro espacio de trabajo.",
    ],

    "追加": ["Add", "添加", "추가", "Añadir"],
    "タブに追加するウィンドウ": ["Windows to Add as Tabs", "要添加为标签页的窗口", "탭에 추가할 창", "Ventanas para añadir como pestañas"],
    "アプリ / ウィンドウ": ["App / Window", "应用 / 窗口", "앱 / 창", "App / Ventana"],
    "キャンセル": ["Cancel", "取消", "취소", "Cancelar"],
    "新しいタブ": ["New Tab", "新标签页", "새 탭", "Nueva pestaña"],
    "複数選択": ["Select Multiple", "多选", "여러 개 선택", "Seleccionar varias"],
    "追加できなくなったウィンドウ: %@": [
        "Window no longer available: %@", "窗口已不可添加：%@", "더 이상 추가할 수 없는 창: %@", "Ventana ya no disponible: %@",
    ],
    "開いているウィンドウ": ["Open Windows", "已打开的窗口", "열려 있는 창", "Ventanas abiertas"],
    "一覧を更新": ["Refresh Windows", "刷新窗口列表", "창 목록 새로 고침", "Actualizar ventanas"],
    "画面収録を許可してプレビューを表示…": [
        "Allow Screen Recording for Previews…", "允许录屏以显示预览…", "미리보기를 위해 화면 기록 허용…",
        "Permitir la grabación de pantalla para ver vistas previas…",
    ],
    "最近タブに追加したアプリ": [
        "Apps Recently Added to Tabs", "最近添加到标签页的应用", "최근 탭에 추가한 앱", "Apps añadidas recientemente a pestañas",
    ],
    "どのワークスペースでも、ウィンドウをタブに追加するとそのアプリがここに新しい順で表示されます（最大10個）。": [
        "When you add a window as a tab in any workspace, its app appears here, newest first (up to 10).",
        "在任意工作区中将窗口添加为标签页后，其应用会按从新到旧显示在这里（最多 10 个）。",
        "어느 작업 공간에서든 창을 탭으로 추가하면 해당 앱이 최신순으로 여기에 표시됩니다(최대 10개).",
        "Al añadir una ventana como pestaña en cualquier espacio de trabajo, su app aparece aquí, de la más reciente a la más antigua (hasta 10).",
    ],
    "アプリを選ぶと新しいウィンドウを開いて、このタブに追加します。起動していないアプリは起動し、起動中のアプリでは「新規ウィンドウ」を実行します。": [
        "Choose an app to open a new window in this tab. Apps that aren’t running are launched; running apps use their New Window command.",
        "选择应用后，会打开新窗口并添加到此标签页。未运行的应用会被启动；已运行的应用会执行“新建窗口”。",
        "앱을 선택하면 새 창을 열어 이 탭에 추가합니다. 실행 중이 아닌 앱은 실행하고, 실행 중인 앱은 '새 창' 명령을 사용합니다.",
        "Elige una app para abrir una ventana nueva en esta pestaña. Si no está abierta, se abre; si ya lo está, se usa su comando Nueva ventana.",
    ],
    "その他のアプリを選んで起動…": [
        "Choose Another App to Launch…", "选择其他应用并启动…", "다른 앱을 선택하여 실행…", "Elegir otra app para abrir…",
    ],
    "このタブまたはウィンドウは利用できなくなりました。": [
        "This tab or window is no longer available.", "此标签页或窗口已不可用。", "이 탭 또는 창은 더 이상 사용할 수 없습니다.",
        "Esta pestaña o ventana ya no está disponible.",
    ],
    "追加できるウィンドウがありません。": [
        "No windows available to add.", "没有可添加的窗口。", "추가할 수 있는 창이 없습니다.", "No hay ventanas para añadir.",
    ],
    "起動するアプリを選択": ["Choose an App to Launch", "选择要启动的应用", "실행할 앱 선택", "Elegir una app para abrir"],
    "起動": ["Launch", "启动", "실행", "Abrir"],
    "新規ウィンドウの作成": ["opening a new window", "创建新窗口", "새 창 열기", "abrir una ventana nueva"],
    "ウィンドウ一覧の取得": ["listing windows", "获取窗口列表", "창 목록 가져오기", "obtener la lista de ventanas"],
    "「新規ウィンドウ」メニューの取得": [
        "finding an enabled New Window command", "查找可用的新建窗口命令", "사용 가능한 새 창 명령 찾기",
        "encontrar el comando Nueva ventana disponible",
    ],
    "%@を起動できませんでした: %@": [
        "Could not launch %@: %@", "无法启动 %@：%@", "%@을(를) 실행할 수 없습니다: %@", "No se pudo abrir %@: %@",
    ],
    "アプリは起動しましたが、追加できるウィンドウが見つかりませんでした。": [
        "The app launched, but no window was available to add.",
        "应用已启动，但没有找到可添加的窗口。",
        "앱이 실행되었지만 추가할 수 있는 창을 찾지 못했습니다.",
        "La app se abrió, pero no se encontró ninguna ventana para añadir.",
    ],
    "取得できなかったアプリ: %@": ["Apps that could not be read: %@", "无法读取的应用：%@", "가져오지 못한 앱: %@", "Apps no legibles: %@"],
    "、": [", ", "、", ", ", ", "],
    "追加できるウィンドウがありません。別のアプリで通常のウィンドウを開いてください。": [
        "No windows available to add. Open a regular window in another app.",
        "没有可添加的窗口。请在其他应用中打开普通窗口。",
        "추가할 수 있는 창이 없습니다. 다른 앱에서 일반 창을 여세요.",
        "No hay ventanas para añadir. Abra una ventana normal en otra app.",
    ],
    "ウィンドウを選んで追加。フルスクリーンは事前に解除してください。": [
        "Select windows to add. Exit full screen beforehand.",
        "选择要添加的窗口。请先退出全屏。",
        "추가할 창을 선택하세요. 전체 화면은 미리 해제하세요.",
        "Seleccione ventanas para añadir. Salga antes del modo de pantalla completa.",
    ],
    "Command + クリックで複数選択 / Shift + クリックで範囲選択": [
        "Command-click to select multiple / Shift-click to select a range",
        "Command + 点按多选 / Shift + 点按范围选择",
        "Command + 클릭으로 다중 선택 / Shift + 클릭으로 범위 선택",
        "Command + clic: selección múltiple / Shift + clic: rango",
    ],
    "選択したアプリの全ウィンドウを選択": [
        "Select All Windows of App", "选择该应用的所有窗口", "앱의 모든 창 선택", "Seleccionar todas las ventanas de la app",
    ],
    "%d件を追加": ["Add %d", "添加 %d 个", "%d개 추가", "Añadir %d"],

    "分割数は縦・横それぞれ1〜4にしてください。": [
        "Use 1–4 for both columns and rows.", "行数和列数都请设为 1–4。", "가로·세로 분할 수는 각각 1~4로 지정하세요.",
        "Use de 1 a 4 columnas y filas.",
    ],
    "分割表示の領域を取得できませんでした。": [
        "Could not get the split view area.", "无法获取分屏区域。", "분할 표시 영역을 가져올 수 없습니다.",
        "No se pudo obtener el área de la vista dividida.",
    ],
    "対象アプリ": ["the target app", "目标应用", "대상 앱", "la app de destino"],
    "%@（%@のウィンドウが収まりません）": [
        "%@ (%@’s window won’t fit)",
        "%@（%@ 的窗口无法放入）",
        "%@ (%@ 창이 맞지 않음)",
        "%@ (la ventana de %@ no cabe)",
    ],
    "%@の最小サイズにより、この方向には分割できません。": [
        "%@’s window won’t fit in this direction.",
        "%@ 的窗口无法放入此方向的窗格。",
        "%@ 창은 이 방향의 패널에 맞지 않습니다.",
        "La ventana de %@ no cabe en esta dirección.",
    ],
    "%@のサイズ・位置の制約により分割できないため、1×1表示に戻しました。": [
        "The panes could not fit %@’s window, so the workspace returned to 1×1.",
        "窗格无法容纳 %@ 的窗口，工作区已恢复为 1×1。",
        "패널에 %@ 창이 맞지 않아 작업 공간을 1×1로 되돌렸습니다.",
        "Los paneles no admiten la ventana de %@; el espacio de trabajo volvió a 1×1.",
    ],
    "%@のサイズ・位置の制約により、枠内に完全には収まりません。": [
        "%@’s window does not fully fit in the pane.",
        "%@ 的窗口无法完全放入窗格。",
        "%@ 창이 패널에 완전히 맞지 않습니다.",
        "La ventana de %@ no cabe por completo en el panel.",
    ],
    "⌃ Tab / ⌃ ⇧ Tab でタブを切替": [
        "⌃ Tab / ⌃ ⇧ Tab to switch tabs", "⌃ Tab / ⌃ ⇧ Tab 切换标签页",
        "⌃ Tab / ⌃ ⇧ Tab으로 탭 전환", "⌃ Tab / ⌃ ⇧ Tab para cambiar de pestaña",
    ],

    "ここに移動 / 入れ替え": ["Move / Swap Here", "移到此处 / 交换", "여기로 이동 / 교체", "Mover / intercambiar aquí"],
    "左": ["Left", "左", "왼쪽", "Izquierda"], "右": ["Right", "右", "오른쪽", "Derecha"],
    "上": ["Top", "上", "위", "Arriba"], "下": ["Bottom", "下", "아래", "Abajo"],
    "閉じる": ["Close", "关闭", "닫기", "Cerrar"],
    "ウィンドウを追加": ["Add Window", "添加窗口", "창 추가", "Añadir ventana"],
    "権限設定": ["Permission Settings", "权限设置", "권한 설정", "Ajustes de permisos"],
    "別のウィンドウをここへ移動して離す\nまたは、上の ＋ から追加\n\n異なるアプリをタブで切り替えられます。": [
        "Drag another window here and release,\nor add one with + above.\n\nSwitch between different apps with tabs.",
        "将其他窗口拖到此处松开，\n或通过上方的 + 添加。\n\n可用标签页在不同应用间切换。",
        "다른 창을 여기로 이동해 놓거나\n위의 +로 추가하세요.\n\n서로 다른 앱을 탭으로 전환할 수 있습니다.",
        "Arrastre otra ventana aquí y suéltela,\no añada una con + arriba.\n\nCambie entre apps distintas con pestañas.",
    ],
    "最大化 / 復元（空き領域のダブルクリックでも切替）": [
        "Maximize / Restore (also by double-clicking the empty area)", "最大化 / 还原（也可双击空白区域）",
        "최대화 / 복원(빈 영역을 더블 클릭해도 전환)", "Maximizar / Restaurar (también con doble clic en el área vacía)",
    ],
    "ドラッグして移動 / ダブルクリックで最大化": [
        "Drag to move / double-click to maximize", "拖动移动 / 双击最大化", "드래그하여 이동 / 더블 클릭으로 최대화",
        "Arrastre para mover / doble clic para maximizar",
    ],
    "横": ["Col ", "列 ", "열 ", "Col. "], "縦": ["Row ", "行 ", "행 ", "Fila "],
    "%@の分割数": ["%@ split count", "%@分屏数", "%@ 분할 수", "División de %@"],
    "追加にはアクセシビリティの許可が必要です": [
        "Accessibility permission is required to add", "添加需要辅助功能权限", "추가하려면 손쉬운 사용 허용이 필요합니다",
        "Se requiere permiso de Accesibilidad para añadir",
    ],
    "この帯へ移動して離すとタブに追加": [
        "Move onto this banner and release to add as a tab", "移到此横幅并松开即可添加为标签页",
        "이 띠로 이동해 놓으면 탭에 추가", "Mueva sobre este banner y suelte para añadir como pestaña",
    ],
    "配置を入れ替え": ["Swap Placement", "交换位置", "배치 교체", "Intercambiar posición"],
    "%d行 %d列": ["Row %d, Col %d", "第%d行 第%d列", "%d행 %d열", "Fila %d, col. %d"],
    "操作対象": ["Active", "当前操作", "조작 대상", "Activa"],
    "分割表示中": ["Shown in Split", "分屏显示中", "분할 표시 중", "Visible en división"],
    "未選択": ["Not Selected", "未选择", "선택 안 됨", "No seleccionada"],
    "元の位置に戻してタブから解除": [
        "Restore original position and release tab", "还原到原位置并解除标签页", "원래 위치로 되돌리고 탭에서 해제",
        "Restaurar posición original y liberar pestaña",
    ],
    "権限設定\n%@": ["Permission Settings\n%@", "权限设置\n%@", "권한 설정\n%@", "Ajustes de permisos\n%@"],
]
