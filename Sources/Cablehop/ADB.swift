import Foundation
import Security

enum ADBError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "adb was not found. Install it with: brew install android-platform-tools"
        case .failed(let message): return message
        }
    }
}

struct ADBResult {
    let out: String
    let err: String
    let code: Int32

    var combined: String { (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Thin async wrapper around the `adb` command-line tool.
enum ADB {
    static let path: String? = {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = ProcessInfo.processInfo.environment[key] {
                candidates.insert(sdk + "/platform-tools/adb", at: 0)
            }
        }
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil)?.path {
            candidates.append(bundled)
        }
        let installed = candidates.filter { fm.isExecutableFile(atPath: $0) }
        // Prefer Google's own signed adb, so a copy planted earlier in the search order can't be picked
        // over the real one. An unsigned build (e.g. compiled from source) still works, with a log note.
        if let genuine = installed.first(where: isSignedByGoogle) { return genuine }
        if let other = installed.first {
            Log.warning("Using an adb that isn't signed by Google: \(other)", .adb)
            return other
        }
        return nil
    }()

    /// Google signs its platform tools with its Apple Developer ID (team EQHXZ8M8AV).
    static func isSignedByGoogle(_ path: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path).resolvingSymlinksInPath() as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(#"anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV""# as CFString,
                                             [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Runs adb and collects its output. The process is killed if it outlives `timeout`
    /// (nil = no limit) or if the calling task is cancelled.
    static func run(_ args: [String], timeout: TimeInterval? = 30) async throws -> ADBResult {
        let r: (out: Data, err: Data, code: Int32)
        do {
            r = try await runRaw(args, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.warning("adb \(describe(args)): \(error.localizedDescription)", .adb)
            throw error
        }
        let result = ADBResult(out: String(decoding: r.out, as: UTF8.self),
                               err: String(decoding: r.err, as: UTF8.self),
                               code: r.code)
        if r.code != 0 {
            Log.debug("adb \(describe(args)) exited \(r.code): \(result.combined.prefix(300))", .adb)
        }
        return result
    }

    /// A short, log-friendly version of an adb command line (serial numbers shortened).
    static func describe(_ args: [String]) -> String {
        var parts = args
        if let i = parts.firstIndex(of: "-s"), i + 1 < parts.count { parts[i + 1] = "…" + parts[i + 1].suffix(4) }
        if let i = parts.firstIndex(of: "pair"), i + 2 < parts.count { parts[i + 2] = "••••••" }  // pairing code
        return String(parts.joined(separator: " ").prefix(200))
    }

    /// Like `run`, but returns stdout as raw bytes (for `exec-out` binary data).
    static func runData(_ args: [String], timeout: TimeInterval? = 60) async throws -> Data {
        let r = try await runRaw(args, timeout: timeout)
        guard r.code == 0 else { throw ADBError.failed(String(decoding: r.err, as: UTF8.self)) }
        return r.out
    }

    private static func runRaw(_ args: [String], timeout: TimeInterval?) async throws -> (out: Data, err: Data, code: Int32) {
        guard let path else { throw ADBError.notFound }
        let job = ProcessJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = job.process
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = args
                    let outPipe = Pipe(), errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    process.standardInput = FileHandle.nullDevice
                    do { try job.launch() } catch { cont.resume(throwing: error); return }
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { job.kill(reason: .timedOut) }
                    }

                    // Read stderr on another thread so a full pipe can never deadlock the process.
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    let errData = errBox.data
                    process.waitUntilExit()

                    switch job.killReason {
                    case .cancelled: cont.resume(throwing: CancellationError())
                    case .timedOut: cont.resume(throwing: ADBError.failed("The phone didn't respond in time. Check that it's still connected."))
                    case nil: cont.resume(returning: (outData, errData, process.terminationStatus))
                    }
                }
            }
        } onCancel: {
            job.kill(reason: .cancelled)
        }
    }

    /// Single-quotes a string for the device's /system/bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func shell(_ serial: String, _ command: String) async throws -> String {
        let r = try await run(["-s", serial, "shell", command])
        guard r.code == 0 else {
            throw ADBError.failed(r.combined.isEmpty ? "Command failed on the device." : r.combined)
        }
        return r.out
    }

    // MARK: Files

    static func listDirectory(serial: String, path: String) async throws -> [RemoteFile] {
        let q = quote(path == "/" ? "/" : path + "/")
        let command = """
        if [ ! -d \(q) ]; then echo __NOTDIR__; elif [ ! -r \(q) ]; then echo __NOPERM__; \
        else find \(q) -mindepth 1 -maxdepth 1 -exec stat -L -c '%F|%s|%Y|%n' {} + 2>/dev/null; fi
        """
        let r = try await run(["-s", serial, "shell", command])
        if r.out.hasPrefix("__NOTDIR__") { throw ADBError.failed("This folder doesn't exist on the phone.") }
        if r.out.hasPrefix("__NOPERM__") { throw ADBError.failed("Android doesn't allow access to this folder.") }
        if r.out.isEmpty && r.code != 0 && !r.err.isEmpty { throw ADBError.failed(r.combined) }
        return parseStatLines(r.out)
    }

    /// Finds files and folders under `root` whose names contain `query`.
    static func search(serial: String, root: String, query: String, limit: Int = 500) async throws -> [RemoteFile] {
        let command = "find \(quote(root + "/")) -iname \(quote("*" + query + "*")) -not -path '*/Android/data/*' "
            + "-not -path '*/Android/obb/*' -exec stat -L -c '%F|%s|%Y|%n' {} + 2>/dev/null | head -n \(limit)"
        let r = try await run(["-s", serial, "shell", command], timeout: 120)
        return parseStatLines(r.out)
    }

    /// Every regular file under `root`, with paths relative to it. Used by folder sync.
    static func listFilesRecursive(serial: String, root: String) async throws -> [String: Int64] {
        let r = try await run(["-s", serial, "shell",
                               "find \(quote(root + "/")) -type f -exec stat -c '%s|%n' {} + 2>/dev/null"],
                              timeout: 600)
        var result: [String: Int64] = [:]
        let prefix = RemotePath.normalize(root + "/")
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            let full = RemotePath.normalize(String(parts[1]))
            guard full.hasPrefix(prefix), RemotePath.isSafe(full) else { continue }
            result[String(full.dropFirst(prefix.count))] = size
        }
        return result
    }

    /// Parses `stat -c '%F|%s|%Y|%n'` output. Lines that don't look exactly right are dropped, so a
    /// filename containing a newline can't smuggle in a fake entry (e.g. one pointing at "../..").
    private static func parseStatLines(_ out: String) -> [RemoteFile] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let size = Int64(parts[1]), let mtime = TimeInterval(parts[2]) else { return nil }
            let fullPath = RemotePath.normalize(String(parts[3]))
            guard RemotePath.isSafe(fullPath), let name = fullPath.split(separator: "/").last.map(String.init) else { return nil }
            return RemoteFile(
                path: fullPath,
                name: name,
                isDirectory: parts[0] == "directory",
                size: size,
                modified: Date(timeIntervalSince1970: mtime))
        }
    }

    /// The first `count` bytes of a remote file, without copying the whole thing.
    static func readPrefix(serial: String, path: String, count: Int) async throws -> Data {
        try await runData(["-s", serial, "exec-out", "head -c \(count) \(quote(path))"])
    }

    static func readFile(serial: String, path: String) async throws -> Data {
        try await runData(["-s", serial, "exec-out", "cat \(quote(path))"], timeout: 120)
    }

    static func screenshot(serial: String) async throws -> Data {
        let data = try await runData(["-s", serial, "exec-out", "screencap -p"])
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw ADBError.failed("The phone didn't return a screenshot.") }
        return data
    }

    static func remoteSize(serial: String, path: String) async -> Int64? {
        guard let out = try? await shell(serial, "du -sk \(quote(path)) 2>/dev/null"),
              let kb = out.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    /// Pulls a remote file or folder into a fresh temporary folder and returns its local URL.
    static func pullToTemp(serial: String, remotePath: String, name: String) async throws -> URL {
        let base = Caches.temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dest = base.appendingPathComponent(name)
        let r = try await run(["-s", serial, "pull", "-a", remotePath, dest.path], timeout: nil)
        guard r.code == 0 else {
            try? FileManager.default.removeItem(at: base)
            throw ADBError.failed(r.combined)
        }
        Quarantine.mark(dest)
        return dest
    }

    // MARK: Device info

    static func deviceInfo(serial: String) async throws -> DeviceInfo {
        let command = #"""
        echo "MF=$(getprop ro.product.manufacturer)"; \
        echo "MD=$(getprop ro.product.model)"; \
        echo "AV=$(getprop ro.build.version.release)"; \
        echo "SDK=$(getprop ro.build.version.sdk)"; \
        echo "BL=$(dumpsys battery 2>/dev/null | grep -m1 ' level:' | tr -dc 0-9)"; \
        echo "IP=$(ip -f inet addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | head -n1 | cut -d' ' -f2)"; \
        echo "DF=$(df -k /sdcard 2>/dev/null | tail -n 1)"
        """#
        let out = try await shell(serial, command)
        var info = DeviceInfo()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "MF": info.manufacturer = value
            case "MD": info.model = value
            case "AV": info.androidVersion = value
            case "SDK": info.sdk = Int(value) ?? 0
            case "BL": info.battery = Int(value)
            case "IP": info.wifiIP = value.isEmpty ? nil : value
            case "DF":
                let cols = value.split(whereSeparator: \.isWhitespace)
                if cols.count >= 4, let total = Int64(cols[1]), let free = Int64(cols[3]) {
                    info.storageTotal = total * 1024
                    info.storageFree = free * 1024
                }
            default: break
            }
        }
        return info
    }

    // MARK: Wireless

    static func mdnsServices() async -> [MDNSService] {
        guard let r = try? await run(["mdns", "services"]) else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 3, cols[1].contains("_adb") else { return nil }
            return MDNSService(name: String(cols[0]), type: String(cols[1]), address: String(cols[2]))
        }
    }
}

/// Hands data back from a reader thread (ordered by a DispatchGroup wait).
private final class DataBox: @unchecked Sendable { var data = Data() }

/// A Process plus thread-safe bookkeeping for killing it from another thread.
private final class ProcessJob: @unchecked Sendable {
    enum KillReason { case cancelled, timedOut }

    let process = Process()
    private let lock = NSLock()
    private var launched = false
    private var reason: KillReason?

    var killReason: KillReason? { lock.withLock { reason } }

    func launch() throws {
        try lock.withLock {
            if reason != nil { throw CancellationError() }  // cancelled before it started
            try process.run()
            launched = true
        }
    }

    func kill(reason newReason: KillReason) {
        lock.withLock {
            guard reason == nil else { return }
            if launched && !process.isRunning { return }  // already finished normally
            reason = newReason
            if launched { process.terminate() }
        }
    }
}

/// Marks files that came from the phone as downloaded, so Gatekeeper checks any apps or
/// scripts before they can run, just like files from Safari or AirDrop.
enum Quarantine {
    static func mark(_ url: URL) {
        let properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Cablehop",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        func apply(_ target: URL) {
            var target = target
            var values = URLResourceValues()
            values.quarantineProperties = properties
            try? target.setResourceValues(values)
        }
        apply(url)
        if let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            while let child = children.nextObject() as? URL { apply(child) }
        }
    }
}

/// Runs a process attached to a pseudo-terminal so `adb push/pull` print their live progress.
/// Callbacks are set once before `start()`, then only read from the reader thread.
final class PTYProcess: @unchecked Sendable {
    private let process = Process()
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // adb only prints its live "[ 42%]" progress for a real terminal type. Apps opened from Finder
        // have no TERM set, so without this every adb transfer would sit at 0% until it finished.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
    }

    func start() throws {
        var masterFD: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 300, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slave, nil, nil, &size) == 0 else {
            throw ADBError.failed("Couldn't open a terminal for the transfer.")
        }
        // Keep this transfer's terminal from leaking into other transfers' adb processes.
        let master = masterFD
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(master); close(slave)
            throw error
        }
        close(slave)

        let process = self.process
        Thread { [weak self] in
            var all = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            var waiting = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            while true {
                let ready = poll(&waiting, 1, 500)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 { break }
                if ready == 0 {
                    // Nothing new. Once adb has exited, stop waiting: if this transfer started adb's background
                    // server, that server keeps the terminal open and the read would never end.
                    if !process.isRunning { break }
                    continue
                }
                let n = read(master, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }  // EIO once adb exits and the terminal closes
                let chunk = Data(buffer[0..<n])
                all.append(chunk)
                self?.onOutput?(String(decoding: chunk, as: UTF8.self))
            }
            close(master)
            process.waitUntilExit()
            self?.onExit?(process.terminationStatus, String(decoding: all, as: UTF8.self))
        }.start()
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}
