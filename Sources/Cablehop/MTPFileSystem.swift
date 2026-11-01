import Foundation

/// Phones currently connected in "File transfer" (MTP) mode, keyed by Cablehop device serial ("mtp:…").
enum Phones {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: MTPFileSystem] = [:]  // guarded by `lock`

    static func mtp(_ serial: String) -> MTPFileSystem? { lock.withLock { sessions[serial] } }
    static func isMTP(_ serial: String) -> Bool { serial.hasPrefix("mtp:") }
    static var serials: [String] { lock.withLock { Array(sessions.keys) } }

    static func register(_ serial: String, _ fs: MTPFileSystem) { lock.withLock { sessions[serial] = fs } }

    static func close(_ serial: String) {
        guard let fs = lock.withLock({ sessions.removeValue(forKey: serial) }) else { return }
        DispatchQueue.global().async { fs.isBroken ? fs.conn.abandon() : fs.conn.close() }
    }

    /// Ends the session properly and returns only once the phone has been told, so it's safe to unplug.
    /// Anything still talking to the phone finishes first.
    static func closeAndWait(_ serial: String) async {
        guard let fs = lock.withLock({ sessions.removeValue(forKey: serial) }) else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                fs.isBroken ? fs.conn.abandon() : fs.conn.close()
                done.resume()
            }
        }
    }
}

/// Runs blocking USB work off the main thread.
func onBackground<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try work() }) }
    }
}

/// Lets a transfer be cancelled from the main thread while it runs on a background one.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.withLock { flag } }
    func cancel() { lock.withLock { flag = true } }
}

/// Path-based file access on top of MTP's numeric object handles, so the rest of the app can use the
/// same "/sdcard/DCIM/Camera" paths it uses over adb. The first storage is "/sdcard"; any others
/// (SD cards) appear under "/storage/<name>".
final class MTPFileSystem: @unchecked Sendable {
    let conn: MTPConnection
    private let lock = NSLock()
    private var _storages: [MTPStorage] = []
    private var childCache: [String: [MTPObject]] = [:]

    private static let root: UInt32 = 0xFFFFFFFF

    struct Location: Hashable {
        let storage: UInt32
        let handle: UInt32
        var key: String { "\(storage):\(handle)" }
    }

    init(conn: MTPConnection) { self.conn = conn }

    var storages: [MTPStorage] { lock.withLock { _storages } }
    /// Android hides all storage over MTP until the phone is unlocked.
    var isLocked: Bool { storages.isEmpty }
    var displayName: String { conn.model.isEmpty ? "Android phone" : conn.model }

    func loadStorages() throws {
        let s = try conn.storages()
        lock.withLock {
            if s.map(\.id) != _storages.map(\.id) { childCache.removeAll() }
            _storages = s
        }
    }

    func deviceInfo() -> DeviceInfo {
        try? loadStorages()
        var info = DeviceInfo()
        info.manufacturer = conn.manufacturer
        info.model = conn.model
        info.battery = conn.batteryLevel()
        if let primary = storages.first {
            info.storageTotal = Int64(primary.capacity)
            info.storageFree = Int64(primary.free)
        }
        return info
    }

    // MARK: Paths

    private func rootPath(index: Int, storage: MTPStorage) -> String {
        index == 0 ? "/sdcard" : "/storage/" + storage.description.replacingOccurrences(of: "/", with: "-")
    }

    /// Walks a path down from its storage root. Returns nil for "/" (the list of storages).
    func resolve(_ path: String) throws -> Location? {
        if path == "/" { return nil }
        let all = storages
        guard !all.isEmpty else { throw MTPError.locked }
        var location: Location
        var rest: [Substring]
        if path == "/sdcard" || path.hasPrefix("/sdcard/") {
            location = Location(storage: all[0].id, handle: Self.root)
            rest = path.dropFirst("/sdcard".count).split(separator: "/")
        } else if path.hasPrefix("/storage/") {
            let parts = path.split(separator: "/")
            guard parts.count >= 2,
                  let index = all.indices.first(where: { rootPath(index: $0, storage: all[$0]) == "/storage/\(parts[1])" })
            else { throw MTPError.response(0x2009) }
            location = Location(storage: all[index].id, handle: Self.root)
            rest = Array(parts.dropFirst(2))
        } else {
            throw MTPError.response(0x2009)
        }
        for name in rest {
            let kids = try children(of: location)
            guard let match = kids.first(where: { $0.name == name }) ?? kids.first(where: { $0.name.lowercased() == name.lowercased() }),
                  match.isFolder else { throw MTPError.response(0x2009) }
            location = Location(storage: location.storage, handle: match.handle)
        }
        return location
    }

    /// The object at `path` (a file or folder, not a storage root).
    func object(at path: String) throws -> (object: MTPObject, parent: Location) {
        guard let parent = try resolve(RemotePath.parent(path)) else { throw MTPError.response(0x2009) }
        let name = (path as NSString).lastPathComponent
        let kids = try children(of: parent)
        guard let match = kids.first(where: { $0.name == name }) ?? kids.first(where: { $0.name.lowercased() == name.lowercased() })
        else { throw MTPError.response(0x2009) }
        return (match, parent)
    }

    func children(of location: Location, refresh: Bool = false) throws -> [MTPObject] {
        if !refresh, let cached = lock.withLock({ childCache[location.key] }) { return cached }
        // Names that can't be represented as a path component are skipped rather than mis-addressed.
        let kids = try conn.children(storage: location.storage, parent: location.handle)
            .filter { !$0.name.isEmpty && !$0.name.contains("/") && $0.name != "." && $0.name != ".." }
        lock.withLock { childCache[location.key] = kids }
        return kids
    }

    private func invalidate(_ location: Location) {
        lock.withLock { _ = childCache.removeValue(forKey: location.key) }
    }

    // MARK: Public operations (retry once after resetting a failed USB link)

    func list(_ path: String) throws -> [RemoteFile] { try withRecovery { try listImpl(path) } }
    func makeFolder(in dir: String, named name: String) throws { try withRecovery { try makeFolderImpl(in: dir, named: name) } }
    func rename(_ path: String, to name: String) throws { try withRecovery { try renameImpl(path, to: name) } }
    func delete(_ paths: [String]) throws { try withRecovery { try deleteImpl(paths) } }
    func size(of path: String) throws -> UInt64 { try withRecovery { try sizeImpl(of: path) } }
    func thumbnail(_ path: String) throws -> Data { try withRecovery { try thumbnailImpl(path) } }
    func readAll(_ path: String) throws -> Data { try withRecovery { try readAllImpl(path) } }

    func download(_ path: String, to url: URL, cancel: CancelToken, progress: @escaping (UInt64) -> Void) throws {
        try withRecovery { try downloadImpl(path, to: url, cancel: cancel, progress: progress) }
    }

    func upload(_ url: URL, into dir: String, cancel: CancelToken, progress: @escaping (UInt64) -> Void) throws {
        try withRecovery { try uploadImpl(url, into: dir, cancel: cancel, progress: progress) }
    }

    func upload(_ url: URL, toExactPath path: String, cancel: CancelToken, progress: @escaping (UInt64) -> Void) throws {
        try withRecovery { try uploadImpl(url, toExactPath: path, cancel: cancel, progress: progress) }
    }

    /// Set when the link couldn't be recovered in place; the device manager then resets the phone's USB.
    var isBroken: Bool { lock.withLock { broken } }
    private var broken = false

    private func withRecovery<T>(_ operation: () throws -> T) throws -> T {
        guard !isBroken else { throw MTPError.unresponsive }
        do {
            return try operation()
        } catch let error as MTPError where error.isLinkFailure {
            Log.warning("USB link failure (\(error.localizedDescription)); recovering", .mtp)
            do {
                try conn.recover()
            } catch {
                Log.error("Couldn't recover the USB link; the phone will be reset", .mtp)
                lock.withLock { broken = true }
                throw MTPError.unresponsive
            }
            lock.withLock { childCache.removeAll() }
            return try operation()
        }
    }

    // MARK: Browsing

    private func listImpl(_ path: String) throws -> [RemoteFile] {
        guard let location = try resolve(path) else {
            return storages.enumerated().map { index, storage in
                RemoteFile(path: rootPath(index: index, storage: storage), name: storage.description,
                           isDirectory: true, size: 0, modified: .distantPast)
            }
        }
        return try children(of: location, refresh: true).map {
            RemoteFile(path: RemotePath.join(path, $0.name), name: $0.name, isDirectory: $0.isFolder,
                       size: Int64(clamping: $0.size), modified: $0.modified)
        }
    }

    // MARK: Changes

    private func makeFolderImpl(in dir: String, named name: String) throws {
        guard name.utf16.count <= 254 else { throw ADBError.failed("That name is too long for the phone.") }
        guard let location = try resolve(dir) else { throw MTPError.response(0x200F) }
        if try children(of: location, refresh: true).contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw ADBError.failed("“\(name)” already exists here.")
        }
        _ = try conn.sendObjectInfo(storage: location.storage, parent: location.handle, name: name, isFolder: true, size: 0)
        invalidate(location)
    }

    private func renameImpl(_ path: String, to name: String) throws {
        guard name.utf16.count <= 254 else { throw ADBError.failed("That name is too long for the phone.") }
        let (object, parent) = try object(at: path)
        let caseOnly = name.lowercased() == object.name.lowercased()
        if !caseOnly, try children(of: parent, refresh: true).contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw ADBError.failed("“\(name)” already exists. Choose a different name.")
        }
        try conn.rename(object.handle, to: name)
        invalidate(parent)
    }

    private func deleteImpl(_ paths: [String]) throws {
        for path in paths {
            let (object, parent) = try object(at: path)
            try conn.delete(object.handle)  // Android removes folders with everything inside
            invalidate(parent)
        }
    }

    // MARK: Transfers

    /// Total bytes under a remote file or folder.
    private func sizeImpl(of path: String) throws -> UInt64 {
        let (object, _) = try object(at: path)
        return try size(of: object)
    }

    private func size(of object: MTPObject) throws -> UInt64 {
        guard object.isFolder else { return object.size }
        return try children(of: Location(storage: object.storage, handle: object.handle))
            .reduce(0) { $0 + (try size(of: $1)) }
    }

    /// Copies a remote file or folder to `url` on the Mac.
    private func downloadImpl(_ path: String, to url: URL, cancel: CancelToken, progress: @escaping (UInt64) -> Void) throws {
        let (object, _) = try object(at: path)
        var done: UInt64 = 0
        try download(object, to: url, cancel: cancel) { delta in done += delta; progress(done) }
    }

    private func download(_ object: MTPObject, to url: URL, cancel: CancelToken, advance: (UInt64) -> Void) throws {
        if cancel.isCancelled { throw MTPError.cancelled }
        if object.isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for child in try children(of: Location(storage: object.storage, handle: object.handle), refresh: true) {
                try download(child, to: url.appendingPathComponent(RemotePath.safeLocalName(child.name)), cancel: cancel, advance: advance)
            }
            return
        }
        var reported: UInt64 = 0
        try conn.downloadInPieces(object.handle, size: object.size, to: url, isCancelled: { cancel.isCancelled }) { total in
            if total > reported { advance(total - reported); reported = total }
        }
        if object.modified != .distantPast {
            try? FileManager.default.setAttributes([.modificationDate: object.modified], ofItemAtPath: url.path)
        }
    }

    /// Copies a Mac file or folder into the phone folder `dir`, replacing a same-named file and
    /// merging into a same-named folder.
    private func uploadImpl(_ url: URL, into dir: String, cancel: CancelToken, progress: @escaping (UInt64) -> Void) throws {
        guard let location = try resolve(dir) else { throw MTPError.response(0x200F) }
        var done: UInt64 = 0
        try upload(url, into: location, name: url.lastPathComponent, cancel: cancel) { delta in done += delta; progress(done) }
    }

    /// Copies a Mac file to an exact phone path, creating missing folders (used by folder sync).
    private func uploadImpl(_ url: URL, toExactPath path: String, cancel: CancelToken, progress: @escaping (UInt64) -> Void) throws {
        let location = try makeFolders(RemotePath.parent(path))
        var done: UInt64 = 0
        try upload(url, into: location, name: (path as NSString).lastPathComponent, cancel: cancel) { delta in done += delta; progress(done) }
    }

    private func upload(_ url: URL, into location: Location, name: String, cancel: CancelToken, advance: (UInt64) -> Void) throws {
        if cancel.isCancelled { throw MTPError.cancelled }
        // MTP names are capped at 254 UTF-16 characters; refuse rather than silently cut the name short.
        guard name.utf16.count <= 254 else { throw ADBError.failed("“\(name.prefix(40))…” has a name too long for the phone.") }
        let existing = try children(of: location, refresh: true).first { $0.name.lowercased() == name.lowercased() }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let folder: UInt32
            if let existing, existing.isFolder {
                folder = existing.handle
            } else {
                if let existing { try conn.delete(existing.handle) }
                folder = try conn.sendObjectInfo(storage: location.storage, parent: location.handle, name: name, isFolder: true, size: 0)
                invalidate(location)
            }
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles])
            for child in contents {
                try upload(child, into: Location(storage: location.storage, handle: folder), name: child.lastPathComponent,
                           cancel: cancel, advance: advance)
            }
            return
        }
        if let existing { try conn.delete(existing.handle) }  // MTP can't overwrite in place
        var reported: UInt64 = 0
        let watcher = CancelWatcher(token: cancel, conn: conn)
        defer { watcher.stop() }
        _ = try conn.upload(from: url, storage: location.storage, parent: location.handle, name: name) { sent in
            if sent > reported { advance(sent - reported); reported = sent }
        }
        invalidate(location)
    }

    private func makeFolders(_ path: String) throws -> Location {
        if let found = (try? resolve(path)) ?? nil { return found }
        let parent = try makeFolders(RemotePath.parent(path))
        let name = (path as NSString).lastPathComponent
        if let existing = try children(of: parent, refresh: true).first(where: { $0.name.lowercased() == name.lowercased() && $0.isFolder }) {
            return Location(storage: parent.storage, handle: existing.handle)
        }
        let handle = try conn.sendObjectInfo(storage: parent.storage, parent: parent.handle, name: name, isFolder: true, size: 0)
        invalidate(parent)
        return Location(storage: parent.storage, handle: handle)
    }

    private func thumbnailImpl(_ path: String) throws -> Data {
        try conn.thumbnail(try object(at: path).object.handle)
    }

    private func readAllImpl(_ path: String) throws -> Data {
        try conn.readAll(try object(at: path).object.handle)
    }

    /// Copies a file into a fresh temporary folder (for opening, Quick Look, and dragging out).
    func pullToTemp(_ path: String, name: String) throws -> URL {
        let base = Caches.temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dest = base.appendingPathComponent(name)
        do {
            try download(path, to: dest, cancel: CancelToken(), progress: { _ in })
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        Quarantine.mark(dest)
        return dest
    }
}

/// While an upload (which holds the USB connection for the whole file) runs, forwards a cancel
/// request from the transfer list to the connection.
private final class CancelWatcher: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(token: CancelToken, conn: MTPConnection) {
        timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler {
            if token.isCancelled { conn.requestCancel() }  // keep re-sending until the upload stops
        }
        timer.resume()
    }

    func stop() { timer.cancel() }
}

/// One entry point for things that work the same over adb and file-transfer mode.
enum PhoneFiles {
    /// Copies a phone file into a temporary folder on the Mac (for opening, Quick Look and drag-out).
    static func pullToTemp(serial: String, file: RemoteFile) async throws -> URL {
        let name = RemotePath.safeLocalName(file.name)
        if let fs = Phones.mtp(serial) {
            let path = file.path
            return try await onBackground { try fs.pullToTemp(path, name: name) }
        }
        return try await ADB.pullToTemp(serial: serial, remotePath: file.path, name: name)
    }
}

extension PhoneFiles {
    /// Copies a phone file or folder to an exact Mac location (used when dragging into Finder).
    static func download(serial: String, file: RemoteFile, to url: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        if let fs = Phones.mtp(serial) {
            let path = file.path
            try await onBackground {
                let total = max(1, (try? fs.size(of: path)) ?? UInt64(max(file.size, 1)))
                try fs.download(path, to: url, cancel: CancelToken()) { done in progress(Double(done) / Double(total)) }
            }
            return
        }
        let r = try await ADB.run(["-s", serial, "pull", "-a", file.path, url.path], timeout: nil)
        guard r.code == 0 else { throw ADBError.failed(TransferOutput.error(r.combined)) }
        progress(1)
    }
}
