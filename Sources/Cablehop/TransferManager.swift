import AppKit
import Observation
import UserNotifications

enum TransferDirection: Sendable { case push, pull, install }

enum TransferState: Equatable {
    case queued, running, done, cancelled
    case failed(String)

    var isActive: Bool { self == .queued || self == .running }
}

@MainActor
@Observable
final class Transfer: Identifiable {
    let id = UUID()
    let serial: String
    let direction: TransferDirection
    let name: String
    let source: String
    /// For downloads, may change to "Name 2" if something else took the name before the copy finished.
    private(set) var destination: String
    let isDirectory: Bool
    var state: TransferState = .queued
    var progress: Double = 0
    var detail = ""
    var totalBytes: Int64?
    var startedAt: Date?
    @ObservationIgnored var runner: PTYProcess?
    @ObservationIgnored var cancelToken: CancelToken?

    init(serial: String, direction: TransferDirection, name: String, source: String, destination: String,
         isDirectory: Bool, totalBytes: Int64? = nil) {
        self.serial = serial
        self.direction = direction
        self.name = name
        self.source = source
        self.destination = destination
        self.isDirectory = isDirectory
        self.totalBytes = totalBytes
    }

    /// Uploads into a folder (vs. sync uploads, which name the exact file path).
    var destinationIsFolder: Bool { direction == .push && !isExactPath }
    var isExactPath = false
    /// A drag into Finder: Finder drives the copy, so it can't be retried from here.
    var isExternal = false

    fileprivate func moveDestination(to path: String) { destination = path }

    /// Updates progress at most every half percent, so a fast copy doesn't redraw the UI hundreds of
    /// times a second.
    func updateProgress(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        if clamped >= 1 || abs(clamped - progress) >= 0.005 { progress = clamped }
    }

    /// "download of “IMG_1234.jpg” (4.2 MB, file transfer)" for the logs.
    var logLabel: String {
        let kind = direction == .push ? "upload" : direction == .pull ? "download" : "app install"
        let size = totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unknown"
        let mode = Phones.isMTP(serial) ? "file transfer" : "adb"
        return "\(kind) of “\(name)”\(isDirectory ? " (folder)" : "") (\(size), \(mode))"
    }

    /// Where a download is written until it completes.
    var partialPath: String { destination + ".cablehop-part" }

    /// Average speed so far, from adb's percentage and the known total size.
    var bytesPerSecond: Double? {
        guard state == .running, let totalBytes, let startedAt, progress > 0.01 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return nil }
        return Double(totalBytes) * progress / elapsed
    }

    var secondsRemaining: Double? {
        guard let speed = bytesPerSecond, speed > 0, let totalBytes else { return nil }
        return Double(totalBytes) * (1 - progress) / speed
    }
}

@MainActor
@Observable
final class TransferManager {
    private(set) var items: [Transfer] = []
    /// Bumped whenever a transfer finishes, so file browsers know to refresh.
    private(set) var completionTick = 0
    /// Bumped whenever new transfers are added, so the transfers popover can open itself.
    private(set) var startedTick = 0
    @ObservationIgnored private(set) var lastCompleted: Transfer?
    @ObservationIgnored private var reservedPaths: Set<String> = []
    @ObservationIgnored private var batchDone = 0
    @ObservationIgnored private var batchFailed = 0
    @ObservationIgnored private var sleepAssertion: NSObjectProtocol?
    private let maxConcurrent = 2

    /// The app's one instance, so the app delegate can ask about running transfers at quit time.
    @ObservationIgnored static weak var current: TransferManager?

    /// Finished transfers, newest first, kept across launches.
    private(set) var history: [TransferRecord] = TransferRecord.load()

    init() {
        TransferManager.current = self
    }

    /// Progress of everything still running or waiting, weighted by size (0...1), for the toolbar ring.
    var overallProgress: Double? {
        let active = items.filter { $0.state.isActive }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0.0) { $0 + Double(max($1.totalBytes ?? 1, 1)) }
        let done = active.reduce(0.0) { $0 + Double(max($1.totalBytes ?? 1, 1)) * $1.progress }
        return total > 0 ? done / total : 0
    }

    // MARK: Drag-outs (Finder drives these; we only show them)

    func beginExternal(serial: String, file: RemoteFile, destination: URL) -> Transfer {
        startedTick += 1
        let transfer = Transfer(serial: serial, direction: .pull, name: file.name, source: file.path,
                                destination: destination.path, isDirectory: file.isDirectory,
                                totalBytes: file.isDirectory ? nil : file.size)
        transfer.isExactPath = true
        transfer.isExternal = true
        transfer.state = .running
        transfer.startedAt = Date()
        items.append(transfer)
        pump()
        return transfer
    }

    func endExternal(_ transfer: Transfer?, error: Error?) {
        guard let transfer else { return }
        if let error {
            Log.error("Drag to Finder failed for \(transfer.logLabel): \(error.localizedDescription)", .transfer)
        } else {
            Log.info("Dragged to Finder: \(transfer.logLabel)", .transfer)
        }
        if let error {
            transfer.state = .failed(error.localizedDescription)
            batchFailed += 1
        } else {
            transfer.state = .done
            transfer.progress = 1
            transfer.detail = "Saved to \((transfer.destination as NSString).deletingLastPathComponent.abbreviatingWithTilde)"
            batchDone += 1
        }
        record(transfer)
        lastCompleted = transfer
        completionTick += 1
        pump()
    }

    func clearHistory() {
        history = []
        TransferRecord.save(history)
        clearFinished()
    }

    private func record(_ transfer: Transfer) {
        history.removeAll { $0.id == transfer.id }
        history.insert(TransferRecord(transfer), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        TransferRecord.save(history)
    }

    var activeCount: Int { items.filter { $0.state.isActive }.count }

    func push(_ urls: [URL], serial: String, to remoteDir: String) {
        startedTick += 1
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let transfer = Transfer(serial: serial, direction: .push, name: url.lastPathComponent,
                                    source: url.path, destination: remoteDir, isDirectory: isDir.boolValue)
            items.append(transfer)
            if isDir.boolValue {
                Task.detached(priority: .utility) {
                    let size = LocalFiles.totalSize(of: url)
                    await MainActor.run { transfer.totalBytes = size }
                }
            } else {
                transfer.totalBytes = LocalFiles.size(of: url)
            }
        }
        pump()
    }

    func pull(_ files: [RemoteFile], serial: String, to localDir: URL) {
        startedTick += 1
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        for file in files {
            let dest = Self.uniqueDestination(in: localDir, name: RemotePath.safeLocalName(file.name), reserved: reservedPaths)
            reservedPaths.insert(dest.path)
            let transfer = Transfer(serial: serial, direction: .pull, name: file.name, source: file.path,
                                    destination: dest.path, isDirectory: file.isDirectory,
                                    totalBytes: file.isDirectory ? nil : file.size)
            items.append(transfer)
            if file.isDirectory && !Phones.isMTP(serial) {  // MTP sizes are worked out when the copy starts
                Task {
                    transfer.totalBytes = await ADB.remoteSize(serial: serial, path: file.path)
                }
            }
        }
        pump()
    }

    /// Queues exact source → destination copies (used by folder sync).
    func enqueue(_ copies: [SyncCopy], direction: TransferDirection, serial: String) {
        startedTick += 1
        for copy in copies {
            if direction == .pull {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: copy.destination).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            }
            let transfer = Transfer(serial: serial, direction: direction, name: copy.name, source: copy.source,
                                    destination: copy.destination, isDirectory: false, totalBytes: copy.size)
            transfer.isExactPath = true
            items.append(transfer)
        }
        pump()
    }

    func install(_ apks: [URL], serial: String) {
        startedTick += 1
        for apk in apks {
            items.append(Transfer(serial: serial, direction: .install, name: apk.lastPathComponent,
                                  source: apk.path, destination: "", isDirectory: false))
        }
        pump()
    }

    func cancel(_ transfer: Transfer) {
        switch transfer.state {
        case .queued:
            transfer.state = .cancelled
            reservedPaths.remove(transfer.destination)
        case .running:
            transfer.state = .cancelled
            transfer.runner?.cancel()
            transfer.cancelToken?.cancel()
        default: break
        }
        pump()
    }

    func cancelAll() {
        for transfer in items where transfer.state.isActive { cancel(transfer) }
    }

    func activeCount(for serial: String) -> Int {
        items.filter { $0.serial == serial && $0.state.isActive }.count
    }

    /// Unmounting a phone: stop everything copying to or from it. Each copy removes its own half-finished
    /// file as it stops.
    func cancelAll(for serial: String) {
        for transfer in items where transfer.serial == serial && transfer.state.isActive { cancel(transfer) }
    }

    /// Quitting: the copies won't get to tidy up after themselves, so remove half-finished downloads here.
    func cancelAllBeforeQuit() {
        let downloads = items.filter { $0.state == .running && $0.direction == .pull && !$0.isExternal }
        cancelAll()
        for transfer in downloads { try? FileManager.default.removeItem(atPath: transfer.partialPath) }
    }

    func retry(_ transfer: Transfer) {
        guard !transfer.state.isActive else { return }
        if transfer.direction == .pull && !transfer.isExactPath { reservedPaths.insert(transfer.destination) }
        transfer.state = .queued
        transfer.progress = 0
        transfer.detail = ""
        pump()
    }

    func clearFinished() {
        items.removeAll { !$0.state.isActive }
    }

    /// "Photo.jpg", or "Photo 2.jpg", "Photo 3.jpg", … if that's already on the Mac or about to be.
    nonisolated static func uniqueDestination(in dir: URL, name: String, reserved: Set<String>) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func pump() {
        while items.filter({ $0.state == .running }).count < maxConcurrent,
              let next = items.first(where: { $0.state == .queued }) {
            start(next)
        }
        let active = activeCount
        NSApp?.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        // Don't let the Mac fall asleep halfway through a big copy.
        if active > 0 && sleepAssertion == nil {
            Notifier.requestPermission()
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transferring files with an Android phone")
        } else if active == 0, let assertion = sleepAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            sleepAssertion = nil
        }
        if active == 0 && batchDone + batchFailed > 0 {
            Notifier.transfersFinished(done: batchDone, failed: batchFailed)
            batchDone = 0
            batchFailed = 0
        }
    }

    private func start(_ transfer: Transfer) {
        Log.info("Started \(transfer.logLabel)", .transfer)
        if Phones.isMTP(transfer.serial) {
            startMTP(transfer)
            return
        }
        guard let adb = ADB.path else {
            transfer.state = .failed("adb not found")
            return
        }
        transfer.state = .running
        transfer.startedAt = Date()
        switch transfer.direction {
        case .push where transfer.destinationIsFolder:
            // adb treats a missing destination folder as a new *file* name, so make sure the folder exists.
            Task {
                _ = try? await ADB.shell(transfer.serial, "mkdir -p -- \(ADB.quote(transfer.destination))")
                guard transfer.state == .running else { return }  // cancelled meanwhile
                launch(transfer, adb: adb, args: ["-s", transfer.serial, "push", transfer.source, transfer.destination + "/"])
            }
        case .push:
            launch(transfer, adb: adb, args: ["-s", transfer.serial, "push", transfer.source, transfer.destination])
        case .pull:
            try? FileManager.default.removeItem(atPath: transfer.partialPath)
            launch(transfer, adb: adb, args: ["-s", transfer.serial, "pull", "-a", transfer.source, transfer.partialPath])
        case .install:
            launch(transfer, adb: adb, args: ["-s", transfer.serial, "install", "-r", transfer.source])
        }
    }

    /// File-transfer (MTP) phones: copy in-process over USB instead of through adb.
    private func startMTP(_ transfer: Transfer) {
        transfer.state = .running
        transfer.startedAt = Date()
        guard let fs = Phones.mtp(transfer.serial) else {
            finish(transfer, code: 1, output: "", failure: "The phone is no longer connected.")
            return
        }
        guard transfer.direction != .install else {
            finish(transfer, code: 1, output: "", failure: "Installing apps needs USB debugging.")
            return
        }
        let token = CancelToken()
        transfer.cancelToken = token
        let job = MTPJob(direction: transfer.direction, source: transfer.source, destination: transfer.destination,
                         partial: transfer.partialPath, exact: transfer.isExactPath, isDirectory: transfer.isDirectory)
        Task {
            let started = Date()
            if transfer.direction == .pull && (transfer.totalBytes == nil || transfer.isDirectory) {
                transfer.totalBytes = (try? await onBackground { try fs.size(of: job.source) }).map { Int64($0) }
            }
            if transfer.direction == .push && transfer.totalBytes == nil {
                // Folder uploads: measure before starting, so progress moves from the first byte.
                let url = URL(fileURLWithPath: job.source)
                transfer.totalBytes = try? await onBackground { LocalFiles.totalSize(of: url) }
            }
            let result = await job.run(fs: fs, cancel: token) { done in
                Task { @MainActor in
                    if let total = transfer.totalBytes, total > 0 {
                        transfer.updateProgress(Double(done) / Double(total))
                    }
                }
            }
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            switch result {
            case .success(let bytes):
                let speed = ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) / elapsed), countStyle: .file)
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                finish(transfer, code: 0, output: "\(size) in \(String(format: "%.1f", elapsed))s · \(speed)/s")
            case .failure(let error):
                finish(transfer, code: 1, output: "", failure: token.isCancelled ? "Cancelled" : error.localizedDescription)
            }
        }
    }

    private func launch(_ transfer: Transfer, adb: String, args: [String]) {
        let runner = PTYProcess(executable: adb, arguments: args)
        transfer.runner = runner
        runner.onOutput = { [weak transfer] chunk in
            guard let percent = TransferOutput.lastPercent(in: chunk) else { return }
            Task { @MainActor in transfer?.updateProgress(Double(percent) / 100) }
        }
        runner.onExit = { [weak self, weak transfer] code, output in
            Task { @MainActor in
                guard let self, let transfer else { return }
                self.finish(transfer, code: code, output: output)
            }
        }
        do {
            try runner.start()
        } catch {
            transfer.runner = nil
            transfer.state = .failed(error.localizedDescription)
            batchFailed += 1
            pump()
        }
    }

    private func finish(_ transfer: Transfer, code: Int32, output: String, failure explicitFailure: String? = nil) {
        transfer.runner = nil
        transfer.cancelToken = nil
        reservedPaths.remove(transfer.destination)
        let fm = FileManager.default
        let partial = transfer.partialPath
        let isMTP = Phones.isMTP(transfer.serial)
        var succeeded = code == 0 && (transfer.direction != .install || isMTP || output.contains("Success"))
        var failure = explicitFailure ?? TransferOutput.error(output)

        if succeeded && transfer.direction == .pull && transfer.state != .cancelled {
            // Swap the finished download into place only now, so a failed copy never damages an existing file.
            do {
                var dest = URL(fileURLWithPath: transfer.destination)
                if !transfer.isExactPath && fm.fileExists(atPath: dest.path) {
                    // Plain downloads never overwrite: something took the name while this one was copying
                    // (e.g. a retry). Only sync, which names exact paths, updates files in place.
                    dest = Self.uniqueDestination(in: dest.deletingLastPathComponent(), name: dest.lastPathComponent,
                                                  reserved: reservedPaths)
                    transfer.moveDestination(to: dest.path)
                }
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: URL(fileURLWithPath: partial))
                } else {
                    try fm.moveItem(atPath: partial, toPath: dest.path)
                }
                Quarantine.mark(dest)
            } catch {
                succeeded = false
                failure = "Couldn't save the file: \(error.localizedDescription)"
            }
        }
        if transfer.direction == .pull { try? fm.removeItem(atPath: partial) }

        if transfer.state == .cancelled {
            // Already marked by cancel().
        } else if succeeded {
            transfer.state = .done
            transfer.progress = 1
            transfer.detail = transfer.direction == .install ? "Installed" : isMTP ? output : TransferOutput.summary(output)
            batchDone += 1
            Log.info("Finished \(transfer.logLabel): \(transfer.detail)", .transfer)
        } else {
            transfer.state = .failed(failure)
            batchFailed += 1
            Log.error("Failed \(transfer.logLabel): \(failure)", .transfer)
        }
        if transfer.state == .cancelled { Log.info("Cancelled \(transfer.logLabel)", .transfer) }
        record(transfer)
        lastCompleted = transfer
        completionTick += 1
        pump()
    }
}

/// The values an MTP copy needs, so the USB work can run off the main thread.
private struct MTPJob: Sendable {
    let direction: TransferDirection
    let source: String
    let destination: String
    let partial: String
    let exact: Bool
    let isDirectory: Bool

    /// Returns the number of bytes copied.
    func run(fs: MTPFileSystem, cancel: CancelToken, progress: @escaping @Sendable (UInt64) -> Void) async -> Result<UInt64, Error> {
        do {
            return .success(try await onBackground {
                switch direction {
                case .pull:
                    var copied: UInt64 = 0
                    try fs.download(source, to: URL(fileURLWithPath: partial), cancel: cancel) { copied = $0; progress($0) }
                    return copied
                case .push:
                    let url = URL(fileURLWithPath: source)
                    if exact {
                        try fs.upload(url, toExactPath: destination, cancel: cancel, progress: progress)
                    } else {
                        try fs.upload(url, into: destination, cancel: cancel, progress: progress)
                    }
                    return UInt64(isDirectory ? LocalFiles.totalSize(of: url) : LocalFiles.size(of: url))
                case .install:
                    return 0
                }
            })
        } catch {
            return .failure(error)
        }
    }
}

/// A finished transfer as remembered in the history list.
struct TransferRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case upload, download, install }
    let id: UUID
    let name: String
    let kind: Kind
    let date: Date
    let succeeded: Bool
    let detail: String
    /// Mac path for downloads (for "Show in Finder"), phone folder for uploads.
    let destination: String

    @MainActor
    init(_ t: Transfer) {
        id = t.id
        name = t.name
        kind = t.direction == .push ? .upload : t.direction == .pull ? .download : .install
        date = Date()
        switch t.state {
        case .done: succeeded = true; detail = t.detail
        case .failed(let message): succeeded = false; detail = message
        default: succeeded = false; detail = "Cancelled"
        }
        destination = t.destination
    }

    private static let key = "transferHistory"

    static func load() -> [TransferRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TransferRecord].self, from: data)) ?? []
    }

    static func save(_ records: [TransferRecord]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: key)
    }
}

private extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}

struct SyncCopy {
    let name: String
    let source: String
    let destination: String
    let size: Int64
}

enum LocalFiles {
    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func totalSize(of folder: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        while let url = enumerator?.nextObject() as? URL { total += size(of: url) }
        return total
    }

    /// Regular, non-hidden files under `root`, keyed by relative path.
    static func filesRecursive(in root: URL) -> [String: Int64] {
        var result: [String: Int64] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let base = root.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            result[String(path.dropFirst(base.count))] = Int64(values.fileSize ?? 0)
        }
        return result
    }
}

enum Notifier {
    static let enabledKey = "notifyWhenDone"
    @MainActor private static var requested = false

    private static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    @MainActor static func requestPermission() {
        guard canNotify, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Only notifies when Cablehop is in the background; the transfer list covers the foreground.
    @MainActor
    static func transfersFinished(done: Int, failed: Int) {
        guard canNotify, NSApp?.isActive == false else { return }
        let content = UNMutableNotificationContent()
        content.title = failed == 0 ? "Transfers complete" : "Transfers finished with errors"
        content.body = failed == 0
            ? "\(done) item\(done == 1 ? "" : "s") copied."
            : "\(done) copied, \(failed) failed."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Parsing for `adb push/pull` terminal output.
enum TransferOutput {
    private static let percentRegex = try! NSRegularExpression(pattern: #"\[\s*(\d{1,3})%\]"#)

    static func lastPercent(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = percentRegex.matches(in: text, range: range).last,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    private static func lines(_ output: String) -> [String] {
        output.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
    }

    /// e.g. "1 file pulled, 0 skipped. 38.1 MB/s (12345678 bytes in 0.309s)"
    static func summary(_ output: String) -> String {
        guard let last = lines(output).last else { return "" }
        if let colon = last.range(of: ": ", options: .backwards), last[colon.upperBound...].first?.isNumber == true {
            return String(last[colon.upperBound...])
        }
        return last
    }

    static func error(_ output: String) -> String {
        let all = lines(output)
        let message = all.last { $0.localizedCaseInsensitiveContains("error") || $0.contains("Failure") }
            ?? all.last ?? "Transfer failed"
        return message.replacingOccurrences(of: "adb: error: ", with: "")
    }
}
