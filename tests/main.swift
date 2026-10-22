import Foundation
@testable import TextS

// The helper path the app uses, relative to the running executable.
let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/textsniper-rs")

func installHelper(_ body: String) {
    try? FileManager.default.createDirectory(
        at: helperPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? body.write(to: helperPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath.path)
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

// A helper that never answers, which is how a wedged recognizer looks.
installHelper("#!/bin/sh\ncat > /dev/null\n")

if let worker = OCRWorker() {
    let start = Date()
    let outcome = worker.recognize(at: "/tmp/texts.png", fast: false)
    let elapsed = Date().timeIntervalSince(start)
    if case .helperFailed = outcome {
        check(true, "the accurate recognizer gives up on a helper that never answers")
    } else {
        check(false, "the accurate recognizer gives up on a helper that never answers")
    }
    // The deadline used to be 90 seconds, which left the app stuck for a
    // minute and a half before it tried anything else.
    check(elapsed < 20, "the accurate recognizer gives up in \(Int(elapsed))s, not 90s")
    worker.stop()
} else {
    check(false, "a helper starts")
}

// A helper that answers: the same image read again with the quick recognizer
// is reported as coming from the quick recognizer.
installHelper("#!/bin/sh\nwhile IFS= read -r line; do printf 'OK 5\\nhello'; done\n")

if let worker = OCRWorker() {
    let outcome = rereadWithQuickRecognizer(worker, path: "/tmp/texts.png")
    if case .successQuick = outcome {
        check(true, "a fresh helper reads the image with the quick recognizer")
    } else {
        check(false, "a fresh helper reads the image with the quick recognizer")
    }
    worker.stop()
}

// Turning "Faster recognition" off has to bring the accurate recognizer back.
// It stops working on some Macs after a request, and the app falls back to
// the quick one, which cannot read Chinese, Japanese or Korean.
check(accurateRecognizerAfterToggle(settingOn: false, wasReady: false),
      "turning the setting off brings the accurate recognizer back")
check(accurateRecognizerAfterToggle(settingOn: false, wasReady: true),
      "turning the setting off keeps the accurate recognizer")
check(accurateRecognizerAfterToggle(settingOn: true, wasReady: true),
      "turning the setting on leaves the accurate recognizer as it was")
check(!accurateRecognizerAfterToggle(settingOn: true, wasReady: false),
      "turning the setting on leaves the accurate recognizer as it was")

// The mode the settings window shows has to be the mode a capture uses.
check(recognizerInUse(settingOn: false, accurateReady: true) == .accurate,
      "the accurate recognizer is used when the setting is off and it works")
check(recognizerInUse(settingOn: true, accurateReady: true) == .quickForSpeed,
      "the quick recognizer is used when the setting is on")
check(recognizerInUse(settingOn: false, accurateReady: false) == .quickBecauseAccurateFailed,
      "the quick recognizer takes over when the accurate one is not working")
check(recognizerInUse(settingOn: false, accurateReady: true).status != recognizerInUse(settingOn: true, accurateReady: true).status,
      "the status line tells the two modes apart")

if failures.isEmpty {
    print("all checks passed")
    exit(0)
}
print("\(failures.count) check(s) failed")
exit(1)
