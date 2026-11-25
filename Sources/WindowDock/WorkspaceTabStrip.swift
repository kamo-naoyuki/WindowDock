import AppKit

/// Keep tab groups (including drag placeholders) in one coordinate system even when there are two rows.
final class WorkspaceTabStrip: NSView {
    private(set) var arrangedSubviews: [NSView] = []
    let spacing: CGFloat = 2
    var orientation: NSUserInterfaceLayoutOrientation = .horizontal {
        didSet { if orientation != oldValue { invalidateArrangement() } }
    }
    var secondRow: Int? {
        didSet { if secondRow != oldValue { invalidateArrangement() } }
    }
    private var arrangement: [NSLayoutConstraint] = []
    private var arrangementDirty = true

    func row(at y: CGFloat) -> ArraySlice<NSView> {
        let views = arrangedSubviews
        guard let split = secondRow, split > 0, split < views.count else { return views[...] }
        let middle = (views[split - 1].frame.midY + views[split].frame.midY) / 2
        return y < middle ? views[split...] : views[..<split]
    }

    func addArrangedSubview(_ view: NSView) { insertArrangedSubview(view, at: arrangedSubviews.count) }

    func insertArrangedSubview(_ view: NSView, at index: Int) {
        arrangedSubviews.insert(view, at: index)
        if view.superview !== self { addSubview(view) }
        view.translatesAutoresizingMaskIntoConstraints = false
        invalidateArrangement()
    }

    func removeArrangedSubview(_ view: NSView) {
        arrangedSubviews.removeAll { $0 === view }
        invalidateArrangement()
    }

    private func invalidateArrangement() {
        arrangementDirty = true
        needsUpdateConstraints = true
    }

    override func updateConstraints() {
        if arrangementDirty {
            arrangementDirty = false
            NSLayoutConstraint.deactivate(arrangement)
            arrangement = []
            let views = arrangedSubviews
            if orientation == .vertical {
                for (i, view) in views.enumerated() {
                    arrangement += [
                        view.centerXAnchor.constraint(equalTo: centerXAnchor),
                        view.topAnchor.constraint(equalTo: i == 0 ? topAnchor : views[i - 1].bottomAnchor,
                                                  constant: i == 0 ? 0 : spacing),
                    ]
                }
                arrangement.append(views.last?.bottomAnchor.constraint(equalTo: bottomAnchor)
                    ?? heightAnchor.constraint(equalToConstant: 0))
            } else {
                let split = min(secondRow ?? views.count, views.count)
                for (i, view) in views.enumerated() {
                    let first = i == 0 || i == split
                    arrangement += [
                        view.leadingAnchor.constraint(equalTo: first ? leadingAnchor : views[i - 1].trailingAnchor,
                                                      constant: first ? 0 : spacing),
                        view.topAnchor.constraint(equalTo: i < split ? topAnchor : views[0].bottomAnchor,
                                                  constant: i < split ? 0 : spacing),
                    ]
                    if i + 1 == split || i + 1 == views.count {
                        arrangement.append(trailingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor))
                    }
                }
                let hugRows = widthAnchor.constraint(equalToConstant: 0)
                hugRows.priority = .fittingSizeCompression
                arrangement.append(hugRows)
            }
            NSLayoutConstraint.activate(arrangement)
        }
        super.updateConstraints()
    }
}
