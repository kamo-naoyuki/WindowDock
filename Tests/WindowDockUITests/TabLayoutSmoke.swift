import AppKit
import QuartzCore
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
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class TitlebarControlProbe: NSButton {
    var mouseDownCount = 0

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }
}

private final class TabBarTrackingEvent: NSEvent {
    var area: NSTrackingArea?
    override var trackingArea: NSTrackingArea? { area }
}

private final class TabCloseProbe: NSObject {
    var remove: (Int) -> Void = { _ in }
    @objc func click(_ sender: NSButton) { remove(sender.tag) }
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
    private static func checkCloseSlotsAndWrapping() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 930, height: 600),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        host.orderBack(nil)
        defer { host.close() }
        var failures: [String] = []
        let click = TabCloseProbe()
        let tracking = TabBarTrackingEvent()
        tracking.area = chrome.addButton.superview?.trackingAreas.first { $0.owner === chrome }
        guard tracking.area != nil else { return ["missing tab bar pointer tracking"] }
        let all = (0 ..< 27).map {
            WorkspaceTabItem(id: UUID(), title: $0.isMultiple(of: 2) ? "A" : "A longer title", selected: $0 == 0)
        }
        var items = all
        var groups: [WorkspaceChromeView.Tab] = []
        func layout() {
            chrome.layoutSubtreeIfNeeded()
            chrome.tabs.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func settle() {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.24))
            layout()
        }
        func render() {
            groups = chrome.setTabs(items)
            for (index, tab) in groups.enumerated() {
                tab.select.tag = index
                tab.close.tag = index
                tab.close.target = click
                tab.close.action = #selector(TabCloseProbe.click(_:))
            }
            if let first = groups.first { chrome.revealTab(first.view) }
            layout()
        }
        click.remove = { items.remove(at: $0); render() }
        defer { click.remove = { _ in } }
        func screenPoint(_ view: NSView, x: CGFloat? = nil) -> NSPoint {
            view.window!
                .convertPoint(toScreen: view.convert(NSPoint(x: x ?? view.bounds.midX, y: view.bounds.midY), to: nil))
        }
        func closeTwice(at slot: Int) {
            let point = screenPoint(groups[slot].close)
            let viewport = chrome.tabs.visibleRect
            chrome.mouseEntered(with: tracking)
            for _ in 0 ..< 2 {
                let next = groups[slot + 1].id
                let hit = chrome.hitTest(host.convertPoint(fromScreen: point))
                if hit !== groups[slot].close {
                    failures.append("slot \(slot): repeated click missed × at \(point)")
                    break
                }
                (hit as? NSButton)?.performClick(nil)
                let center = screenPoint(groups[slot].close)
                if groups[slot].id != next || abs(center.x - point.x) > 1 || abs(center.y - point.y) > 1
                    || chrome.tabs.visibleRect != viewport {
                    failures
                        .append(
                            "slot \(slot): next × moved from \(point) to \(center), viewport \(viewport) → \(chrome.tabs.visibleRect)")
                }
            }
        }
        for (count, scroll) in [(7, false), (all.count, true)] {
            items = Array(all.prefix(count))
            render()
            settle()
            if scroll { chrome.revealTab(groups[count - 1].view) }
            let slot = scroll ? count - 4 : 2
            let width = groups[slot].view.bounds.width
            closeTwice(at: slot)
            chrome.mouseExited(with: tracking)
            layout()
            if !scroll, groups[slot].view.bounds.width <= width + 1 {
                failures.append("leaving the tab bar did not redistribute freed space")
            }
        }

        chrome.wrapsCrowdedTabs = true
        for position: TabBarPosition in [.top, .bottom] {
            chrome.setTabBarPosition(position)
            items = all
            render()
            settle()
            guard let split = chrome.tabs.secondRow, split < groups.count else {
                failures.append("\(position): overflow did not wrap")
                continue
            }
            let second = groups[split]
            let topFrame = groups[0].view.frame, lower = second.view.frame
            if lower.maxY > topFrame.minY || lower.minX != topFrame.minX || abs(lower.width - topFrame.width) > 1
                || chrome.tabs.visibleRect.width >= chrome.tabs.bounds.width {
                failures.append("\(position): crowded rows did not align or scroll together: \(topFrame), \(lower)")
            }
            let point = screenPoint(second.view, x: 1)
            if chrome.tabInsertionIndex(at: point) != split || chrome
                .hitTest(host.convertPoint(fromScreen: screenPoint(second.close))) !== second.close {
                failures.append("\(position): could not target the first tab in the second row")
            }
            chrome.showWindowDropTarget(at: point, requiresPermission: false)
            if let preview = chrome.windowDropPreview as? WorkspaceTabGroup,
               chrome.tabs.arrangedSubviews.firstIndex(of: preview) == split,
               let title = preview.arrangedSubviews.first as? NSButton, title.alignment == .left {
                if abs(preview.frame.width - second.view.frame.width) >
                    1 { failures.append("drop preview width differs") }
            } else { failures.append("\(position): window preview did not follow the target row") }
            chrome.hideWindowDropTarget()
            layout()
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("across-rows", forType: workspaceTabDragType)
            let source = groups[0].select, destination = screenPoint(groups[split + 1].select)
            var reordered: [Int]?
            chrome.onReorderTabs = { reordered = $0 }
            chrome.beginTabDrag(source: source, token: "across-rows")
            if !chrome.performTabReorder(pasteboard: board, source: source, screenPoint: destination)
                || reordered?[split + 1] != 0 { failures.append("\(position): drag failed to reorder across rows") }
            chrome.setAutoHideTabBar(true)
            chrome.setAutoHiddenToolbarVisible(true)
            layout()
            if (chrome.autoHiddenToolbarPanel?.frame.height ?? 0) < chrome.tabs.bounds.height {
                failures.append("\(position): auto-hidden bar clipped its second row")
            }
            chrome.setAutoHideTabBar(false)
            chrome.mouseExited(with: tracking)
            let capacity =
                Int((chrome.tabs.visibleRect.width + chrome.tabs.spacing) / (topFrame.width + chrome.tabs.spacing))
            items = Array(all.prefix(capacity + 2))
            render()
            settle()
            guard let boundary = chrome.tabs.secondRow, boundary >= 1, boundary + 1 < groups.count else {
                failures.append("\(position): second row was not available for repeated closes")
                continue
            }
            closeTwice(at: boundary - 1)
            if chrome.tabs.secondRow != boundary { failures.append("\(position): row collapsed under the pointer") }
            chrome.mouseExited(with: tracking)
            settle()
            if chrome.tabs.secondRow != nil || chrome.tabs.visibleRect.height >= 64 {
                failures
                    .append(
                        "\(position): wrapping did not collapse: split=\(String(describing: chrome.tabs.secondRow)), strip=\(chrome.tabs.bounds), visible=\(chrome.tabs.visibleRect), widths=\(groups.map { $0.view.frame.width })")
            }
        }
        return failures
    }

    @MainActor
    private static func checkTabStripFeedback() -> [String] {
        let host = WorkspaceWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 640),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        host.orderBack(nil)
        defer { host.close() }
        var failures: [String] = []
        let first = WorkspaceTabItem(id: UUID(), title: "First", selected: true, displayed: true, pinned: true,
                                     tabSwitchTarget: true)
        let middle = WorkspaceTabItem(id: UUID(), title: "Middle", selected: false)
        let last = WorkspaceTabItem(id: UUID(), title: "Last", selected: false)
        func settle() {
            chrome.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.24))
        }
        for vertical in [false, true] {
            chrome.setTabBarPosition(vertical ? .left : .top)
            let existing = chrome.setTabs([first, last])
            settle()
            for adding in [true, false] {
                let neighbor = existing[1].view
                func position(_ view: NSView, presented: Bool) -> CGFloat {
                    guard let layer = view.layer, let root = chrome.addButton.superview?.layer else { return .nan }
                    let current = presented ? layer.presentation() ?? layer : layer
                    let target = presented ? root.presentation() ?? root : root
                    let frame = current.convert(current.bounds, to: target)
                    return vertical ? frame.midY : frame.midX
                }
                let before = position(neighbor, presented: false)
                let firstBefore = position(existing[0].view, presented: false)
                let plusBefore = position(chrome.addButton, presented: false)
                let next = chrome.setTabs(adding ? [first, middle, last] : [first, last])
                chrome.revealTab(next[0].view)
                func between(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool {
                    value.isFinite && value > min(a, b) + 1 && value < max(a, b) - 1
                }
                var samples: [(first: CGFloat, last: CGFloat, plus: CGFloat)] = []
                var entry: [(center: CGFloat, width: CGFloat)] = []
                let end = Date(timeIntervalSinceNow: 0.24)
                repeat {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.009))
                    samples.append((position(existing[0].view, presented: true), position(neighbor, presented: true),
                                    position(chrome.addButton, presented: true)))
                    if adding, let layer = next[1].view.layer?.presentation(), layer.opacity > 0.05 {
                        entry.append((position(next[1].view, presented: true), layer.frame.width))
                    }
                } while Date() < end
                let after = position(neighbor, presented: false)
                let firstAfter = position(existing[0].view, presented: false)
                let plusAfter = position(chrome.addButton, presented: false)
                let sawSlide = samples
                    .contains { between($0.last, before, after) || between($0.first, firstBefore, firstAfter) }
                let sawPlus = samples.contains { between($0.plus, plusBefore, plusAfter) }
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if adding {
                    let center = position(next[1].view, presented: false)
                    let width = next[1].view.frame.width
                    if entry.isEmpty || entry.contains(where: { abs($0.center - center) > 1.5 })
                        || entry.contains(where: { $0.width < width - 1 }) == reduce {
                        failures
                            .append(
                                "vertical=\(vertical): new tab should pop at \(center), not fly in: \(entry.prefix(4))")
                    }
                }
                if next.last?.view !== neighbor || max(abs(before - after), abs(firstBefore - firstAfter)) < 25
                    || sawSlide == reduce || (!vertical && (sawPlus == reduce || abs(plusBefore - plusAfter) < 25)) {
                    failures
                        .append(
                            "vertical=\(vertical) add=\(adding): first \(firstBefore)→\(firstAfter), last \(before)→\(after), slide=\(sawSlide); + \(plusBefore)→\(plusAfter), slide=\(sawPlus); reduce=\(reduce), samples=\(samples.prefix(4))")
                }
            }
        }
        let groups = chrome.setTabs([first, last]).map(\.view)
        for group in groups {
            guard group.trackingAreas.contains(where: {
                $0.owner === group && $0.options.contains([.mouseEnteredAndExited, .inVisibleRect])
            }), let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: host.windowNumber,
                                                   context: nil, eventNumber: 1, trackingNumber: 0, userData: nil),
                let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: host.windowNumber,
                                                  context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)
            else { return failures + ["missing tab-wide mouse tracking"] }
            group.mouseExited(with: exit)
            let base = group.layer?.backgroundColor
            let border = group.layer?.borderColor
            group.mouseEntered(with: enter)
            if group.layer?.backgroundColor == base || group.layer?.borderColor != border {
                failures.append("hover did not change the tab fill independently of the selection border")
            }
            guard let close = group.arrangedSubviews.last as? NSButton,
                  close.trackingAreas.contains(where: { $0.options.contains(.mouseEnteredAndExited) })
            else { return failures + ["the close button does not track its own hover"] }
            let tabFill = group.layer?.backgroundColor
            close.mouseEntered(with: enter)
            if (close.layer?.backgroundColor?.alpha ?? 0) < 0.22 || group.layer?.backgroundColor != tabFill {
                failures.append("the × did not gain a stronger local highlight over the hovered tab")
            }
            close.mouseExited(with: exit)
            if (close.layer?.backgroundColor?.alpha ?? 0) != 0 || group.layer?.backgroundColor != tabFill {
                failures.append("leaving × did not clear just its highlight")
            }
            group.mouseExited(with: exit)
            if group.layer?.backgroundColor != base { failures.append("tab remained highlighted after mouse exit") }
        }
        for closesWindow in [false, true] {
            chrome.closesWindowsOnRelease = closesWindow
            let close = chrome.setTabs([first, last])[0].close
            chrome.layoutSubtreeIfNeeded()
            let label = closesWindow ? L("ウィンドウを閉じる") : L("元の位置に戻してタブから解除")
            guard let cell = close.cell else { return failures + ["missing close button cell"] }
            if close.image == nil || cell.imageRect(forBounds: close.bounds).intersection(close.bounds).isEmpty
                || !cell.titleRect(forBounds: close.bounds).isEmpty {
                failures.append("the tab close button did not draw just its × for \(label)")
            }
            if close.toolTip != label || close.accessibilityLabel() != label {
                failures.append("the tab close button lost its action description for \(label)")
            }
        }
        return failures
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 760),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.workspaceButton.title = "Workspace"
        var failures = checkTabStripFeedback() + checkCloseSlotsAndWrapping()

        func settle() {
            for _ in 0 ..< 4 {
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
                if group.isHidden || tab.isHidden || tab.bounds.width < 21.5 || tab.bounds.height < 28 {
                    failures.append("\(label): tab has no usable size")
                }
            }
        }
        settle()
        let shortTitle = chrome.appendTab(title: "Tools", selected: false)
        let iconTitle = chrome.appendTab(
            title: "Tools", icon: NSImage(size: NSSize(width: 16, height: 16)), selected: false)
        let longTitle = chrome.appendTab(
            title: String(repeating: "Long application window title ", count: 4), selected: true)
        checkVisible("mixed title lengths")
        let shortWidth = shortTitle.select.bounds.width
        let longWidth = longTitle.select.bounds.width
        if abs(shortWidth - longWidth) > 1 || abs(iconTitle.select.bounds.width - longWidth) > 1
            || [shortTitle, iconTitle, longTitle].contains(where: { $0.select.alignment != .left }) {
            failures.append("titles with and without icons did not share equal-width, left-aligned slots")
        }
        for _ in 0 ..< 5 {
            chrome.appendTab(title: String(repeating: "Another long window ", count: 4), selected: false)
        }
        checkVisible("mixed title lengths when crowded")
        if longTitle.select.bounds
            .width >= longWidth || abs(shortTitle.select.bounds.width - longTitle.select.bounds.width) > 1 {
            failures.append("crowded tabs did not shrink together")
        }
        chrome.clearTabs()
        settle()
        let single = chrome.appendTab(title: "First application window", selected: true)
        checkVisible("first tab after empty layout")
        let singleWidth = single.select.bounds.width
        for index in 1 ..< 7 {
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
        for index in 7 ..< 20 {
            chrome.appendTab(title: "Application \(index)", selected: false)
        }
        checkVisible("twenty tabs")
        if single.view.frame.width > 56.5 || single.close.frame.width < 18 {
            failures.append("crowded tabs did not compact to 56 points while keeping the close button")
        }
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
            let divider = chrome.workspaceButton.superview?.subviews.compactMap { $0 as? NSBox }.first {
                $0.boxType == .separator
            }
            guard let scroll = chrome.tabs.enclosingScrollView else { fatalError("missing tab scroll view") }
            if divider?.isHidden != false || abs((divider?.frame.midX ?? 0) - scroll.frame.minX) > 4 {
                failures.append("scrolling hid the leading tabs without marking the workspace-name boundary")
            }
            chrome.revealTab(single.view)
            if divider?.isHidden != true {
                failures.append("returning to the first tab left a spurious clipping divider")
            }
        }
        chrome.clearTabs()
        settle()
        let releaseIDs = (0 ..< 4).map { _ in UUID() }
        for (id, title) in zip(releaseIDs, ["Release first", "Release target", "Release third", "Release fourth"]) {
            chrome.appendTab(id: id, title: title, selected: false)
        }
        for (tag, group) in chrome.tabs.arrangedSubviews.enumerated() {
            ((group as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton).tag = tag
        }
        var released: [TabReleaseRequest] = []
        chrome.onReleaseTabs = { released.append($0) }
        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let targetTab = (chrome.tabs.arrangedSubviews[1] as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
        let releaseMenu = targetTab.menu(for: rightClick)
        chrome.closesWindowsOnRelease = true
        let closeMenu = targetTab.menu(for: rightClick)
        // An open menu still targets the windows and the action it originally offered.
        chrome.clearTabs()
        chrome.appendTab(title: "New tab", selected: true)
        for (menu, bulkClose) in [(releaseMenu, false), (closeMenu, true)] {
            let expectations: [(String, [Int], Bool)] = [
                ("タブを解除", [1], false), ("ウィンドウを閉じる", [1], true),
                (bulkClose ? "他のタブのウィンドウをすべて閉じる" : "他のタブをすべて解除", [0, 2, 3], bulkClose),
                (bulkClose ? "右側のタブのウィンドウを閉じる" : "右側のタブを解除", [2, 3], bulkClose),
                (bulkClose ? "左側のタブのウィンドウを閉じる" : "左側のタブを解除", [0], bulkClose),
                (bulkClose ? "すべてのタブのウィンドウを閉じる" : "すべてのタブを解除", [0, 1, 2, 3], bulkClose),
            ]
            for (title, indexes, closeWindows) in expectations {
                guard let item = menu?.item(withTitle: L(title)), let action = item.action else {
                    failures.append("tab context menu did not offer \(title)")
                    continue
                }
                released.removeAll()
                _ = NSApp.sendAction(action, to: item.target, from: item)
                if released != [TabReleaseRequest(ids: indexes.map { releaseIDs[$0] }, closeWindows: closeWindows)] {
                    failures
                        .append(
                            "tab context menu performed the wrong action or targeted the wrong windows for \(title)")
                }
            }
        }
        chrome.closesWindowsOnRelease = false
        let regularStageTop = chrome.stage.frame.maxY
        chrome.setAutoHideTabBar(true)
        settle()
        if !chrome.autoHideTabBar || chrome.stage.frame.maxY < regularStageTop + 30 {
            failures.append("auto-hide mode did not expand the managed window area")
        }
        if chrome.autoHiddenToolbarPanel?.isVisible == true {
            failures.append("auto-hidden toolbar panel was visible before hover")
        }
        chrome.setAutoHiddenToolbarVisible(true)
        settle()
        if chrome.autoHiddenToolbarPanel?.isVisible != true
            || chrome.autoHiddenToolbarPanel?.frame.width != host.frame.width - 64
            || chrome.autoHiddenToolbarPanel?.frame.minX != host.frame.minX + 64
            || chrome.autoHiddenToolbarPanel?.frame.maxY != host.frame.maxY
            || chrome.autoHiddenToolbarPanel?.frame.height != 34
        {
            failures.append(
                "auto-hidden toolbar panel did not cover the workspace's top edge: \(String(describing: chrome.autoHiddenToolbarPanel?.frame)) host=\(host.frame)")
        }
        chrome.setAutoHideTabBar(false)
        settle()
        if chrome.autoHideTabBar || chrome.autoHiddenToolbarPanel?.isVisible == true
            || abs(chrome.stage.frame.maxY - regularStageTop) > 0.5
        {
            failures.append("disabling auto-hide did not restore the embedded toolbar layout")
        }
        chrome.clearTabs()
        settle()
        chrome.appendTab(title: "First application window", selected: true)
        checkVisible("first tab after clear")
        if let tab = (chrome.tabs.arrangedSubviews.first as? WorkspaceTabGroup)?.arrangedSubviews.first,
           tab.bounds.width <= wideWidth
        {
            failures.append("tab did not expand again after removing other tabs")
        }
        let target = chrome.appendTab(title: "Drag target", selected: false)
        let board = NSPasteboard(name: NSPasteboard.Name("TabLayoutSmoke-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        for frame in [
            NSRect(x: 0, y: 0, width: 1400, height: 900),
            NSRect(x: 260, y: 190, width: 900, height: 600),
        ] {
            host.setFrame(frame, display: false)
            settle()
            let source = (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! NSButton
            let group = source.superview!
            let anchor = NSPoint(x: 15, y: source.bounds.midY)
            let anchorInGroup = source.convert(anchor, to: group)
            chrome.beginTabDrag(source: source, token: "geometry", anchor: anchor)
            board.setString("geometry", forType: workspaceTabDragType)
            let destination = target.select.convert(
                NSPoint(x: target.select.bounds.midX, y: target.select.bounds.midY), to: nil)
            let info = TabLayoutDragInfo(board: board, source: source, window: host, location: destination)
            _ = target.select.draggingUpdated(info)
            let actualAnchor = group.convert(anchorInGroup, to: nil)
            if abs(actualAnchor.x - destination.x) > 1 || chrome.tabDragPreviewPanel?.isVisible == true {
                failures.append("resized window: reordered tab is not under the pointer")
            }
            let panePoint = chrome.gridAreas[0].convert(NSPoint(x: 100, y: 100), to: nil)
            let paneInfo = TabLayoutDragInfo(board: board, source: source, window: host, location: panePoint)
            _ = chrome.draggingUpdated(paneInfo)
            let paneScreenPoint = host.convertPoint(toScreen: panePoint)
            let previewAligned =
                chrome.tabDragPreviewPanel.map {
                    $0.isVisible && abs($0.frame.minX + anchorInGroup.x - paneScreenPoint.x) <= 1
                        && abs($0.frame.minY + anchorInGroup.y - paneScreenPoint.y) <= 1
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
            let panePoint = host.convertPoint(
                toScreen: pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil))
            _ = chrome.updateFloatingTab(pasteboard: board, source: source, screenPoint: panePoint)
            if pane.subviews.contains(where: { $0 is WorkspaceTabDropOverlay })
                || chrome.tabDragPreviewPanel?.isVisible != true
            {
                failures.append("a single pane did not show the detached-tab preview without a pane target")
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
                (NSPoint(x: area.bounds.maxX - 10, y: area.bounds.midY), false),
            ] {
                let point = chrome.convert(localPoint, from: area)
                let color = bitmap.colorAt(
                    x: Int(point.x * CGFloat(bitmap.pixelsWide) / chrome.bounds.width),
                    y: Int((chrome.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / chrome.bounds.height))
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
        let probeHost = WorkspaceWindow(
            contentRect: NSRect(x: 150, y: 150, width: 500, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        probeHost.isReleasedWhenClosed = false
        let probe = FrameChangeProbe(frame: .zero)
        probeHost.contentView = probe
        let probeArea = NSView(frame: NSRect(x: 10, y: 10, width: 480, height: 380))
        probe.addSubview(probeArea)
        probe.contentArea = probeArea
        probe.revealsWindow = true
        var preparedChanges = 0
        for iteration in 0 ..< 30 {
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
                    y: Int((probe.bounds.height - y) * CGFloat(bitmap.pixelsHigh) / probe.bounds.height))
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
            failures.append(
                "workspace windows use server-side titlebar dragging, which skips the pre-move transparency mask")
        }
        let titleHost = WorkspaceWindow(
            contentRect: NSRect(x: 150, y: 150, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
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
               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        {
            var queuedEvents: [NSEvent] = []
            for (offset, type) in [
                (CGFloat(120), CGEventType.leftMouseDragged),
                (CGFloat(-80), CGEventType.leftMouseDragged),
                (CGFloat(180), CGEventType.leftMouseDragged),
                (CGFloat(180), CGEventType.leftMouseUp),
            ] {
                let screenPoint = CGPoint(x: pressScreen.x + offset, y: screen.frame.maxY - pressScreen.y)
                if let cgEvent = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: screenPoint, mouseButton: .left),
                    let event = NSEvent(cgEvent: cgEvent)
                {
                    queuedEvents.append(event)
                }
            }
            if queuedEvents.count == 4 {
                // These events stay in this test application's queue; they do not move the system pointer.
                for event in queuedEvents { NSApp.postEvent(event, atStart: false) }
                titleHost.sendEvent(down)
                if titleProbe.finishedChanges != 3 || titleHost.frame != titleFrame.offsetBy(dx: 180, dy: 0) {
                    failures.append("titlebar mouse tracking bypassed application-controlled frame changes")
                }
            } else {
                failures.append("could not create titlebar tracking events")
            }
        } else {
            failures.append("could not prepare titlebar mouse tracking")
        }
        let control = TitlebarControlProbe(
            frame: NSRect(
                x: 320, y: titleHost.contentLayoutRect.maxY + 1, width: 100, height: 20))
        titleProbe.addSubview(control)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: control.frame.midX, y: control.frame.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: titleHost.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1) {
            titleHost.sendEvent(event)
            if control.mouseDownCount != 1 || titleProbe.finishedChanges != 3 {
                failures.append(
                    "titlebar control clicks=\(control.mouseDownCount), frame changes=\(titleProbe.finishedChanges)")
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
                      context: nil, eventNumber: resizeEventNumber, clickCount: 1, pressure: 1)
            else { return nil }
            let start = titleHost.convertPoint(toScreen: point)
            var queued: [NSEvent] = []
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let location = CGPoint(x: start.x + delta.width, y: screen.frame.maxY - (start.y + delta.height))
                if let cgEvent = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .left),
                    let event = NSEvent(cgEvent: cgEvent)
                {
                    queued.append(event)
                }
            }
            guard queued.count == 2 else { return nil }
            for event in queued { NSApp.postEvent(event, atStart: false) }
            titleHost.sendEvent(down)
            return titleHost.frame
        }
        let resizeChecks: [(String, (NSRect) -> NSPoint, NSSize, (NSRect) -> NSRect)] = [
            (
                "top edge", { NSPoint(x: $0.midX, y: $0.maxY - 2) }, NSSize(width: 0, height: 30),
                { NSRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + 30) }),
            (
                "top-right corner", { NSPoint(x: $0.maxX - 2, y: $0.maxY - 2) }, NSSize(width: 20, height: 20),
                { NSRect(x: $0.minX, y: $0.minY, width: $0.width + 20, height: $0.height + 20) }),
            (
                "right edge over a pane cell", { NSPoint(x: $0.maxX - 6, y: $0.midY) }, NSSize(width: 25, height: 0),
                { NSRect(x: $0.minX, y: $0.minY, width: $0.width + 25, height: $0.height) }),
            (
                "bottom-right grip", { NSPoint(x: $0.maxX - 12, y: 12) }, NSSize(width: 30, height: -20),
                { NSRect(x: $0.minX, y: $0.minY - 20, width: $0.width + 30, height: $0.height + 20) }),
        ]
        for (label, point, delta, expected) in resizeChecks {
            let before = titleHost.frame
            paneCell.frame = titleProbe.bounds.insetBy(dx: 3, dy: 3)
            let after = dragTitleHost(from: point(titleProbe.bounds), by: delta)
            if after != expected(before) || paneCell.mouseDownCount != 0 {
                failures.append(
                    "\(label) moved or was swallowed instead of resizing: \(before) -> \(String(describing: after))")
            }
        }
        let beforeCenterClick = titleHost.frame
        paneCell.frame = titleProbe.bounds.insetBy(dx: 3, dy: 3)
        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: titleProbe.bounds.midX, y: titleProbe.bounds.midY),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: titleHost.windowNumber, context: nil, eventNumber: 30, clickCount: 1, pressure: 1) {
            titleHost.sendEvent(event)
            if paneCell.mouseDownCount != 1 || titleHost.frame != beforeCenterClick {
                failures.append(
                    "a click inside a pane was taken by workspace resizing: clicks=\(paneCell.mouseDownCount) \(beforeCenterClick) -> \(titleHost.frame)")
            }
        }
        titleHost.close()
        let otherHost = WorkspaceWindow(
            contentRect: NSRect(x: 1400, y: 120, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        otherHost.isReleasedWhenClosed = false
        let otherChrome = WorkspaceChromeView(frame: .zero)
        otherHost.contentView = otherChrome
        for index in 0 ..< 3 {
            let tab = otherChrome.appendTab(title: "Destination \(index)", selected: index == 0)
            tab.select.tag = index
        }
        otherChrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        otherChrome.layoutSubtreeIfNeeded()
        let source =
            (chrome.tabs.arrangedSubviews.first as! WorkspaceTabGroup).arrangedSubviews.first as! WorkspaceTabButton
        let transferToken = "cross-workspace"
        board.setString(transferToken, forType: workspaceTabDragType)
        chrome.beginTabDrag(source: source, token: transferToken)
        otherChrome.acceptsExternalTab = { token, button in token == transferToken && button === source }
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
            if marker.frame != tabMarkerFrame || marker.frame.width != 3 || marker.frame.height != 28
                || !marker.isVisible || !marker.ignoresMouseEvents || marker.isKeyWindow
                || NSApp.keyWindow !== previousKey
                || marker.contentView?.subviews.contains(where: { $0 is NSTextField }) == true
            {
                failures.append("tab transfers did not retain their thin, nonactivating insertion line")
            }
            let expectedX = otherHost.convertPoint(toScreen: destinationGroup.convert(.zero, to: nil)).x
            if abs(marker.frame.minX - expectedX) > 1
                || otherChrome.tabInsertionIndex(at: otherHost.convertPoint(toScreen: tabPoint)) != 1
            {
                failures.append("the insertion line did not match its actual tab insertion position")
            }
        } else {
            failures.append("the tab insertion line was not created")
        }
        otherChrome.showWindowDropTarget(
            at: otherHost.convertPoint(toScreen: tabPoint), requiresPermission: false,
            application: .current, title: "Dragged window")
        if let preview = otherChrome.windowDropPreview {
            if otherChrome.tabs.arrangedSubviews.firstIndex(of: preview) != 1
                || preview.alphaValue >= 1 || otherChrome.windowDropPanel?.isVisible != true
                || otherChrome.windowDropPanel?.ignoresMouseEvents != true
                || (otherChrome.windowDropPanel?.frame.width ?? 0) <= preview.frame.width
                || (otherChrome.windowDropPanel?.level ?? .normal) <= .normal
                || (preview as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? NSButton })
                .first?.title != "Dragged window"
                || NSApp.keyWindow !== previousKey
            {
                failures.append("ordinary window addition did not show the tab bar and insertion preview in front")
            }
            otherChrome.layoutSubtreeIfNeeded()
            let previewPoint = otherHost.convertPoint(
                toScreen: preview.convert(NSPoint(x: preview.bounds.midX, y: preview.bounds.midY), to: nil))
            if otherChrome.tabInsertionIndex(at: previewPoint) != 1 {
                failures.append("the preview did not preserve the insertion index under the pointer")
            }
            let last = otherChrome.tabs.arrangedSubviews.last!
            let endPoint = otherHost.convertPoint(
                toScreen: last.convert(NSPoint(x: last.bounds.maxX - 1, y: last.bounds.midY), to: nil))
            otherChrome.showWindowDropTarget(at: endPoint, requiresPermission: false)
            if otherChrome.tabs.arrangedSubviews.last !== preview
                || otherChrome.tabInsertionIndex(at: endPoint) != 3
            {
                failures.append("the translucent preview did not follow the insertion position")
            }
        } else {
            failures.append("the ordinary window-addition preview was not created")
        }
        _ = destinationButton.draggingUpdated(tabInfo)
        if otherChrome.windowDropPanel?.frame != tabMarkerFrame
            || otherChrome.windowDropPanel?.contentView?.subviews.contains(where: { !$0.isHidden && $0 is NSTextField })
            == true || otherChrome.windowDropPreview != nil
        {
            failures.append("switching from window addition to tab transfer retained a wide bar or visible label")
        }
        if entered != .move || chrome.tabDragPreviewPanel?.isVisible != true
            || !destinationButton.performDragOperation(tabInfo) || received?.1 != 1 || received?.2 != nil
        {
            failures.append("another workspace rejected the tab, lost its preview, or chose the wrong insertion index")
        }
        received = nil
        let cell = otherChrome.gridAreas[0]
        let cellPoint = cell.convert(NSPoint(x: 100, y: 100), to: nil)
        let cellInfo = TabLayoutDragInfo(board: board, source: source, window: otherHost, location: cellPoint)
        func highlightedPanes() -> [Int] {
            otherChrome.gridAreas.indices.filter { index in
                otherChrome.gridAreas[index].subviews.contains { $0 is WorkspaceTabDropOverlay && !$0.isHidden }
            }
        }
        _ = otherChrome.draggingUpdated(cellInfo)
        if highlightedPanes() != [0] {
            failures.append("a cross-workspace pane hover did not highlight just the receiving pane")
        }
        _ = destinationButton.draggingUpdated(tabInfo)
        if !highlightedPanes().isEmpty || otherChrome.windowDropPanel?.isVisible != true {
            failures.append(
                "returning to the destination tab strip did not replace the pane highlight with the insertion line")
        }
        if !otherChrome.performDragOperation(cellInfo) || received?.2 != 0 || received?.1 != nil {
            failures.append("cross-workspace pane drop did not select the destination pane")
        }
        otherChrome.hideExternalTabTargets()
        otherChrome.setGrid(.single, activeCell: 0)
        otherChrome.layoutSubtreeIfNeeded()
        received = nil
        let singlePane = otherChrome.gridAreas[0]
        let singlePanePoint = singlePane.convert(NSPoint(x: singlePane.bounds.midX, y: singlePane.bounds.midY), to: nil)
        let singlePaneInfo = TabLayoutDragInfo(
            board: board, source: source, window: otherHost, location: singlePanePoint)
        let expectedIndex = otherChrome.tabInsertionIndex(at: otherHost.convertPoint(toScreen: singlePanePoint))
        if singlePane.subviews.contains(where: { $0 is WorkspaceTabDropOverlay })
            || otherChrome.draggingUpdated(singlePaneInfo) != .move || otherChrome.windowDropPanel?.isVisible != true
            || otherChrome.windowDropPanel?.frame.width != 3 || !otherChrome.performDragOperation(singlePaneInfo)
            || received?.1 != expectedIndex || received?.2 != nil
        {
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
            location: NSPoint(x: 150, y: otherChrome.bounds.maxY - 16))
        if otherChrome.draggingEntered(emptyInfo) != .move || !otherChrome.performDragOperation(emptyInfo)
            || received?.1 != 0 || received?.2 != nil
        {
            failures.append("an empty workspace could not receive its first tab")
        }
        otherChrome.hideExternalTabTargets()
        if cell.subviews.contains(where: { $0 is WorkspaceTabDropOverlay })
            || otherChrome.windowDropPanel?.isVisible == true
        {
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
            if !cancelled, host.frame.contains(point), chrome.tabRowContains(point) || chrome.gridAreas.count > 1 {
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
                (destination, CGEventType.leftMouseDragged),
            ] {
                if let cg = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: point.x, y: screen.frame.maxY - point.y), mouseButton: .left),
                    let event = NSEvent(
                        cgEvent: cg) {
                    events.append(event)
                }
            }
            let completion: NSEvent?
            if escape {
                completion = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)
            } else {
                completion = CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: CGPoint(x: destination.x, y: screen.frame.maxY - destination.y),
                    mouseButton: .left).flatMap { NSEvent(cgEvent: $0) }
            }
            guard events.count == 2, let completion,
                  let down = NSEvent.mouseEvent(
                      with: .leftMouseDown, location: press, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                      context: nil, eventNumber: 3, clickCount: 1, pressure: 1)
            else {
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
        if mouseCompletions.count != 1 || mouseCompletions.first?.0 != outside || mouseCompletions.first?.1 != false
            || chrome.tabs.arrangedSubviews.map({ ObjectIdentifier($0) }) != originalViews
            || chrome.tabDragPreviewPanel?.isVisible == true
        {
            failures.append("releasing a tab outside was lost or classified as cancellation")
        }
        replayTabDrag(to: outside, escape: true)
        if mouseCompletions.count != 2 || mouseCompletions.last?.1 != true
            || chrome.tabDragPreviewPanel?.isVisible == true
        {
            failures.append("Escape did not cancel tab tracking and remove its preview")
        }
        for (index, group) in chrome.tabs.arrangedSubviews.enumerated() {
            (group as! WorkspaceTabGroup).arrangedSubviews.compactMap { $0 as? WorkspaceTabButton }.first?.tag = index
        }
        var committedOrder: [Int]?
        chrome.onReorderTabs = { committedOrder = $0 }
        let neighbor = chrome.tabs.arrangedSubviews[1]
        let neighborPoint = host.convertPoint(
            toScreen: neighbor.convert(
                NSPoint(x: neighbor.bounds.maxX - 5, y: neighbor.bounds.midY), to: nil))
        replayTabDrag(to: neighborPoint, escape: false)
        if committedOrder != [1, 0] {
            failures.append("application-controlled mouse tracking no longer committed local tab reordering")
        }
        var movedCell: Int?
        chrome.onMoveTab = { _, cell in movedCell = cell }
        chrome.setGrid(WorkspaceGridSize(columns: 2, rows: 1), activeCell: 0)
        settle()
        let ownPane = chrome.gridAreas[0]
        replayTabDrag(
            to: host.convertPoint(
                toScreen: ownPane.convert(
                    NSPoint(x: ownPane.bounds.midX, y: ownPane.bounds.midY), to: nil)), escape: false)
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
        if movedCell != nil || committedOrder != nil {
            failures.append(
                "releasing a tab over the only pane unexpectedly reordered or moved it: moved=\(String(describing: movedCell)) order=\(String(describing: committedOrder))")
        }
        // Another app activated during the drag may receive its mouse-up; tracking must end once the button is up.
        let completionsBeforeLostRelease = mouseCompletions.count
        var trackingHung = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard mouseCompletions.count == completionsBeforeLostRelease, let screen = NSScreen.screens.first else {
                return
            }
            trackingHung = true
            let point = CGPoint(x: outside.x, y: screen.frame.maxY - outside.y)
            if let up = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
                .flatMap({ NSEvent(cgEvent: $0) }) {
                NSApp.postEvent(up, atStart: false)
            }
        }
        replayTabDrag(to: outside, escape: false, completes: false)
        if trackingHung || mouseCompletions.count != completionsBeforeLostRelease + 1
            || mouseCompletions.last?.1 != false || chrome.tabDragPreviewPanel?.isVisible == true
        {
            failures.append("a tab drag whose mouse-up went to another app kept tracking after the button was released")
        }
        host.close()
        let autoHideController = WorkspaceController(name: "Auto-hide smoke")
        autoHideController.window.orderFrontRegardless()
        autoHideController.setAutoHideTabs(true)
        let revealPoint = NSPoint(
            x: autoHideController.autoHideHoverFrame.midX,
            y: autoHideController.autoHideHoverFrame.midY)
        let outsidePoint = NSPoint(
            x: autoHideController.window.frame.maxX + 80,
            y: autoHideController.window.frame.maxY - 2)
        let hoverStart = ProcessInfo.processInfo.systemUptime
        autoHideController.updateAutoHiddenTabBar(at: revealPoint, now: hoverStart)
        if autoHideController.isAutoHiddenToolbarVisible {
            failures.append("auto-hidden toolbar appeared without the hover delay")
        }
        autoHideController.updateAutoHiddenTabBar(at: revealPoint, now: hoverStart + 0.3)
        if !autoHideController.isAutoHiddenToolbarVisible {
            failures.append("hovering at the top edge did not reveal the auto-hidden toolbar")
        }
        autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: hoverStart + 0.4)
        autoHideController.updateAutoHiddenTabBar(at: outsidePoint, now: hoverStart + 1.3)
        if autoHideController.isAutoHiddenToolbarVisible {
            failures.append("auto-hidden toolbar remained visible after leaving it")
        }
        autoHideController.window.orderOut(nil)
        failures += positionChecks()
        if failures.isEmpty {
            print("PASS: tab layout, cross-workspace drops, actual tab mouse release/Escape, and movement masks")
            exit(0)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(1)
    }

    @MainActor
    private static func positionChecks() -> [String] {
        var failures: [String] = []
        let host = WorkspaceWindow(
            contentRect: NSRect(x: 100, y: 100, width: 720, height: 480),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let chrome = WorkspaceChromeView(frame: .zero)
        host.contentView = chrome
        chrome.workspaceButton.title = "Workspace"
        for index in 0 ..< 20 {
            let tab = chrome.appendTab(title: "Window \(index)", selected: index == 0)
            tab.select.tag = index
        }
        host.orderFrontRegardless()
        defer { host.close() }
        func settle() {
            for _ in 0 ..< 4 {
                chrome.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        for position in TabBarPosition.allCases {
            chrome.setTabBarPosition(position)
            settle()
            let stage = chrome.stage.frame
            switch position {
            case .top:
                if stage.maxY > chrome.bounds.maxY - 33 { failures.append("top tab bar did not reserve space") }
            case .bottom:
                if stage.minY < chrome.bounds.minY + 36 { failures.append("bottom tab bar did not reserve space") }
            case .left:
                if stage.minX < chrome.bounds.minX + 190 { failures.append("left tab bar did not reserve space") }
            case .right:
                if stage.maxX > chrome.bounds.maxX - 190 { failures.append("right tab bar did not reserve space") }
            }
            if position.isVertical {
                if chrome.tabs.orientation != .vertical || chrome.tabs.visibleRect.width < 175
                    || chrome.tabs.visibleRect.height < 50 || chrome.tabs.bounds.height <= chrome.tabs.visibleRect
                    .height
                {
                    failures.append("\(position): vertical tabs did not have a scrollable viewport")
                }
            } else if chrome.tabs.orientation != .horizontal || chrome.tabs.visibleRect.height < 28 {
                failures.append("\(position): horizontal tabs did not have a usable viewport")
            }
            for control in [chrome.addButton, chrome.columnSelector, chrome.rowSelector, chrome.permissionButton] {
                let frame = chrome.convert(control.bounds, from: control)
                if frame.isEmpty || !chrome.bounds.contains(frame) {
                    failures.append("\(position): toolbar control was clipped")
                }
            }
            guard let last = chrome.tabs.arrangedSubviews.last else {
                failures.append("\(position): tabs disappeared")
                continue
            }
            chrome.revealTab(last)
            settle()
            if !chrome.tabs.visibleRect.contains(last.frame) {
                failures.append("\(position): last tab could not be revealed")
            }
            let point = position.isVertical
                ? NSPoint(x: last.bounds.midX, y: last.bounds.maxY - 1)
                : NSPoint(x: last.bounds.minX + 1, y: last.bounds.midY)
            let screenPoint = host.convertPoint(toScreen: last.convert(point, to: nil))
            if chrome.tabInsertionIndex(at: screenPoint) != 19 {
                failures.append("\(position): insertion index did not follow tab order")
            }
            chrome.showWindowDropTarget(at: screenPoint, requiresPermission: false)
            if chrome.windowDropPreview == nil || chrome.windowDropPanel?.isVisible != true
                || chrome.tabInsertionIndex(at: screenPoint) != 19
            {
                failures.append("\(position): window drop preview was missing or misplaced")
            }
            chrome.hideWindowDropTarget()
            if position.isVertical {
                let sourceGroup = chrome.tabs.arrangedSubviews[18] as! WorkspaceTabGroup
                let source = sourceGroup.arrangedSubviews.first as! WorkspaceTabButton
                let originalOrder = chrome.tabs.arrangedSubviews.compactMap {
                    ($0 as? WorkspaceTabGroup)?.arrangedSubviews.first as? WorkspaceTabButton
                }.map(\.tag)
                var committed: [Int]?
                chrome.onReorderTabs = { committed = $0 }
                let board = NSPasteboard.withUniqueName()
                board.setString("vertical-reorder", forType: workspaceTabDragType)
                chrome.beginTabDrag(source: source, token: "vertical-reorder")
                let destination = host.convertPoint(
                    toScreen: last.convert(NSPoint(x: last.bounds.midX, y: last.bounds.minY + 1), to: nil))
                _ = chrome.updateFloatingTab(pasteboard: board, source: source, screenPoint: destination)
                let dropped = chrome.performTabReorder(
                    pasteboard: board, source: source, screenPoint: destination)
                var expected = originalOrder
                expected.append(expected.remove(at: 18))
                if !dropped || committed != expected {
                    failures.append("\(position): vertical tab reorder did not follow the pointer")
                }
                board.releaseGlobally()

                let incoming = NSButton(title: "Incoming", target: nil, action: nil)
                let incomingBoard = NSPasteboard.withUniqueName()
                incomingBoard.setString("incoming", forType: workspaceTabDragType)
                chrome.acceptsExternalTab = { token, button in token == "incoming" && button === incoming }
                var receivedIndex: Int?
                chrome.onExternalTabDrop = { _, _, index, _ in
                    receivedIndex = index
                    return true
                }
                let target = chrome.tabs.arrangedSubviews[18]
                chrome.revealTab(target)
                settle()
                let incomingPoint = host.convertPoint(
                    toScreen: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.maxY - 1), to: nil))
                let expectedIndex = chrome.tabInsertionIndex(at: incomingPoint)
                _ = chrome.updateFloatingTab(pasteboard: incomingBoard, source: incoming, screenPoint: incomingPoint)
                if chrome.windowDropPanel?.frame.height != 3 || (chrome.windowDropPanel?.frame.width ?? 0) < 40
                    || !chrome.completeTabDrop(
                        pasteboard: incomingBoard, source: incoming, screenPoint: incomingPoint)
                    || receivedIndex != expectedIndex
                {
                    failures.append("\(position): incoming tab marker or insertion index was incorrect")
                }
                incomingBoard.releaseGlobally()
                chrome.acceptsExternalTab = nil
                chrome.onExternalTabDrop = nil
            }
            chrome.setAutoHideTabBar(true)
            chrome.setAutoHiddenToolbarVisible(true)
            settle()
            let expanded = chrome.stage.frame
            if position.isVertical ? expanded.width < stage.width + 180 : expanded.height < stage.height + 30 {
                failures.append("\(position): auto-hide did not reclaim the tab bar area")
            }
            if chrome.autoHiddenToolbarPanel?.isVisible != true
                || !host.frame.contains(chrome.toolbarHoverFrame)
            {
                failures.append("\(position): auto-hidden toolbar or edge hover area was missing")
            }
            if let panel = chrome.autoHiddenToolbarPanel {
                chrome.showWindowDropTarget(
                    at: NSPoint(x: panel.frame.midX, y: panel.frame.midY), requiresPermission: false)
                if chrome.windowDropPreview == nil || chrome.windowDropPanel?.frame != panel.frame {
                    failures.append("\(position): auto-hidden window drop preview was not shown on its bar")
                }
                chrome.hideWindowDropTarget()
            }
            chrome.setAutoHideTabBar(false)
            settle()
        }
        do {
            let old = try JSONDecoder().decode(SavedWorkspace.self, from: Data(#"{"name":"old","windows":[]}"#.utf8))
            if old.tabBarPosition != nil { failures.append("old layouts did not preserve the default tab position") }
            let saved = SavedWorkspace(name: "Saved", windows: [], tabBarPosition: .right)
            let restored = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))
            let controller = WorkspaceController(name: "Position")
            controller.restoreLayout(restored)
            if controller.tabBarPosition != .right {
                failures.append("tab bar position did not survive restoring a saved workspace")
            }
            let menu = controller.tabBarPositionMenu()
            menu.update()
            if menu.items.count != 4 || menu.items[3].state != .on {
                failures.append("tab bar position menu did not reflect the restored position")
            } else if let action = menu.items[1].action {
                _ = NSApp.sendAction(action, to: menu.items[1].target, from: menu.items[1])
                if controller.tabBarPosition != .bottom {
                    failures.append("tab bar position menu did not change the workspace")
                }
            } else {
                failures.append("tab bar position menu did not offer an action")
            }
            controller.quitting = true
            controller.window.orderOut(nil)
        } catch {
            failures.append("tab bar position persistence failed: \(error)")
        }
        return failures
    }
}
