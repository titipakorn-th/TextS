import AppKit
import Foundation
@testable import TextS

// The helper path the app uses, relative to the running executable.
let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/textsniper-rs")

func installHelper(_ body: String) {
    try! FileManager.default.createDirectory(
        at: helperPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! body.write(to: helperPath, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath.path)
}

var failures: [String] = []

func check(_ passed: Bool, _ message: String) {
    if passed {
        print("ok   \(message)")
    } else {
        failures.append(message)
        print("FAIL \(message)")
    }
}

installHelper("#!/bin/sh\nwhile IFS= read -r line; do sleep 6; printf 'OK 5\\nhello'; done\n")
if let worker = OCRWorker() {
    let outcome = worker.recognize(at: "/tmp/texts.png", fast: false)
    if case .success = outcome {
        check(true, "accurate requests may take longer than five seconds")
    } else {
        check(false, "accurate requests may take longer than five seconds")
    }
    worker.stop()
} else { check(false, "slow helper starts") }

check(recognizerInUse(settingOn: false) == .accurate,
      "setting off stays accurate before initialization or after a failure")

installHelper("#!/bin/sh\nwhile IFS= read -r line; do printf 'HELPER_ERROR 6\\nbroken'; done\n")
if let worker = OCRWorker() {
    if case .helperFailed(let message) = worker.recognize(at: "/tmp/texts.png", fast: false) {
        check(message == "broken", "HELPER_ERROR preserves the engine failure for retry")
    } else { check(false, "HELPER_ERROR preserves the engine failure for retry") }
    worker.stop()
} else { check(false, "error helper starts") }

installHelper("#!/bin/sh\nwhile IFS= read -r line; do printf 'OK 5\\nh'; sleep 6; printf 'ello'; done\n")
if let worker = OCRWorker(frameTimeout: 0.2) {
    let start = Date()
    let outcome = worker.recognize(at: "/tmp/texts.png", fast: false)
    if case .helperFailed = outcome {
        check(true, "a stalled partial payload fails within the frame deadline")
    } else { check(false, "a stalled partial payload fails within the frame deadline") }
    check(Date().timeIntervalSince(start) < 2, "a partial payload cannot block past the deadline")
    worker.stop()
} else { check(false, "partial helper starts") }

installHelper("#!/bin/sh\nexec cat > /dev/null\n")
if let worker = OCRWorker(frameTimeout: 0.2) {
    let start = Date()
    if case .helperFailed = worker.recognize(at: "/tmp/texts.png", fast: false) {
        check(true, "a helper that never answers fails")
    } else { check(false, "a helper that never answers fails") }
    check(Date().timeIntervalSince(start) < 2, "a missing header obeys the deadline")
    worker.stop()
} else { check(false, "silent helper starts") }

check(recognizerInUse(settingOn: true) == .quickForSpeed, "setting on selects quick")
check(recognizerInUse(settingOn: false).status != recognizerInUse(settingOn: true).status,
      "settings describe the selected mode")

let selectionPath = "/tmp/texts selection.png"
for fast in [false, true] {
    let request = fast ? "fast\t\(selectionPath)" : selectionPath
    installHelper("#!/bin/sh\nwhile IFS= read -r line; do printf 'HELPER_ERROR 6\\nbroken'; done\n")
    var first: OCRWorker?
    var fresh: OCRWorker?
    var starts = 0
    var replacements = 0
    var progress = 0
    let outcome = recognizeSelection(at: selectionPath, fast: fast, onRecognizing: { progress += 1 }, worker: {
        starts += 1
        first = OCRWorker()
        return first
    }, replacement: {
        replacements += 1
        first?.stop()
        installHelper("#!/bin/sh\nwhile IFS= read -r line; do if [ \"$line\" = '\(request)' ]; then printf 'OK 5\\nhello'; else printf 'ERROR 13\\nwrong request'; fi; done\n")
        fresh = OCRWorker()
        return fresh
    })
    if case .success = outcome {
        check(true, "restart retries the same image and mode (fast=\(fast))")
    } else { check(false, "restart retries the same image and mode (fast=\(fast))") }
    check(starts == 1 && replacements == 1 && progress == 2,
          "helper failure gets exactly one fresh attempt (fast=\(fast))")
    first?.stop()
    fresh?.stop()
}

for frame in ["ERROR 13\nno text found", "HELPER_ERROR 6\nbroken", "bad header\n", "OK 5\nhello"] {
    installHelper("#!/bin/sh\nwhile IFS= read -r line; do printf '\(frame)'; done\n")
    var workers: [OCRWorker] = []
    var replacements = 0
    func startWorker() -> OCRWorker? {
        let worker = OCRWorker()
        if let worker { workers.append(worker) }
        return worker
    }
    let outcome = recognizeSelection(at: selectionPath, fast: false, worker: startWorker, replacement: {
        replacements += 1
        workers.last?.stop()
        return startWorker()
    })
    switch outcome {
    case .rejected(let message):
        check(frame.hasPrefix("ERROR") && message == "no text found" && replacements == 0,
              "a rejected selection preserves its error and never retries")
    case .helperFailed:
        check((frame.hasPrefix("HELPER_ERROR") || frame.hasPrefix("bad")) && replacements == 1,
              "repeated helper failures stop after one retry")
    case .success:
        check(frame.hasPrefix("OK") && replacements == 0, "success never retries")
    default:
        check(false, "unexpected recognition outcome")
    }
    for worker in workers { worker.stop() }
    check(recognizerInUse(settingOn: false) == .accurate,
          "setting off remains accurate after \(frame.components(separatedBy: " ")[0])")
}

var replacementCalls = 0
let missingWorker = recognizeSelection(at: selectionPath, fast: false, worker: { nil }, replacement: {
    replacementCalls += 1
    return nil
})
if case .rejected = missingWorker {
    check(replacementCalls == 0, "worker startup failure does not retry a selection")
} else { check(false, "worker startup failure is reported") }

func checkRealOCR() throws {
    guard CommandLine.arguments.count == 3 else {
        check(false, "real helper and fixture directory are required")
        return
    }
    try FileManager.default.removeItem(at: helperPath)
    try FileManager.default.copyItem(atPath: CommandLine.arguments[1], toPath: helperPath.path)
    let pasteboard = NSPasteboard.general
    let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    } ?? []
    defer {
        pasteboard.clearContents()
        pasteboard.writeObjects(saved)
    }

    var worker = OCRWorker()
    defer { worker?.stop() }
    // Load the models first, the way the app does at launch. The neural
    // engine compiles them the first time a picture is read, and a read that
    // waits for that leaves the helper unable to read anything else, so the
    // checks below would be measuring the cold start rather than the helper.
    let chinesePath = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("chinese.png").path
    let warmup = Process()
    warmup.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    warmup.arguments = ["--warmup", chinesePath]
    warmup.standardOutput = FileHandle.nullDevice
    warmup.standardError = FileHandle.nullDevice
    try warmup.run()
    warmup.waitUntilExit()
    let fixtures: [(String, Bool, [String])] = [
        ("chinese", false, ["你好，世界。"]),
        ("mixed", false, ["偏好设置", "Preferences"]),
        ("chinese", false, ["你好，世界。"]),
        ("mixed", false, ["偏好设置", "Preferences"]),
        ("chinese_small", true, ["这是一个中文识别测试。"])
    ]
    for (name, fast, expected) in fixtures {
        pasteboard.clearContents()
        pasteboard.setString("TextS fixture sentinel", forType: .string)
        let path = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("\(name).png").path
        var restarts = 0
        let outcome = recognizeSelection(at: path, fast: fast, worker: { worker }, replacement: {
            restarts += 1
            worker?.stop()
            worker = OCRWorker()
            return worker
        })
        guard case .success = outcome else {
            check(false, "real \(name) OCR (fast=\(fast)) returned \(outcome)")
            return
        }
        let text = pasteboard.string(forType: .string) ?? ""
        check(expected.allSatisfy(text.contains),
              "real \(name) OCR (fast=\(fast)) copies expected text; restarts=\(restarts); read \(text.debugDescription)")
        check(restarts == 0,
              "real \(name) OCR (fast=\(fast)) needs no helper restart; the helper keeps reading")
    }
}

do {
    try checkRealOCR()
} catch {
    check(false, "real OCR integration failed: \(error)")
}

if failures.isEmpty {
    print("all checks passed")
    exit(0)
}
print("\(failures.count) check(s) failed")
exit(1)
