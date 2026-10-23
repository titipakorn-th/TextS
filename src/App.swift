import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import ServiceManagement

enum CaptureOutcome {
    /// The recognized text is on the clipboard.
    case success
    /// The user backed out of the region selection, so there is nothing to report.
    case canceled
    /// A real answer about the selection. Repeating it will not change it.
    case rejected(String)
    /// The helper could not answer. This is about the helper, not the
    /// selection, and a fresh helper may still read it.
    case helperFailed(String)
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
final class OCRWorker: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let queue = DispatchQueue(label: "com.prince.textsniper.ocr")

    var isRunning: Bool { process.isRunning }

    /// Vision keeps state for every image it reads, so this is a backstop, not
    /// the main defence: the helper now holds steady at around 190 MB. It
    /// exists because runaway growth shows up as an unreadable image rather
    /// than as an error anyone can act on, and a restart recovers cleanly.
    private static let residentByteLimit: UInt64 = 600 * 1024 * 1024

    /// How long the accurate recognizer may take to answer. The neural engine
    /// compiles the recognition models the first time a picture is read, and
    /// on a cold Mac that takes tens of seconds. A capture that runs into that
    /// has to be allowed to finish, because a request cut short leaves the
    /// models half-built and the next one no faster.
    static let accurateFrameTimeout: TimeInterval = 90

    /// How long the quick recognizer may take. It carries a lighter model, so
    /// it answers as soon as that model is loaded.
    static let quickFrameTimeout: TimeInterval = 45

    private let frameTimeoutOverride: TimeInterval?

    var overMemoryLimit: Bool { residentSize > Self.residentByteLimit }

    private var residentSize: UInt64 {
        guard process.isRunning else { return 0 }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        // `task_info` needs a Mach port, not a pid, so this is the route that
        // works against a child process we only know by pid.
        guard proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, size) == size else {
            return 0
        }
        return UInt64(info.pti_resident_size)
    }

    init?(frameTimeout: TimeInterval? = nil) {
        self.frameTimeoutOverride = frameTimeout
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
            // One deadline covers the whole frame. Reading the pipe directly
            // waited for as long as the helper wanted, including forever when
            // it wedged, and that left the app unable to capture anything again.
            // The accurate recognizer gets more room because it may still be
            // waiting for the neural engine to compile its models.
            let timeout = frameTimeoutOverride ?? (fast ? Self.quickFrameTimeout : Self.accurateFrameTimeout)
            let deadline = Date().addingTimeInterval(timeout)
            let request = fast ? "fast\t\(path)\n" : "\(path)\n"
            do {
                try input.write(contentsOf: Data(request.utf8))
            } catch {
                return .helperFailed("Could not reach the OCR helper: \(error.localizedDescription)")
            }
            return readFrame(deadline: deadline)
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func readFrame(deadline: Date) -> CaptureOutcome {
        guard let header = readLine(deadline: deadline) else {
            return .helperFailed("The OCR helper stopped responding.")
        }
        let parts = header.split(separator: " ")
        guard parts.count == 2, let length = Int(parts[1]), length >= 0 else {
            return .helperFailed("Unreadable response from the OCR helper.")
        }
        guard let payload = readExactly(length, deadline: deadline) else {
            return .helperFailed("The OCR helper stopped responding.")
        }
        switch parts[0] {
        case "OK":
            return payload.isEmpty ? .rejected("No text found") : .success
        case "HELPER_ERROR":
            return .helperFailed(payload.isEmpty ? "The OCR helper stopped responding." : payload)
        case "ERROR":
            return .rejected(payload.isEmpty ? "TextS could not read that selection." : payload)
        default:
            return .helperFailed("Unreadable response from the OCR helper.")
        }
    }

    private func readLine(deadline: Date) -> String? {
        var bytes: [UInt8] = []
        while let byte = readByte(deadline: deadline) {
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        // A line that never arrived terminated is not a header, so it is not
        // handed back as one.
        return nil
    }

    /// Returns nil when the frame is short. Reporting the bytes that did arrive
    /// would leave the rest of the frame in the pipe, and the next capture
    /// would read that remainder as its header.
    private func readExactly(_ count: Int, deadline: Date) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 4096))
        while data.count < count {
            guard waitReadable(deadline: deadline) else { return nil }
            let bytesRead = Darwin.read(output.fileDescriptor, &buffer, min(buffer.count, count - data.count))
            if bytesRead < 0 && errno == EINTR { continue }
            guard bytesRead > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func readByte(deadline: Date) -> UInt8? {
        guard waitReadable(deadline: deadline) else { return nil }
        guard let chunk = try? output.read(upToCount: 1), let byte = chunk.first else { return nil }
        return byte
    }

    /// Waits for the helper to write, up to the deadline. A hang is reported as
    /// a failure the app can recover from, instead of a capture that never ends.
    private func waitReadable(deadline: Date) -> Bool {
        var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let result = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if result > 0 { return Int32(descriptor.revents) & (POLLIN | POLLHUP | POLLERR) != 0 }
            if result == 0 { continue }
            if errno == EINTR { continue }
            return false
        }
    }
}

/// Copies what the user had on the pasteboard. `screencapture -c` writes the
/// selection there, and without this the screenshot stays on the clipboard for
/// the whole recognition, so reaching for it mid-capture pastes a picture.
private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
    guard let items = pasteboard.pasteboardItems else { return nil }
    return items.map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
}

/// What the region selection produced.
private enum RegionSelection {
    case image(URL)
    case canceled
    case failed(String)
}

/// Reads the selection and hands it to the helper. The cropped image is kept
/// when the helper fails to answer, so a broken helper costs a second attempt
/// by a fresh one instead of failing every capture from then on. Re-selecting
/// the region is not asked for again.
private func captureSelection(
    fast: Bool,
    onRecognizing: @escaping () -> Void,
    worker: @escaping () -> OCRWorker?,
    replacement: @escaping () -> OCRWorker?
) -> CaptureOutcome {
    let imageURL: URL
    switch selectRegion() {
    case .image(let url):
        imageURL = url
    case .canceled:
        return .canceled
    case .failed(let message):
        return .rejected(message)
    }
    defer { try? FileManager.default.removeItem(at: imageURL) }

    return recognizeSelection(at: imageURL.path, fast: fast, onRecognizing: onRecognizing,
                              worker: worker, replacement: replacement)
}

func recognizeSelection(
    at path: String,
    fast: Bool,
    onRecognizing: () -> Void = {},
    worker: () -> OCRWorker?,
    replacement: () -> OCRWorker?
) -> CaptureOutcome {
    guard let ocr = worker() else { return .rejected("Could not start OCR.") }
    onRecognizing()
    let outcome = ocr.recognize(at: path, fast: fast)
    guard case .helperFailed = outcome, let fresh = replacement() else { return outcome }
    onRecognizing()
    return fresh.recognize(at: path, fast: fast)
}

/// The recognizer a capture uses.
enum Recognizer {
    case accurate
    /// The quick one, because the setting asks for it.
    case quickForSpeed

    /// What the settings window shows, so the mode in use is never a guess.
    var status: String {
        switch self {
        case .accurate:
            return "In use: the accurate recognizer."
        case .quickForSpeed:
            return "In use: the quick recognizer. Faster recognition is on."
        }
    }
}

func recognizerInUse(settingOn: Bool) -> Recognizer {
    settingOn ? .quickForSpeed : .accurate
}

/// Grabs the region `screencapture -i -c` writes to the clipboard.
private func selectRegion() -> RegionSelection {
    let pasteboard = NSPasteboard.general
    let saved = DispatchQueue.main.sync { snapshot(pasteboard) }
    let initialChangeCount = DispatchQueue.main.sync { pasteboard.changeCount }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-i", "-c", "-x"]
    do {
        try capture.run()
        capture.waitUntilExit()
    } catch {
        return .failed("Could not start screen capture: \(error.localizedDescription)")
    }
    guard capture.terminationStatus == 0 else { return .canceled }

    let imageData: Data? = DispatchQueue.main.sync { () -> Data? in
        guard pasteboard.changeCount != initialChangeCount else { return nil }
        let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        // Hand the clipboard back before the slow part starts. OCR overwrites it
        // with the recognized text when it finishes, but nothing should be
        // holding the cropped screenshot in the meantime.
        if let saved {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        return data
    }
    guard let imageData else { return .failed("No cropped image was captured") }

    let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("textsniper-\(UUID().uuidString).png")
    do {
        try imageData.write(to: imageURL)
    } catch {
        return .failed("Could not save the cropped image: \(error.localizedDescription)")
    }
    return .image(imageURL)
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
    private var recognizerStatus: NSTextField!
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
        startWarmup()
        checkForUpdatesInBackground()
    }

    /// Loads the recognition models ahead of the first capture.
    ///
    /// The neural engine compiles these models the first time a picture is
    /// read, and on a busy Mac that takes over a minute. Doing it here keeps
    /// that wait off the capture. It runs in a throwaway process because a
    /// read that takes that long leaves the recognizer unable to read
    /// anything else, and this one has no more reading to do.
    ///
    /// Nothing waits for this and nothing depends on it. The mode a capture
    /// uses is the mode the user picked, whatever this is doing.
    private func startWarmup() {
        guard let imageURL = Self.warmupImage() else { return }
        let warmup = Process()
        warmup.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/textsniper-rs")
        warmup.arguments = ["--warmup", imageURL.path]
        warmup.standardOutput = FileHandle.nullDevice
        warmup.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async {
            do {
                try warmup.run()
                warmup.waitUntilExit()
            } catch {
                // A warmup that cannot start is not worth reporting: the
                // capture will read the models itself if it has to.
            }
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    /// A short line of text in the scripts the accurate recognizer is needed
    /// for. It only has to be readable: the point is to pull the models in, so
    /// a small picture is quick to read once they arrive. Every script the
    /// recognizer is asked for appears here, so the models it needs are the
    /// ones this warms.
    private static func warmupImage() -> URL? {
        let size = NSSize(width: 520, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let lines = ["TextS is loading its recognizer", "中文字符识别", "中文字符識別",
                     "日本語の文字", "한국어 문자"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(
                in: NSRect(x: 16, y: 16 + CGFloat(index) * 32, width: size.width - 32, height: 32),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20),
                                 .foregroundColor: NSColor.black])
        }
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
            let outcome = captureSelection(
                fast: fast,
                onRecognizing: { DispatchQueue.main.async { self?.showRecognizing() } },
                worker: { worker },
                replacement: { DispatchQueue.main.sync { self?.restartOCR() } }
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturing = false
                switch outcome {
                case .success:
                    self.showFeedback(title: "Copied to clipboard", detail: "Your text is ready to paste.", success: true)
                case .canceled:
                    break
                case .rejected(let message):
                    self.showFeedback(title: "Couldn’t copy text", detail: message, success: false)
                case .helperFailed(let message):
                    // This helper is no longer answering, so it is retired here
                    // and the next capture starts a clean one.
                    self.retireOCR()
                    self.showFeedback(title: "Couldn’t copy text", detail: message, success: false)
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
        // The quick recognizer has a model for a few languages only, and it
        // makes nonsense of the others instead of admitting it cannot read
        // them. The setting says what it covers.
        fastDescription = NSTextField(wrappingLabelWithString: "Quicker results for English, French, German, Italian, Spanish and Portuguese. Other languages can come back as nonsense.")
        fastDescription.font = NSFont.systemFont(ofSize: 11)
        fastDescription.textColor = .secondaryLabelColor
        fastDescription.maximumNumberOfLines = 2
        let fastRow = NSStackView(views: [fastControl, fastDescription])
        fastRow.orientation = .vertical
        fastRow.alignment = .leading
        fastRow.spacing = 4

        recognizerStatus = NSTextField(wrappingLabelWithString: "")
        recognizerStatus.font = .systemFont(ofSize: 11)
        recognizerStatus.textColor = .secondaryLabelColor

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
        let stack = NSStackView(views: [header, divider, sectionTitle, shortcutRow, fastRow, recognizerStatus, loginRow, note])
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
        content.layoutSubtreeIfNeeded()
        // The window grows with its content, so a longer status line never
        // pushes the last row out of view.
        let fitting = stack.fittingSize
        window.setContentSize(NSSize(width: 460, height: max(320, fitting.height + 50)))
        window.center()
        settingsWindow = window
        updateLoginAtStartupState()
        updateFastRecognitionState()
        updateRecognizerStatus()
    }

    @objc private func toggleFastRecognition() {
        let on = fastControl.state == .on
        UserDefaults.standard.set(on, forKey: "fastRecognition")
        updateRecognizerStatus()
    }

    private func updateFastRecognitionState() {
        fastControl.state = fastRecognition ? .on : .off
    }

    /// Shows which recognizer the next capture uses, so the mode is never a
    /// guess.
    private func updateRecognizerStatus() {
        recognizerStatus?.stringValue = recognizerInUse(settingOn: fastRecognition).status
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
        let generation = feedbackGeneration
        icon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Recognizing")
        icon.contentTintColor = .controlAccentColor
        titleLabel.stringValue = "Recognizing…"
        detailLabel.stringValue = "Working on your selection."
        positionFeedback(panel)
        // Loading the models can take a while the first time, so say so
        // rather than leaving the panel looking stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.feedbackGeneration == generation,
                  let detail = self.feedbackDetail else { return }
            guard detail.stringValue == "Working on your selection." else { return }
            detail.stringValue = "Loading the recognizer. This can take a moment."
        }
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

    /// Returns a running helper, starting or replacing one as needed. A helper
    /// that has grown past its memory limit, or that is no longer running, is
    /// retired here so the next capture gets a fresh process.
    private func ensureOCR() -> OCRWorker? {
        if let worker = ocrWorker, worker.isRunning, !worker.overMemoryLimit { return worker }
        ocrWorker?.stop()
        guard let worker = OCRWorker() else { return nil }
        ocrWorker = worker
        return worker
    }

    /// Replaces the helper after one failed to answer. Vision can settle into a
    /// state where every request fails while the process still looks healthy,
    /// and keeping that process made every later capture fail the same way
    /// until TextS was restarted.
    private func restartOCR() -> OCRWorker? {
        retireOCR()
        guard let worker = OCRWorker() else { return nil }
        ocrWorker = worker
        return worker
    }

    private func retireOCR() {
        ocrWorker?.stop()
        ocrWorker = nil
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
