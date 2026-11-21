import AppKit
import WindowDockCore

private final class TabLayoutDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(board: NSPasteboard, source: NSButton, window: NSWindow, location: NSPoint) {
        draggingPasteboard = board
        draggingSource = source
        draggingDestinationWindow = window
        draggingLocation = location
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class TitlebarControlProbe: NSButton {
    var mouseDownCount = 0

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }
}

private final class PaneCellProbe: NSView {
    var mouseDownCount = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }
}

private final class FrameChangeProbe: WorkspaceBackgroundView {
    var onPrepare: ((NSRect, NSRect) -> Void)?
    var onPrepared: (() -> Void)?
    var finishedChanges = 0

    override func prepareForFrameChange(to frame: NSRect) {
        if let window { onPrepare?(window.frame, frame) }
        super.prepareForFrameChange(to: frame)
        onPrepared?()
    }

    override func finishFrameChange() {
        super.finishFrameChange()
        finishedChanges += 1
    }
}

@main
enum TabLayoutSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 760),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false
        )
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.workspaceButton.title = "Workspace"
        var failures: [String] = []

        func settle() {
            for _ in 0..<4 {
                chrome.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func checkVisible(_ label: String) {
            settle()
            let visible = chrome.tabs.visibleRect
            print("\(label): strip=\(chrome.tabs.frame), visible=\(visible)")
            if visible.width < 80 || visible.height < 28 {
                failures.append("\(label): tab viewport collapsed")
            }
            for control in [chrome.addButton, chrome.columnSelector, chrome.rowSelector, chrome.permissionButton] {
                let frame = chrome.convert(control.bounds, from: control)
                if frame.isEmpty || !chrome.bounds.contains(frame) {
                    failures.append("\(label): toolbar control is clipped")
                }
            }
            let nameWidth = chrome.workspaceButton.frame.width
            if nameWidth > ceil(chrome.workspaceButton.intrinsicContentSize.width) + 0.5 {
                failures.append("\(label): workspace name is wider than its text (\(nameWidth))")
            }
            for group in chrome.tabs.arrangedSubviews {
                guard let tab = (group as? WorkspaceTabGroup)?.arrangedSubviews.first as? NSButton else {
                    failures.append("\(label): tab button missing")
                    continue
                }
                if group.isHidden || tab.isHidden || tab.bounds.width < 47.5 || tab.bounds.height < 28 {
                    failures.append("\(label): tab has no usable size")
                }
            }
        }
        settle()
        let shortTitle = chrome.appendTab(title: "Tools", selected: false)
        let iconTitle = chrome.appendTab(title: "Tools", icon: NSImage(size: NSSize(width: 16, height: 16)), selected: false)
        let longTitle = chrome.appendTab(title: String(repeating: "Long application window title ", count: 4), selected: true)
        checkVisible("mixed title lengths")
        let shortWidth = shortTitle.select.bounds.width
        let longWidth = longTitle.select.bounds.width
        let shortPreferred = min(200, max(48, ceil(shortTitle.select.intrinsicContentSize.width)))
        let iconPreferred = min(200, max(48, ceil(iconTitle.select.intrinsicContentSize.width)))
        if abs(shortWidth - shortPreferred) > 0.5 ||
            abs(iconTitle.select.bounds.width - iconPreferred) > 0.5 ||
            longWidth <= shortWidth + 40 {
            failures.append("short tabs did not fit their text/icon content independently of long titles")
        }
        for _ in 0..<5 {
            chrome.appendTab(title: String(repeating: "Another long window ", count: 4), selected: false)
        }
        checkVisible("mixed title lengths when crowded")
        if longTitle.select.bounds.width >= longWidth || abs(shortTitle.select.bounds.width - shortWidth) > 0.5 {
            failures.append("crowding did not shrink long tabs while preserving the short tab's preferred width")
        }
        chrome.clearTabs()
        settle()
        let single = chrome.appendTab(title: "First application window", selected: true)
        checkVisible("first tab after empty layout")
        let singleWidth = single.select.bounds.width
        for index in 1..<7 {
            chrome.appendTab(title: "Application \(index)", selected: false)
        }
        checkVisible("seven tabs")
        if single.select.bounds.width >= singleWidth {
            failures.append("tabs did not shrink as more were added")
        }
        let wideWidth = single.select.bounds.width
        _ = chrome.showNotice(.attention("Constraint warning"))
        settle()
        let warningStageHeight = chrome.stage.frame.height
        if chrome.showNotice(.attention("Constraint warning")) {
            failures.append("repeating the warning changed the notice bar height")
        }
        _ = chrome.showNotice(.information("Normal tab"))
        settle()
        if abs(chrome.stage.frame.height - warningStageHeight - 22) > 0.5 {
            failures.append("switching to a normal tab did not immediately remove the warning bar")
        }
        host.setFrame(NSRect(x: 100, y: 100, width: 720, height: 480), display: false)
        checkVisible("seven tabs in narrow window")
        if single.select.bounds.width > wideWidth + 0.5 {
            failures.append("tabs grew when the window narrowed")
        }
        for index in 7..<20 {
            chrome.appendTab(title: "Application \(index)", selected: false)
        }
        checkVisible("twenty tabs")
        chrome.workspaceButton.title = String(repeating: "Long workspace name ", count: 6)
        checkVisible("long workspace name with crowded tabs")
        if chrome.workspaceButton.frame.width > 49 {
            failures.append("crowded tabs did not take space from the workspace name")
        }
        chrome.workspaceButton.title = "Workspace"
        if chrome.tabs.bounds.width <= chrome.tabs.visibleRect.width {
            failures.append("minimum-width tabs did not scroll")
        }
        if let last = chrome.tabs.arrangedSubviews.last {
            chrome.revealTab(last)
            if !chrome.tabs.visibleRect.contains(last.frame) {
                failures.append("last tab could not be revealed")
            }
        }
        chrome.clearTabs()
        settle()
        chrome.appendTab(title: "First application window", selected: true)
        checkVisible("first tab after clear")
        if let tab = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first,
           tab.bounds.width <= wideWidth {
            failures.append("tab did not expand again after removing other tabs")
        }
        let target = chrome.appendTab(title: "Drag target", selected: false)
        let board = NSPasteboard(name: NSPasteboard.Name("TabLayoutSmoke-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        for frame in [
            NSRect(x: 0, y: 0, width: 1400, height: 900),
            NSRect(x: 260, y: 190, width: 900, height: 600)
        ] {
            host.setFrame(frame, display: false)
            settle()
            let source = (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
            let group = source.superview!
            let anchor = NSPoint(x: 15, y: source.bounds.midY)
            let anchorInGroup = source.convert(anchor, to: group)
            chrome.beginTabDrag(source: source, token: "geometry", anchor: anchor)
            board.setString("geometry", forType: workspaceTabDragType)
            let destination = target.select.convert(NSPoint(x: target.select.bounds.midX, y: target.select.bounds.midY), to: nil)
            let info = TabLayoutDragInfo(board: board, source: source, window: host, location: destination)
            _ = target.select.draggingUpdated(info)
            let actualAnchor = group.convert(anchorInGroup, to: nil)
            if abs(actualAnchor.x - destination.x) > 1 || chrome.tabDragPreviewPanel?.isVisible == true {
                failures.append("resized window: reordered tab is not under the pointer")
            }
            let panePoint = chrome.gridAreas[0].convert(NSPoint(x: 100, y: 100), to: nil)
            let paneInfo = TabLayoutDragInfo(board: board, source: source, window: host, location: panePoint)
            let overlay = chrome.gridAreas[0].subviews.last!
            _ = overlay.draggingUpdated(paneInfo)
            let paneScreenPoint = host.convertPoint(toScreen: panePoint)
            let previewAligned = chrome.tabDragPreviewPanel.map {
                $0.isVisible &&
                abs($0.frame.minX + anchorInGroup.x - paneScreenPoint.x) <= 1 &&
                abs($0.frame.minY + anchorInGroup.y - paneScreenPoint.y) <= 1
            } ?? false
            if !previewAligned {
                failures.append("resized window: pane preview is not under the pointer")
            }
            chrome.endTabDrag()
        }
        chrome.setGrid(.single, activeCell: 0)
        settle()
        do {
            let source = (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
            chrome.beginTabDrag(source: source, token: "single-pane")
            board.setString("single-pane", forType: workspaceTabDragType)
            let pane = chrome.gridAreas[0]
            let panePoint = host.convertPoint(toScreen: pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil))
            _ = chrome.updateFloatingTab(pasteboard: board, source: source, screenPoint: panePoint)
            if pane.subviews.contains(where: { $0 is WorkspaceTabDropOverlay }) ||
                chrome.tabDragPreviewPanel?.isVisible == true ||
                (source.superview as? WorkspaceTabGroup)?.isFloating != true {
                failures.append("a single pane offered a meaningless move-here target instead of keeping the tab in the strip")
            }
            chrome.endTabDrag()
        }
        settle()
        chrome.showManagedWindows(true)
        let area = chrome.gridAreas[0]
        let areaScreenFrame = host.convertToScreen(area.convert(area.bounds, to: nil))
        let oldRenderedFrame = areaScreenFrame.offsetBy(dx: -80, dy: 0)
        if let coverage = WindowGeometry.confirmedCoverage(for: areaScreenFrame, renderedFrames: [oldRenderedFrame]) {
            chrome.presentFrames([0: coverage])
        } else {
            failures.append("moving pane lost its overlapping coverage")
        }
        if let bitmap = chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds) {
            chrome.cacheDisplay(in: chrome.bounds, to: bitmap)
            for (localPoint, transparent) in [
                (NSPoint(x: area.bounds.midX, y: area.bounds.midY), true),
                (NSPoint(x: area.bounds.maxX - 10, y: area.bounds.midY), false)
            ] {
                let point = chrome.convert(localPoint, from: area)
                let color = bitmap.colorAt(
                    x: Int(point.x * CGFloat(bitmap.pixelsWide) / chrome.bounds.width),
                    y: Int((chrome.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / chrome.bounds.height)
                )
                if let alpha = color?.alphaComponent {
                    if transparent ? alpha > 0.01 : alpha < 0.99 {
                        failures.append("moving pane blanked safe overlap or exposed its uncovered edge")
                    }
                } else {
                    failures.append("could not sample moving pane coverage")
                }
            }
        } else {
            failures.append("could not render moving pane coverage")
        }
        let probeHost = WorkspaceWindow(contentRect: NSRect(x: 150, y: 150, width: 500, height: 400),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        probeHost.isReleasedWhenClosed = false
        let probe = FrameChangeProbe(frame: .zero)
        probeHost.contentView = probe
        let probeArea = NSView(frame: NSRect(x: 10, y: 10, width: 480, height: 380))
        probe.addSubview(probeArea)
        probe.contentArea = probeArea
        probe.revealsWindow = true
        var preparedChanges = 0
        for iteration in 0..<30 {
            let oldFrame = probeHost.frame
            let nextFrame = oldFrame.offsetBy(dx: iteration.isMultiple(of: 2) ? 100 : -100, dy: 15)
            probe.coveredScreenRect = probeHost.convertToScreen(probeArea.frame)
            probe.onPrepare = { old, proposed in
                preparedChanges += 1
                if old != oldFrame || proposed != nextFrame {
                    failures.append("fast native move prepared coverage after changing the frame")
                }
            }
            probe.onPrepared = {
                guard let bitmap = probe.bitmapImageRepForCachingDisplay(in: probe.bounds) else {
                    failures.append("could not render the pre-move mask")
                    return
                }
                probe.cacheDisplay(in: probe.bounds, to: bitmap)
                let x = iteration.isMultiple(of: 2) ? probeArea.frame.maxX - 5 : probeArea.frame.minX + 5
                let y = probeArea.frame.midY
                let color = bitmap.colorAt(
                    x: Int(x * CGFloat(bitmap.pixelsWide) / probe.bounds.width),
                    y: Int((probe.bounds.height - y) * CGFloat(bitmap.pixelsHigh) / probe.bounds.height)
                )
                if (color?.alphaComponent ?? 0) < 0.99 {
                    failures.append("fast native move left its exposed edge transparent before moving")
                }
            }
            if iteration.isMultiple(of: 2) {
                probeHost.setFrame(nextFrame, display: true)
            } else {
                probeHost.setFrameOrigin(nextFrame.origin)
            }
        }
        if preparedChanges != 30 || probe.finishedChanges != 30 {
            failures.append("native frame changes bypassed the pre-move coverage update")
        }
        probeHost.close()
        if WorkspaceController(name: "Smoke").window.isMovable {
            failures.append("workspace windows use server-side titlebar dragging, which skips the pre-move transparency mask")
        }
        let titleHost = WorkspaceWindow(
            contentRect: NSRect(x: 150, y: 150, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titleHost.isReleasedWhenClosed = false
        titleHost.isMovable = false
        titleHost.titlebarAppearsTransparent = true
        titleHost.titleVisibility = .hidden
        let titleProbe = FrameChangeProbe(frame: .zero)
        titleHost.contentView = titleProbe
        titleHost.orderFront(nil)
        let titleFrame = titleHost.frame
        let pressPoint = NSPoint(x: 250, y: titleHost.contentLayoutRect.maxY + 8)
        let pressScreen = titleHost.convertPoint(toScreen: pressPoint)
        if let screen = NSScreen.screens.first,
           let down = NSEvent.mouseEvent(
               with: .leftMouseDown, location: pressPoint, modifierFlags: [],
               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: titleHost.windowNumber,
               context: nil, eventNumber: 1, clickCount: 1, pressure: 1
           ) {
            var queuedEvents: [NSEvent] = []
            for (offset, type) in [
                (CGFloat(120), CGEventType.leftMouseDragged),
                (CGFloat(-80), CGEventType.leftMouseDragged),
                (CGFloat(180), CGEventType.leftMouseDragged),
                (CGFloat(180), CGEventType.leftMouseUp)
            ] {
                let screenPoint = CGPoint(x: pressScreen.x + offset, y: screen.frame.maxY - pressScreen.y)
                if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type,
                                         mouseCursorPosition: screenPoint, mouseButton: .left),
                   let event = NSEvent(cgEvent: cgEvent) {
                    queuedEvents.append(event)
                }
            }
            if queuedEvents.count == 4 {
                // These events stay in this test application's queue; they do not move the system pointer.
                for event in queuedEvents { NSApp.postEvent(event, atStart: false) }
                titleHost.sendEvent(down)
                if titleProbe.finishedChanges != 3 ||
                    titleHost.frame != titleFrame.offsetBy(dx: 180, dy: 0) {
                    failures.append("titlebar mouse tracking bypassed application-controlled frame changes")
                }
            } else {
                failures.append("could not create titlebar tracking events")
            }
        } else {
            failures.append("could not prepare titlebar mouse tracking")
        }
        let control = TitlebarControlProbe(frame: NSRect(
            x: 320, y: titleHost.contentLayoutRect.maxY + 1, width: 100, height: 20
        ))
        titleProbe.addSubview(control)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: control.frame.midX, y: control.frame.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: titleHost.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ) {
            titleHost.sendEvent(event)
            if control.mouseDownCount != 1 || titleProbe.finishedChanges != 3 {
                failures.append("titlebar control clicks=\(control.mouseDownCount), frame changes=\(titleProbe.finishedChanges)")
            }
        } else {
            failures.append("could not create a titlebar control click")
        }
        control.removeFromSuperview()
        let paneCell = PaneCellProbe(frame: titleProbe.bounds.insetBy(dx: 3, dy: 3))
        titleProbe.addSubview(paneCell)
        var resizeEventNumber = 10
        func dragTitleHost(from point: NSPoint, by delta: NSSize) -> NSRect? {
            resizeEventNumber += 1
            guard let screen = NSScreen.screens.first,
                  let down = NSEvent.mouseEvent(
                      with: .leftMouseDown, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: titleHost.windowNumber,
                      context: nil, eventNumber: resizeEventNumber, clickCount: 1, pressure: 1
                  ) else { return nil }
            let start = titleHost.convertPoint(toScreen: point)
            var queued: [NSEvent] = []
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let location = CGPoint(x: start.x + delta.width, y: screen.frame.maxY - (start.y + delta.height))
                if let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type,
                                         mouseCursorPosition: location, mouseButton: .left),
                   let event = NSEvent(cgEvent: cgEvent) {
                    queued.append(event)
                }
            }
            guard queued.count == 2 else { return nil }
            for event in queued { NSApp.postEvent(event, atStart: false) }
            titleHost.sendEvent(down)
            return titleHost.frame
        }
        let resizeChecks: [(String, (NSRect) -> NSPoint, NSSize, (NSRect) -> NSRect)] = [
            ("top edge", { NSPoint(x: $0.midX, y: $0.maxY - 2) }, NSSize(width: 0, height: 30),
             { NSRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + 30) }),
            ("top-right corner", { NSPoint(x: $0.maxX - 2, y: $0.maxY - 2) }, NSSize(width: 20, height: 20),
             { NSRect(x: $0.minX, y: $0.minY, width: $0.width + 20, height: $0.height + 20) }),
            ("right edge over a pane cell", { NSPoint(x: $0.maxX - 6, y: $0.midY) }, NSSize(width: 25, height: 0),
             { NSRect(x: $0.minX, y: $0.minY, width: $0.width + 25, height: $0.height) }),
            ("bottom-right grip", { NSPoint(x: $0.maxX - 12, y: 12) }, NSSize(width: 30, height: -20),
             { NSRect(x: $0.minX, y: $0.minY - 20, width: $0.width + 30, height: $0.height + 20) })
        ]
        for (label, point, delta, expected) in resizeChecks {
            let before = titleHost.frame
            paneCell.frame = titleProbe.bounds.insetBy(dx: 3, dy: 3)
            let after = dragTitleHost(from: point(titleProbe.bounds), by: delta)
            if after != expected(before) || paneCell.mouseDownCount != 0 {
                failures.append("\(label) moved or was swallowed instead of resizing: \(before) -> \(String(describing: after))")
            }
        }
        let beforeCenterClick = titleHost.frame
        paneCell.frame = titleProbe.bounds.insetBy(dx: 3, dy: 3)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: titleProbe.bounds.midX, y: titleProbe.bounds.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: titleHost.windowNumber, context: nil, eventNumber: 30, clickCount: 1, pressure: 1
        ) {
            titleHost.sendEvent(event)
            if paneCell.mouseDownCount != 1 || titleHost.frame != beforeCenterClick {
                failures.append("a click inside a pane was taken by workspace resizing: clicks=\(paneCell.mouseDownCount) \(beforeCenterClick) -> \(titleHost.frame)")
            }
        }
        titleHost.close()
        let otherHost = WorkspaceWindow(contentRect: NSRect(x: 1400, y: 120, width: 900, height: 600),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        otherHost.isReleasedWhenClosed = false
        let otherChrome = WorkspaceChromeView(frame: .zero)
        otherHost.contentView = otherChrome
        for index in 0..<3 {
            let tab = otherChrome.appendTab(title: "Destination \(index)", selected: index == 0)
            tab.select.tag = index
        }
        otherChrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        otherChrome.layoutSubtreeIfNeeded()
        let source = (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! WorkspaceTabButton
        let transferToken = "cross-workspace"
        board.setString(transferToken, forType: workspaceTabDragType)
        chrome.beginTabDrag(source: source, token: transferToken)
        otherChrome.acceptsExternalTab = { token, button in token == transferToken && button === source }
        otherChrome.showExternalTabTargets()
        let destinationGroup = otherChrome.tabs.arrangedSubviews[1] as! WorkspaceTabGroup
        let destinationButton = destinationGroup.arrangedSubviews.first as! WorkspaceTabButton
        var received: (String, Int?, Int?)?
        otherChrome.onExternalTabDrop = { token, button, index, cell in
            guard button === source else { return false }
            received = (token, index, cell)
            return true
        }
        let tabPoint = destinationButton.convert(NSPoint(x: 1, y: destinationButton.bounds.midY), to: nil)
        let tabInfo = TabLayoutDragInfo(board: board, source: source, window: otherHost, location: tabPoint)
        let entered = destinationButton.draggingEntered(tabInfo)
        let tabMarkerFrame = otherChrome.windowDropPanel?.frame
        let previousKey = NSApp.keyWindow
        if let marker = otherChrome.windowDropPanel {
            if marker.frame != tabMarkerFrame || marker.frame.width != 3 || marker.frame.height != 28 ||
                !marker.isVisible || !marker.ignoresMouseEvents || marker.isKeyWindow ||
                NSApp.keyWindow !== previousKey ||
                marker.contentView?.subviews.contains(where: { $0 is NSTextField }) == true {
                failures.append("tab transfers did not retain their thin, nonactivating insertion line")
            }
            let expectedX = otherHost.convertPoint(toScreen: destinationGroup.convert(.zero, to: nil)).x
            if abs(marker.frame.minX - expectedX) > 1 || otherChrome.tabInsertionIndex(at: otherHost.convertPoint(toScreen: tabPoint)) != 1 {
                failures.append("the insertion line did not match its actual tab insertion position")
            }
        } else {
            failures.append("the tab insertion line was not created")
        }
        otherChrome.showWindowDropTarget(at: otherHost.convertPoint(toScreen: tabPoint), requiresPermission: false)
        if let panel = otherChrome.windowDropPanel {
            let messages = panel.contentView?.subviews.compactMap { view -> String? in
                guard let label = view as? NSTextField, !label.isHidden else { return nil }
                return label.stringValue
            } ?? []
            if panel.frame.width != otherChrome.bounds.width || panel.frame.height != 34 ||
                !messages.contains(L("ここで離すとタブに追加")) ||
                !panel.ignoresMouseEvents || panel.isKeyWindow || NSApp.keyWindow !== previousKey {
                failures.append("ordinary window addition did not restore the nonactivating blue toolbar message")
            }
        } else {
            failures.append("the ordinary window-addition bar was not created")
        }
        _ = destinationButton.draggingUpdated(tabInfo)
        if otherChrome.windowDropPanel?.frame != tabMarkerFrame ||
            otherChrome.windowDropPanel?.contentView?.subviews.contains(where: { !$0.isHidden && $0 is NSTextField }) == true {
            failures.append("switching from window addition to tab transfer retained a wide bar or visible label")
        }
        if entered != .move ||
            chrome.tabDragPreviewPanel?.isVisible != true ||
            !destinationButton.performDragOperation(tabInfo) || received?.1 != 1 || received?.2 != nil {
            failures.append("another workspace rejected the tab, lost its preview, or chose the wrong insertion index")
        }
        received = nil
        let cell = otherChrome.gridAreas[0]
        let cellPoint = cell.convert(NSPoint(x: 100, y: 100), to: nil)
        let cellInfo = TabLayoutDragInfo(board: board, source: source, window: otherHost, location: cellPoint)
        if !otherChrome.performDragOperation(cellInfo) || received?.2 != 0 || received?.1 != nil {
            failures.append("cross-workspace pane drop did not select the destination pane")
        }
        otherChrome.hideExternalTabTargets()
        otherChrome.setGrid(.single, activeCell: 0)
        otherChrome.layoutSubtreeIfNeeded()
        otherChrome.showExternalTabTargets()
        received = nil
        let singlePane = otherChrome.gridAreas[0]
        let singlePanePoint = singlePane.convert(NSPoint(x: singlePane.bounds.midX, y: singlePane.bounds.midY), to: nil)
        let singlePaneInfo = TabLayoutDragInfo(board: board, source: source, window: otherHost, location: singlePanePoint)
        let expectedIndex = otherChrome.tabInsertionIndex(at: otherHost.convertPoint(toScreen: singlePanePoint))
        if singlePane.subviews.contains(where: { $0 is WorkspaceTabDropOverlay }) ||
            otherChrome.draggingUpdated(singlePaneInfo) != .move ||
            otherChrome.windowDropPanel?.isVisible != true || otherChrome.windowDropPanel?.frame.width != 3 ||
            !otherChrome.performDragOperation(singlePaneInfo) || received?.1 != expectedIndex || received?.2 != nil {
            failures.append("a single-pane workspace did not treat its pane as the tab bar for cross-workspace drops")
        }
        board.setString("stale-token", forType: workspaceTabDragType)
        if destinationButton.draggingEntered(tabInfo) != [] || destinationButton.performDragOperation(tabInfo) {
            failures.append("another workspace accepted a stale tab drag")
        }
        otherChrome.clearTabs()
        otherChrome.layoutSubtreeIfNeeded()
        board.setString(transferToken, forType: workspaceTabDragType)
        received = nil
        let emptyInfo = TabLayoutDragInfo(
            board: board, source: source, window: otherHost,
            location: NSPoint(x: 150, y: otherChrome.bounds.maxY - 16)
        )
        if otherChrome.draggingEntered(emptyInfo) != .move || !otherChrome.performDragOperation(emptyInfo) ||
            received?.1 != 0 || received?.2 != nil {
            failures.append("an empty workspace could not receive its first tab")
        }
        otherChrome.hideExternalTabTargets()
        if cell.subviews.contains(where: { $0 is WorkspaceTabDropOverlay }) || otherChrome.windowDropPanel?.isVisible == true {
            failures.append("cross-workspace target cleanup left pane overlays behind")
        }
        chrome.endTabDrag()
        var ended: (String, Bool)?
        chrome.onTabDragEnd = { token, _, _, cancelled in ended = (token, cancelled) }
        source.onDragBegin?(source, transferToken, NSPoint(x: 10, y: 10), NSImage(size: NSSize(width: 100, height: 32)))
        chrome.endTabDrag()
        source.onDragEnd?(board, NSPoint(x: 1800, y: 100), true)
        if ended?.0 != transferToken || ended?.1 != true {
            failures.append("ending a cancelled or already-cleaned drag lost its transfer token")
        }
        otherHost.close()
        var mouseCompletions: [(NSPoint, Bool)] = []
        chrome.onTabDragEnd = { token, board, point, cancelled in
            if board.string(forType: workspaceTabDragType) != token {
                failures.append("mouse tracking lost its transfer token before completion")
            }
            mouseCompletions.append((point, cancelled))
            if !cancelled, host.frame.contains(point) {
                _ = chrome.completeTabDrop(pasteboard: board, source: source, screenPoint: point)
            }
        }
        func replayTabDrag(to destination: NSPoint, escape: Bool, completes: Bool = true) {
            guard let screen = NSScreen.screens.first else {
                failures.append("could not find a screen for mouse tracking")
                return
            }
            let press = source.convert(NSPoint(x: 15, y: source.bounds.midY), to: nil)
            let start = host.convertPoint(toScreen: press)
            var events: [NSEvent] = []
            for (point, type) in [
                (NSPoint(x: start.x + 6, y: start.y), CGEventType.leftMouseDragged),
                (destination, CGEventType.leftMouseDragged)
            ] {
                if let cg = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: point.x, y: screen.frame.maxY - point.y), mouseButton: .left
                ), let event = NSEvent(cgEvent: cg) { events.append(event) }
            }
            let completion: NSEvent?
            if escape {
                completion = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                )
            } else {
                completion = CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: CGPoint(x: destination.x, y: screen.frame.maxY - destination.y),
                    mouseButton: .left
                ).flatMap { NSEvent(cgEvent: $0) }
            }
            guard events.count == 2, let completion,
                  let down = NSEvent.mouseEvent(
                      with: .leftMouseDown, location: press, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                      context: nil, eventNumber: 3, clickCount: 1, pressure: 1
                  ) else {
                failures.append("could not create tab mouse tracking events")
                return
            }
            if completes { events.append(completion) }
            for event in events { NSApp.postEvent(event, atStart: false) }
            source.mouseDown(with: down)
        }
        let outside = NSPoint(x: host.frame.maxX + 300, y: host.frame.midY)
        let originalViews = chrome.tabs.arrangedSubviews.map { ObjectIdentifier($0) }
        replayTabDrag(to: outside, escape: false)
        if mouseCompletions.count != 1 || mouseCompletions.first?.0 != outside ||
            mouseCompletions.first?.1 != false ||
            chrome.tabs.arrangedSubviews.map({ ObjectIdentifier($0) }) != originalViews ||
            chrome.tabDragPreviewPanel?.isVisible == true {
            failures.append("releasing a tab outside was lost or classified as cancellation")
        }
        replayTabDrag(to: outside, escape: true)
        if mouseCompletions.count != 2 || mouseCompletions.last?.1 != true ||
            chrome.tabDragPreviewPanel?.isVisible == true {
            failures.append("Escape did not cancel tab tracking and remove its preview")
        }
        for (index, group) in chrome.tabs.arrangedSubviews.enumerated() {
            (group as! WorkspaceTabGroup).arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first?.tag = index
        }
        var committedOrder: [Int]?
        chrome.onReorderTabs = { committedOrder = $0 }
        let neighbor = chrome.tabs.arrangedSubviews[1]
        let neighborPoint = host.convertPoint(toScreen: neighbor.convert(
            NSPoint(x: neighbor.bounds.maxX - 5, y: neighbor.bounds.midY), to: nil
        ))
        replayTabDrag(to: neighborPoint, escape: false)
        if committedOrder != [1, 0] {
            failures.append("application-controlled mouse tracking no longer committed local tab reordering")
        }
        var movedCell: Int?
        chrome.onMoveTab = { _, cell in movedCell = cell }
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        settle()
        let ownPane = chrome.gridAreas[0]
        replayTabDrag(to: host.convertPoint(toScreen: ownPane.convert(
            NSPoint(x: ownPane.bounds.midX, y: ownPane.bounds.midY), to: nil
        )), escape: false)
        if movedCell != 0 {
            failures.append("application-controlled mouse tracking no longer committed local pane moves")
        }
        chrome.setGrid(.single, activeCell: 0)
        settle()
        for (index, group) in chrome.tabs.arrangedSubviews.enumerated() {
            (group as! WorkspaceTabGroup).arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first?.tag = index
        }
        movedCell = nil
        committedOrder = nil
        let tabViews = chrome.tabs.arrangedSubviews
        let sourceGroup = source.superview!
        let sourceIndex = tabViews.firstIndex(of: sourceGroup)!
        let neighborIndex = sourceIndex + 1 < tabViews.count ? sourceIndex + 1 : sourceIndex - 1
        let neighborFrame = chrome.tabs.convert(tabViews[neighborIndex].frame, to: nil)
        let floatingCenter = neighborIndex > sourceIndex ? neighborFrame.maxX - 2 : neighborFrame.minX + 2
        let pressOffset = source.convert(NSPoint(x: 15, y: 0), to: sourceGroup).x
        let destinationX = floatingCenter - sourceGroup.frame.width / 2 + pressOffset
        let onlyPane = chrome.gridAreas[0]
        let onlyPaneY = onlyPane.convert(NSPoint(x: 0, y: onlyPane.bounds.midY), to: nil).y
        replayTabDrag(to: host.convertPoint(toScreen: NSPoint(x: destinationX, y: onlyPaneY)), escape: false)
        var expectedOrder = Array(0..<tabViews.count)
        expectedOrder.swapAt(sourceIndex, neighborIndex)
        if movedCell != nil || committedOrder != expectedOrder {
            failures.append("releasing a tab over the only pane did not reorder it like the tab bar: moved=\(String(describing: movedCell)) order=\(String(describing: committedOrder)) expected=\(expectedOrder) tag=\(source.tag)")
        }
        // Another app activated during the drag may receive its mouse-up; tracking must end once the button is up.
        let completionsBeforeLostRelease = mouseCompletions.count
        var trackingHung = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard mouseCompletions.count == completionsBeforeLostRelease, let screen = NSScreen.screens.first else { return }
            trackingHung = true
            let point = CGPoint(x: outside.x, y: screen.frame.maxY - outside.y)
            if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                .flatMap({ NSEvent(cgEvent: $0) }) {
                NSApp.postEvent(up, atStart: false)
            }
        }
        replayTabDrag(to: outside, escape: false, completes: false)
        if trackingHung || mouseCompletions.count != completionsBeforeLostRelease + 1 ||
            mouseCompletions.last?.1 != false || chrome.tabDragPreviewPanel?.isVisible == true {
            failures.append("a tab drag whose mouse-up went to another app kept tracking after the button was released")
        }
        host.close()
        if failures.isEmpty {
            print("PASS: tab layout, cross-workspace drops, actual tab mouse release/Escape, and movement masks")
            exit(0)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(1)
    }
}
