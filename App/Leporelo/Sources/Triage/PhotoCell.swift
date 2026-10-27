import AppKit
import LeporeloCore

/// One cell of the triage grid (160 pt square): the thumbnail as an aspect-fill square crop,
/// dimmed when not selected (videos always), a checkmark when selected, badges top right, the
/// series chip bottom right (click: expand or collapse) and a focus ring for the keyboard.
///
/// Thin on purpose: everything it shows comes from a `TriageItem`.
final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCell")
    static let side: CGFloat = 160

    /// Called with the series id when the chip is clicked.
    var onSeriesChip: ((String) -> Void)?

    private let imageLayer = CALayer()
    private let checkmark = NSImageView()
    private let badges = NSStackView()
    private let chip = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var loadTask: Task<Void, Never>?
    private(set) var item: TriageItem?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        root.wantsLayer = true
        root.layer?.cornerRadius = 6
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.frame = root.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(imageLayer)

        checkmark.image = Self.symbol("checkmark.circle.fill", size: 20)
        checkmark.contentTintColor = .controlAccentColor
        checkmark.wantsLayer = true
        checkmark.layer?.shadowOpacity = 0.4
        checkmark.layer?.shadowRadius = 2

        badges.orientation = .horizontal
        badges.spacing = 3
        badges.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        badges.wantsLayer = true
        badges.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badges.layer?.cornerRadius = 8

        chip.bezelStyle = .inline
        chip.controlSize = .small
        chip.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        chip.target = self
        chip.action = #selector(chipClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        for view in [checkmark, badges, chip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkmark.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            checkmark.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            badges.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            badges.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            chip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            chip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])

        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.image)
        view = root
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageLayer.contents = nil
        item = nil
    }

    override var isSelected: Bool {
        didSet { updateFocusRing() }
    }

    /// Shows `item`; loads the thumbnail asynchronously unless it is already shown or cached.
    func configure(_ item: TriageItem, loader: ThumbnailLoader, package: ProjectPackage) {
        let samePhoto = self.item?.id == item.id
        self.item = item
        let photo = item.photo

        let selected = photo.isSelected && item.isSelectable
        imageLayer.opacity = selected ? 1 : 0.38
        checkmark.isHidden = !selected

        spinner.stopAnimation(nil)
        badges.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for badge in item.badges { badges.addArrangedSubview(badgeView(badge, state: photo.originalState)) }
        badges.isHidden = item.badges.isEmpty

        if let text = item.seriesChip {
            chip.title = text
            chip.isHidden = false
            chip.setAccessibilityLabel(item.isExpanded ? "Sbalit sérii" : "Rozbalit sérii, \(text)")
        } else {
            chip.isHidden = true
        }

        view.setAccessibilityLabel(item.accessibilityLabel)
        updateFocusRing()

        if samePhoto, imageLayer.contents != nil { return }
        if let image = loader.cached(item.id) {
            imageLayer.contents = image
            return
        }
        if !samePhoto { imageLayer.contents = nil }
        loadTask?.cancel()
        let id = item.id
        loadTask = Task { [weak self] in
            let image = await loader.load(id, from: package)
            guard !Task.isCancelled, let self, self.item?.id == id, let image else { return }
            self.imageLayer.contents = image
        }
    }

    @objc private func chipClicked() {
        if let id = item?.seriesID { onSeriesChip?(id) }
    }

    private func updateFocusRing() {
        view.layer?.borderWidth = isSelected ? 3 : 0
        view.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }

    private func badgeView(_ badge: Badge, state: OriginalState) -> NSView {
        if badge == .cloud, state == .downloading {
            spinner.startAnimation(nil)
            return spinner
        }
        let view = NSImageView()
        view.image = Self.symbol(Self.symbolName(badge, state: state), size: 12)
        view.contentTintColor = .white
        view.toolTip = Self.tooltip(badge, state: state)
        return view
    }

    static func symbolName(_ badge: Badge, state: OriginalState) -> String {
        switch badge {
        case .blurred: "camera.metering.unknown"
        case .closedEyes: "eye.slash"
        case .duplicate: "square.on.square"
        case .video: "video.fill"
        case .screenshot: "doc.text.viewfinder"
        case .cloud: state == .unavailable ? "exclamationmark.icloud" : "icloud.and.arrow.down"
        }
    }

    static func tooltip(_ badge: Badge, state: OriginalState) -> String {
        switch badge {
        case .blurred: "Rozmazaná"
        case .closedEyes: "Zavřené oči"
        case .duplicate: "Podobná fotka v sérii"
        case .video: "Video, do alba nejde"
        case .screenshot: "Snímek obrazovky nebo účtenka"
        case .cloud: TriageText.originalDescription(state).capitalizedFirst
        }
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
        return image?.withSymbolConfiguration(config)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
