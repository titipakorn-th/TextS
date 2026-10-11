import AppKit
import Carbon.HIToolbox
import Foundation
import ServiceManagement

private enum CaptureOutcome {
    case success
    case failure(String)
}

private struct GlobalShortcut: Codable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let standard = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "2"
    )

    var displayName: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    var isValid: Bool {
        keyCode < 128 && modifiers != 0 && !keyLabel.isEmpty
    }

    static func loadSaved() -> GlobalShortcut {
        guard let data = UserDefaults.standard.data(forKey: "captureShortcut"),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
              shortcut.isValid else { return .standard }
        return shortcut
    }
}

private final class ShortcutRecorderField: NSTextField {
    var didRecord: ((GlobalShortcut) -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }

        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyLabel = characters.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? "Key \(event.keyCode)"
        let shortcut = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: keyLabel)
        stringValue = shortcut.displayName
        didRecord?(shortcut)
    }
}

private let hotKeyCallback: EventHandlerProcPtr = { _, _, userData in
    guard let userData else { return noErr }
    let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { app.capture() }
    return noErr
}

private func captureAndRecognize() -> CaptureOutcome {
    let pasteboard = NSPasteboard.general
    let initialChangeCount = DispatchQueue.main.sync { pasteboard.changeCount }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-i", "-c", "-x"]
    do {
        try capture.run()
        capture.waitUntilExit()
    } catch {
        return .failure("Could not start screen capture: \(error.localizedDescription)")
    }
    guard capture.terminationStatus == 0 else { return .failure("Capture canceled") }

    let imageData = DispatchQueue.main.sync {
        guard pasteboard.changeCount != initialChangeCount else { return nil as Data? }
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }
    guard let imageData else { return .failure("No cropped image was captured") }

    let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("textsniper-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: imageURL) }
    do {
        try imageData.write(to: imageURL)
    } catch {
        return .failure("Could not save the cropped image: \(error.localizedDescription)")
    }

    let recognizer = Process()
    recognizer.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/textsniper-rs")
    recognizer.arguments = [imageURL.path]
    let output = Pipe()
    recognizer.standardOutput = output
    recognizer.standardError = output
    do {
        try recognizer.run()
        let message = output.fileHandleForReading.readDataToEndOfFile()
        recognizer.waitUntilExit()
        guard recognizer.terminationStatus == 0 else {
            return .failure(String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .success
    } catch {
        return .failure("Could not start OCR: \(error.localizedDescription)")
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var loginControl: NSButton!
    private var loginDescription: NSTextField!
    private var shortcutControl: NSButton!
    private var settingsWindow: NSWindow?
    private var isCapturing = false
    private var shortcut = GlobalShortcut.loadSaved()
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var feedbackPanel: NSPanel?
    private var feedbackTitle: NSTextField?
    private var feedbackDetail: NSTextField?
    private var feedbackIcon: NSImageView?
    private var feedbackDismissal: DispatchWorkItem?
    private var feedbackGeneration = 0
    private let successSound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let menu = NSMenu()
        captureItem = NSMenuItem(title: "Capture Text", action: #selector(capture), keyEquivalent: "")
        captureItem.title = "Capture Text (\(shortcut.displayName))"
        captureItem.target = self
        menu.addItem(captureItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TextS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "TextS")
        statusItem.button?.toolTip = "Capture text · \(shortcut.displayName)"
        statusItem.menu = menu
        menu.delegate = self
        registerHotKey()
        createSettingsWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @objc func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = captureAndRecognize()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturing = false
                switch outcome {
                case .success:
                    self.showFeedback(title: "Copied to clipboard", detail: "Your text is ready to paste.", success: true)
                case .failure(let message):
                    if message != "Capture canceled" {
                        self.showFeedback(title: "Couldn’t copy text", detail: message, success: false)
                    }
                }
            }
        }
    }

    @objc private func setCaptureShortcut() {
        let recorder = ShortcutRecorderField(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        recorder.stringValue = "Press a shortcut"
        recorder.alignment = .center
        recorder.isEditable = true
        recorder.isBordered = true
        recorder.focusRingType = .exterior
        var recordedShortcut: GlobalShortcut?
        recorder.didRecord = { recordedShortcut = $0 }

        let alert = NSAlert()
        alert.messageText = "Set Capture Shortcut"
        alert.informativeText = "Press a modifier key with a letter or number."
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.initialFirstResponder = recorder
        guard alert.runModal() == .alertFirstButtonReturn, let recordedShortcut else { return }
        guard recordedShortcut.isValid else {
            showFeedback(title: "Shortcut not changed", detail: "Choose a key with a modifier.", success: false)
            return
        }
        replaceShortcut(with: recordedShortcut)
    }

    @objc private func openSettings() {
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateLoginAtStartupState()
    }

    private func createSettingsWindow() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "TextS")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "TextS")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Capture text from anywhere on your screen.")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let sectionTitle = NSTextField(labelWithString: "Capture")
        sectionTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let shortcutTitle = NSTextField(labelWithString: "Keyboard shortcut")
        let shortcutCaption = NSTextField(labelWithString: "Start a screen selection from any app.")
        shortcutCaption.font = .systemFont(ofSize: 11)
        shortcutCaption.textColor = .secondaryLabelColor
        let shortcutLabels = NSStackView(views: [shortcutTitle, shortcutCaption])
        shortcutLabels.orientation = .vertical
        shortcutLabels.alignment = .leading
        shortcutLabels.spacing = 4

        shortcutControl = NSButton(title: shortcut.displayName, target: self, action: #selector(setCaptureShortcut))
        shortcutControl.bezelStyle = .rounded
        shortcutControl.setButtonType(.momentaryPushIn)
        shortcutControl.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        let shortcutRow = NSStackView(views: [shortcutLabels, shortcutControl])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.distribution = .equalSpacing

        loginControl = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLaunchAtLogin))
        loginDescription = NSTextField(wrappingLabelWithString: "Open TextS automatically when you sign in.")
        loginDescription.font = .systemFont(ofSize: 11)
        loginDescription.textColor = .secondaryLabelColor
        loginDescription.maximumNumberOfLines = 2
        let loginRow = NSStackView(views: [loginControl, loginDescription])
        loginRow.orientation = .vertical
        loginRow.alignment = .leading
        loginRow.spacing = 4

        let note = NSTextField(wrappingLabelWithString: "Recognized text is copied to your clipboard.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let divider = separator()
        let stack = NSStackView(views: [header, divider, sectionTitle, shortcutRow, loginRow, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 19
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        settingsWindow = window
        updateLoginAtStartupState()
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func showFeedback(title: String, detail: String, success: Bool) {
        if feedbackPanel == nil { createFeedbackPanel() }
        guard let panel = feedbackPanel,
              let icon = feedbackIcon,
              let titleLabel = feedbackTitle,
              let detailLabel = feedbackDetail else { return }

        if success {
            successSound?.stop()
            successSound?.play()
        }
        icon.image = NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill", accessibilityDescription: title)
        icon.contentTintColor = success ? .systemGreen : .systemOrange
        titleLabel.stringValue = title
        detailLabel.stringValue = detail

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - panel.frame.width / 2,
                                         y: visibleFrame.minY + 20))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        feedbackDismissal?.cancel()
        feedbackGeneration += 1
        let generation = feedbackGeneration
        let dismissal = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.feedbackGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    guard self.feedbackGeneration == generation else { return }
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            }
        }
        feedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 1.25 : 2.4), execute: dismissal)
    }

    private func createFeedbackPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 82),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .medium)
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            labels.widthAnchor.constraint(equalToConstant: 300),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        panel.contentView = background
        feedbackPanel = panel
        feedbackIcon = icon
        feedbackTitle = title
        feedbackDetail = detail
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            showFeedback(title: "Launch at Login unavailable", detail: "This requires macOS 13 or later.", success: false)
            return
        }
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
            updateLoginAtStartupState()
        } catch {
            showFeedback(title: "Couldn’t change Launch at Login", detail: error.localizedDescription, success: false)
        }
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyCallback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard handlerStatus == noErr, let registeredHotKey = register(shortcut) else {
            showFeedback(title: "Shortcut unavailable", detail: "\(shortcut.displayName) is already in use.", success: false)
            return
        }
        hotKey = registeredHotKey
    }

    private func register(_ shortcut: GlobalShortcut) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x54534E50, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &reference
        )
        return status == noErr ? reference : nil
    }

    private func replaceShortcut(with replacement: GlobalShortcut) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        self.hotKey = nil
        guard let registered = register(replacement) else {
            hotKey = register(shortcut)
            showFeedback(title: "Shortcut unavailable", detail: "\(replacement.displayName) is already in use.", success: false)
            return
        }
        shortcut = replacement
        hotKey = registered
        if let data = try? JSONEncoder().encode(replacement) {
            UserDefaults.standard.set(data, forKey: "captureShortcut")
        }
        captureItem.title = "Capture Text (\(shortcut.displayName))"
        shortcutControl.title = shortcut.displayName
        statusItem.button?.toolTip = "Capture text · \(shortcut.displayName)"
    }

    private func updateLoginAtStartupState() {
        guard #available(macOS 13.0, *) else {
            loginControl.isEnabled = false
            loginDescription.stringValue = "Requires macOS 13 or later."
            return
        }
        loginControl.isEnabled = true
        switch SMAppService.mainApp.status {
        case .enabled:
            loginControl.state = .on
            loginDescription.stringValue = "TextS opens automatically when you sign in."
        case .requiresApproval:
            loginControl.state = .on
            loginDescription.stringValue = "Allow TextS in System Settings → Login Items."
        default:
            loginControl.state = .off
            loginDescription.stringValue = "Open TextS automatically when you sign in."
        }
    }

}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateLoginAtStartupState()
    }
}

@main
private enum TextSApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
