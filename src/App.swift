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

/// Keeps one `textsniper-rs --server` process alive so Vision stays loaded
/// between captures instead of starting a fresh OCR process every time.
private final class OCRWorker: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let queue = DispatchQueue(label: "com.prince.textsniper.ocr")

    var isRunning: Bool { process.isRunning }

    init?() {
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/textsniper-rs")
        process.arguments = ["--server"]
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardInput = inputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    func recognize(at path: String, fast: Bool) -> CaptureOutcome {
        queue.sync {
            let request = fast ? "fast\t\(path)\n" : "\(path)\n"
            do {
                try input.write(contentsOf: Data(request.utf8))
            } catch {
                return .failure("Could not reach the OCR helper: \(error.localizedDescription)")
            }
            return readFrame()
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func readFrame() -> CaptureOutcome {
        guard let header = readLine() else {
            return .failure("The OCR helper stopped responding.")
        }
        let parts = header.split(separator: " ")
        guard parts.count == 2, let length = Int(parts[1]), length >= 0 else {
            return .failure("Unreadable response from the OCR helper.")
        }
        let payload = readExactly(length)
        switch parts[0] {
        case "OK":
            return payload.isEmpty ? .failure("No text found") : .success
        default:
            return .failure(payload.isEmpty ? "Unreadable response from the OCR helper." : payload)
        }
    }

    private func readLine() -> String? {
        var bytes: [UInt8] = []
        while let byte = readByte() {
            if byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private func readExactly(_ count: Int) -> String {
        var data = Data()
        while data.count < count {
            guard let chunk = try? output.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func readByte() -> UInt8? {
        guard let chunk = try? output.read(upToCount: 1), let byte = chunk.first else { return nil }
        return byte
    }
}

private func captureAndRecognize(ocr: OCRWorker, fast: Bool, onRecognizing: () -> Void) -> CaptureOutcome {
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

    onRecognizing()
    return ocr.recognize(at: imageURL.path, fast: fast)
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var checkItem: NSMenuItem!
    private var versionItem: NSMenuItem!
    private var availableRelease: ReleaseInfo?
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
    private var ocrWorker: OCRWorker?
    private var fastControl: NSButton!
    private var fastDescription: NSTextField!
    private var fastRecognition: Bool { UserDefaults.standard.bool(forKey: "fastRecognition") }
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
        updateItem = NSMenuItem(title: "Update", action: #selector(installUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
        versionItem = NSMenuItem(title: "Version \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TextS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "TextS")
        statusItem.button?.toolTip = "Capture text · \(shortcut.displayName)"
        statusItem.menu = menu
        menu.delegate = self
        registerHotKey()
        createSettingsWindow()
        startOCR()
        checkForUpdatesInBackground()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        ocrWorker?.stop()
        ocrWorker = nil
    }

    @objc func capture() {
        guard !isCapturing else { return }
        guard let worker = ensureOCR() else {
            showFeedback(title: "Couldn’t copy text", detail: "Could not start OCR.", success: false)
            return
        }
        isCapturing = true
        let fast = fastRecognition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = captureAndRecognize(ocr: worker, fast: fast) {
                DispatchQueue.main.async { self?.showRecognizing() }
            }
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

        fastControl = NSButton(checkboxWithTitle: "Faster recognition", target: self, action: #selector(toggleFastRecognition))
        fastDescription = NSTextField(wrappingLabelWithString: "Quicker results, with slightly less accurate text.")
        fastDescription.font = NSFont.systemFont(ofSize: 11)
        fastDescription.textColor = .secondaryLabelColor
        fastDescription.maximumNumberOfLines = 2
        let fastRow = NSStackView(views: [fastControl, fastDescription])
        fastRow.orientation = .vertical
        fastRow.alignment = .leading
        fastRow.spacing = 4

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
        let stack = NSStackView(views: [header, divider, sectionTitle, shortcutRow, fastRow, loginRow, note])
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
        updateFastRecognitionState()
    }

    @objc private func toggleFastRecognition() {
        UserDefaults.standard.set(fastControl.state == .on, forKey: "fastRecognition")
    }

    private func updateFastRecognitionState() {
        fastControl.state = fastRecognition ? .on : .off
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func positionFeedback(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - panel.frame.width / 2,
                                         y: visibleFrame.minY + 20))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Shown as soon as a region is selected, so a slow recognition reads as
    /// progress instead of a hang. `showFeedback` replaces it with the result.
    private func showRecognizing() {
        if feedbackPanel == nil { createFeedbackPanel() }
        guard let panel = feedbackPanel,
              let icon = feedbackIcon,
              let titleLabel = feedbackTitle,
              let detailLabel = feedbackDetail else { return }

        feedbackDismissal?.cancel()
        feedbackGeneration += 1
        icon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Recognizing")
        icon.contentTintColor = .controlAccentColor
        titleLabel.stringValue = "Recognizing…"
        detailLabel.stringValue = "Working on your selection."
        positionFeedback(panel)
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

        positionFeedback(panel)

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

    /// Loads the OCR models at launch so the first capture finds them already
    /// in memory, and keeps one helper process alive for the whole session.
    private func startOCR() {
        guard let worker = ensureOCR() else { return }
        guard let imageURL = Self.warmupImage() else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = worker.recognize(at: imageURL.path, fast: false)
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    private func ensureOCR() -> OCRWorker? {
        if let worker = ocrWorker, worker.isRunning { return worker }
        ocrWorker = OCRWorker()
        return ocrWorker
    }

    private static func warmupImage() -> URL? {
        let size = NSSize(width: 180, height: 48)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("TextS" as NSString).draw(at: NSPoint(x: 14, y: 15),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 24),
                                                    .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("textsniper-warmup-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    @objc private func checkForUpdates() {
        Updater.checkLatest { [weak self] release in
            guard let self else { return }
            if let release {
                self.applyAvailable(release)
                self.showFeedback(title: "Update available",
                                  detail: "TextS \(release.version) is ready to install.",
                                  success: true)
            } else {
                self.showFeedback(title: "You’re up to date",
                                  detail: "TextS \(Updater.currentVersion) is the latest version.",
                                  success: true)
            }
        }
    }

    /// Quiet launch-time check, at most once every six hours so the menu never
    /// waits on the network.
    private func checkForUpdatesInBackground() {
        let lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) > 6 * 60 * 60 else { return }
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        Updater.checkLatest { [weak self] release in
            guard let self, let release else { return }
            self.applyAvailable(release)
        }
    }

    private func applyAvailable(_ release: ReleaseInfo) {
        availableRelease = release
        updateItem.title = "Update to \(release.version)…"
        updateItem.isHidden = false
    }

    @objc private func installUpdate() {
        guard let release = availableRelease else { return }
        updateItem.isEnabled = false
        showFeedback(title: "Updating TextS", detail: "Downloading \(release.version)…", success: true)
        Updater.install(release,
                        progress: { [weak self] message in
                            DispatchQueue.main.async {
                                self?.showFeedback(title: "Updating TextS", detail: message, success: true)
                            }
                        },
                        completion: { [weak self] result in
                            guard let self else { return }
                            self.updateItem.isEnabled = true
                            switch result {
                            case .success:
                                self.showFeedback(title: "Update installed",
                                                  detail: "Restarting TextS…",
                                                  success: true)
                                Updater.relaunch()
                            case .failure(let error):
                                self.showFeedback(title: "Couldn’t update",
                                                  detail: error.message,
                                                  success: false)
                            }
                        })
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
        checkForUpdatesInBackground()
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
