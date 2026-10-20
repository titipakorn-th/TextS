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

if failures.isEmpty {
    print("all checks passed")
    exit(0)
}
print("\(failures.count) check(s) failed")
exit(1)
