import AppKit

final class WatchlistSettingsController: NSWindowController, NSWindowDelegate {
    var onApply: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let editor = WatchlistTextView()
    private let applyButton = NSButton(title: "保存并应用", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var isValidating = false
    private var closingAfterApply = false

    init() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "选择 OKX 标的"
        settingsWindow.contentMinSize = NSSize(width: 500, height: 440)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.setFrameAutosaveName("OKXWatchlistSettingsWindow")
        super.init(window: settingsWindow)
        settingsWindow.delegate = self
        configureContent()
        settingsWindow.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(instrumentIDs: [String]) {
        guard let window else { return }
        if !window.isVisible && !window.isMiniaturized {
            closingAfterApply = false
            editor.string = instrumentIDs.joined(separator: "\n")
            editor.undoManager?.removeAllActions()
            setValidationState(
                isValidating: false,
                message: "保存时会检查 OKX 是否支持这些标的。"
            )
        }
        showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !isValidating {
            window.makeFirstResponder(editor)
        }
    }

    func setValidationState(isValidating: Bool, message: String, isError: Bool = false) {
        self.isValidating = isValidating
        editor.isEditable = !isValidating
        editor.isSelectable = !isValidating
        editor.textColor = isValidating ? .secondaryLabelColor : .textColor
        applyButton.isEnabled = !isValidating
        statusLabel.stringValue = message
        statusLabel.toolTip = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        spinner.isHidden = !isValidating
        if isValidating {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            if window?.isKeyWindow == true {
                window?.makeFirstResponder(editor)
            }
        }
    }

    func closeAfterApplying() {
        closingAfterApply = true
        spinner.stopAnimation(nil)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        spinner.stopAnimation(nil)
        if !closingAfterApply {
            onCancel?()
        }
    }

    private func configureContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "显示你关注的行情")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        let instructions = NSTextField(wrappingLabelWithString:
            "每行一个标的，也可以用逗号分隔。最多 20 个；删除或调整行顺序，即可修改浮窗里的列表。"
        )
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.setAccessibilityLabel("OKX 标的列表")
        editor.setAccessibilityIdentifier("watchlist-editor")
        editor.identifier = NSUserInterfaceItemIdentifier("watchlist-editor")
        scrollView.documentView = editor

        let examples = NSTextField(wrappingLabelWithString:
            "MU、BTC、ETH 默认显示 USDT 永续合约。\nBTC-USDT 显示现货；也支持 MU-USDT-SWAP 等完整 OKX 标的编号。"
        )
        examples.font = .systemFont(ofSize: 11)
        examples.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 7
        statusRow.detachesHiddenViews = true

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applySelection)
        applyButton.setAccessibilityIdentifier("watchlist-apply")
        applyButton.identifier = NSUserInterfaceItemIdentifier("watchlist-apply")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection)
        cancelButton.setAccessibilityIdentifier("watchlist-cancel")
        cancelButton.identifier = NSUserInterfaceItemIdentifier("watchlist-cancel")
        let buttonRow = NSStackView(views: [cancelButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        for view in [heading, instructions, scrollView, examples, statusRow, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.heightAnchor.constraint(equalToConstant: 22),

            instructions.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            instructions.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            instructions.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            instructions.heightAnchor.constraint(equalToConstant: 32),

            scrollView.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 10),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            examples.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            examples.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            examples.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            examples.heightAnchor.constraint(equalToConstant: 30),

            statusRow.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            statusRow.topAnchor.constraint(equalTo: examples.bottomAnchor, constant: 6),
            statusRow.heightAnchor.constraint(equalToConstant: 44),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            buttonRow.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            buttonRow.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 8),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            buttonRow.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            applyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104)
        ])
    }

    @objc private func applySelection() {
        guard !isValidating else { return }
        onApply?(editor.string)
    }

    @objc private func cancelSelection() {
        close()
    }
}

private final class WatchlistTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // The floating app has no permanent Edit menu, so expose the familiar editor shortcuts here.
        switch key {
        case "a":
            if isSelectable { selectAll(nil) }
        case "c":
            if isSelectable { copy(nil) }
        case "v":
            if isEditable { pasteAsPlainText(nil) }
        case "x":
            if isEditable { cut(nil) }
        case "z":
            if isEditable {
                if modifiers.contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
            }
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
