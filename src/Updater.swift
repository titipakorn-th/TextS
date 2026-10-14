import AppKit
import Foundation

/// A published release that is newer than the running build.
struct ReleaseInfo {
    let version: String
    let downloadURL: URL
    let pageURL: URL
}

struct UpdateError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Checks GitHub releases for a newer build and installs it from the published
/// disk image. TextS is ad-hoc signed and not notarized, so this replaces the
/// app bundle directly instead of using a framework updater.
enum Updater {

    private static let repository = "titipakorn-th/TextS"
    private static let applicationsPath = "/Applications/TextS.app"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Version comparison

    /// Compares dotted numeric versions, ignoring a leading `v`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            return trimmed.split(separator: ".").map { Int($0) ?? 0 }
        }
        let candidateParts = parts(candidate)
        let currentParts = parts(current)
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let left = index < candidateParts.count ? candidateParts[index] : 0
            let right = index < currentParts.count ? currentParts[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Release lookup

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    /// Returns the newest published release when it beats the running build.
    static func checkLatest(completion: @escaping (ReleaseInfo?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TextS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  let diskImage = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard isNewer(version, than: currentVersion) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let info = ReleaseInfo(version: version,
                                   downloadURL: diskImage.browserDownloadURL,
                                   pageURL: release.htmlURL)
            DispatchQueue.main.async { completion(info) }
        }.resume()
    }

    // MARK: - Install

    /// Downloads the disk image, replaces the app in Applications, and relaunches.
    static func install(_ release: ReleaseInfo,
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Result<Void, UpdateError>) -> Void) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextS-\(release.version).dmg")
        let cleanup = { try? FileManager.default.removeItem(at: destination) }

        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 120
        let task = URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            let fail: (String) -> Void = { message in
                cleanup()
                DispatchQueue.main.async { completion(.failure(UpdateError(message))) }
            }
            if let error { return fail(error.localizedDescription) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return fail("The download failed (HTTP \(http.statusCode)).")
            }
            guard let temporaryURL else { return fail("The download did not finish.") }
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            } catch {
                return fail("Could not save the update: \(error.localizedDescription)")
            }

            DispatchQueue.global(qos: .userInitiated).async {
                switch replaceApp(using: destination.path) {
                case .success:
                    cleanup()
                    DispatchQueue.main.async { completion(.success(())) }
                case .failure(let error):
                    cleanup()
                    fail(error.message)
                }
            }
        }
        progress("Downloading \(release.version)…")
        task.resume()
    }

    private enum InstallFailure: Error {
        case message(String)
    }

    private static func replaceApp(using diskImage: String) -> Result<Void, UpdateError> {
        let mounted: URL
        do {
            mounted = try mount(diskImage: diskImage)
        } catch {
            return .failure(UpdateError(error.localizedDescription))
        }
        defer { detach(mountPoint: mounted) }

        let source = mounted.appendingPathComponent("TextS.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(UpdateError("The update did not contain TextS.app."))
        }

        let target = URL(fileURLWithPath: applicationsPath)
        let previous = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextS-\(UUID().uuidString).app")
        let hadPrevious = FileManager.default.fileExists(atPath: target.path)
        if hadPrevious {
            do {
                try FileManager.default.moveItem(at: target, to: previous)
            } catch {
                return .failure(UpdateError("Could not replace the installed app: \(error.localizedDescription)"))
            }
        }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [source.path, target.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            restore(previous, to: target, hadPrevious: hadPrevious)
            return .failure(UpdateError("Could not copy the update: \(error.localizedDescription)"))
        }
        guard ditto.terminationStatus == 0 else {
            restore(previous, to: target, hadPrevious: hadPrevious)
            return .failure(UpdateError("Could not copy the update."))
        }
        try? FileManager.default.removeItem(at: previous)
        return .success(())
    }

    private static func restore(_ previous: URL, to target: URL, hadPrevious: Bool) {
        try? FileManager.default.removeItem(at: target)
        if hadPrevious {
            try? FileManager.default.moveItem(at: previous, to: target)
        }
    }

    private static func mount(diskImage: String) throws -> URL {
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", diskImage, "-nobrowse", "-readonly"]
        let output = Pipe()
        attach.standardOutput = output
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            throw InstallFailure.message("Could not open the update disk image.")
        }
        let text = String(decoding: data, as: UTF8.self)
        let mountPoints = text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let last = fields.last, last.hasPrefix("/Volumes/") else { return nil }
            return last
        }
        guard let mountPoint = mountPoints.last else {
            throw InstallFailure.message("The update disk image did not mount.")
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private static func detach(mountPoint: URL) {
        let detachProcess = Process()
        detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProcess.arguments = ["detach", mountPoint.path, "-quiet"]
        detachProcess.standardOutput = FileHandle.nullDevice
        detachProcess.standardError = FileHandle.nullDevice
        try? detachProcess.run()
        detachProcess.waitUntilExit()
    }

    /// Starts the freshly installed app after this one quits, so the two never
    /// compete for the global shortcut.
    static func relaunch() {
        let starter = Process()
        starter.executableURL = URL(fileURLWithPath: "/bin/sh")
        starter.arguments = ["-c", "sleep 1; exec \(applicationsPath)/Contents/MacOS/TextS"]
        starter.standardOutput = FileHandle.nullDevice
        starter.standardError = FileHandle.nullDevice
        try? starter.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}