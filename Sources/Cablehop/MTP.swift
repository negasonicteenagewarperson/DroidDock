import Foundation
import IOKit
import IOUSBHost

// A small MTP (Media Transfer Protocol) client over USB, using Apple's IOUSBHost framework.
// This is what Android's "File transfer" USB mode speaks; it needs nothing enabled on the phone.

enum MTPError: LocalizedError {
    case notFound
    case openFailed(String)
    case response(UInt16)
    case protocolError(String)
    case cancelled
    case locked
    /// The phone accepts no commands at all (locked with file transfer paused, or a stuck session).
    case unresponsive

    var errorDescription: String? {
        switch self {
        case .notFound: return "The phone is no longer connected."
        case .openFailed(let why): return "Couldn't open the phone for file transfer. \(why)"
        case .response(let code): return MTPError.describe(code)
        case .protocolError(let why): return "The phone sent an unexpected reply (\(why)). Try unplugging and reconnecting it."
        case .cancelled: return "Cancelled"
        case .locked: return "Unlock your phone to see its files."
        case .unresponsive: return "The phone isn't responding. Unlock it, and make sure “File transfer” is selected in its USB notification."
        }
    }

    /// USB-level failures that a link reset can usually fix (as opposed to the phone saying no).
    var isLinkFailure: Bool {
        switch self {
        case .openFailed, .protocolError: return true
        default: return false
        }
    }

    static func describe(_ code: UInt16) -> String {
        switch code {
        case 0x2002: return "The phone reported a general error."
        case 0x2005: return "The phone doesn't support that action in file-transfer mode."
        case 0x2008, 0x2009: return "That item no longer exists on the phone."
        case 0x200C: return "The phone's storage is full."
        case 0x200D, 0x200E, 0x200F: return "The phone doesn't allow changes to that item."
        case 0x2019: return "The phone is busy. Try again in a moment."
        case 0x201F: return "Cancelled"
        default: return String(format: "The phone refused the request (MTP error 0x%04X).", code)
        }
    }
}

struct MTPStorage: Hashable {
    let id: UInt32
    let description: String
    let capacity: UInt64
    let free: UInt64
}

struct MTPObject {
    let handle: UInt32
    let storage: UInt32
    let parent: UInt32
    let name: String
    let isFolder: Bool
    let size: UInt64
    let modified: Date
}

/// One open MTP session with a phone. All USB I/O is serialized on `queue`.
final class MTPConnection: @unchecked Sendable {
    let usbSerial: String
    let vendorID: Int
    private(set) var manufacturer = ""
    private(set) var model = ""
    private(set) var supportedOps: Set<UInt16> = []

    private let service: io_service_t
    private var interface: IOUSBHostInterface?
    private var bulkIn: IOUSBHostPipe?
    private var bulkOut: IOUSBHostPipe?
    private var maxPacket = 512
    private var transactionID: UInt32 = 0
    let queue = DispatchQueue(label: "Cablehop.mtp")
    private let chunk = 1 << 20  // 1 MB, a multiple of every USB max packet size
    private var ioTimeout: TimeInterval = 30

    /// Set from any thread to abort the transfer in progress at the next chunk boundary.
    private let cancelLock = NSLock()
    private var cancelRequested = false

    /// macOS's ID for this exact USB connection. A phone that's replugged (or reconnects by itself) gets a
    /// new one, even though its serial number is the same.
    let registryID: UInt64

    init(service: io_service_t, usbSerial: String, vendorID: Int) {
        IOObjectRetain(service)
        self.service = service
        self.usbSerial = usbSerial
        self.vendorID = vendorID
        registryID = MTPDiscovery.registryID(of: service)
    }

    deinit {
        interface?.destroy()
        IOObjectRelease(service)
    }

    // MARK: Session

    func open() throws {
        try queue.sync {
            do {
                interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            } catch {
                throw MTPError.openFailed(MTPConnection.ownerHint(error))
            }
            try findEndpoints()
            // A previous session that ended abruptly (unplugged mid-copy, app force-quit) can leave the
            // phone's endpoints stalled, so on failure reset the MTP link once and retry.
            do {
                try handshake(timeout: 10)
            } catch {
                Log.warning("Handshake failed (\(error.localizedDescription)); resetting the link", .mtp)
                resetLink()
                do {
                    try handshake(timeout: 15)
                } catch {
                    throw MTPError.unresponsive
                }
            }
        }
    }

    /// Opens the session, then reads what the phone supports. Same order as the MTP spec and libmtp;
    /// some phones won't answer anything else before a session is open.
    private func handshake(timeout: TimeInterval) throws {
        ioTimeout = timeout
        defer { ioTimeout = 30 }
        transactionID = UInt32.max  // OpenSession must use transaction ID 0
        let r = try transactionLocked(0x1002, [1], expectData: false, check: false)  // OpenSession
        guard r.code == 0x2001 || r.code == 0x201E else { throw MTPError.response(r.code) }
        let info = try transactionLocked(0x1001, [], expectData: true).data  // GetDeviceInfo
        parseDeviceInfo(info)
    }

    /// Clears stalled pipes and sends the USB Still Image class "Device Reset" request.
    private func resetLink() {
        guard let interface else { return }
        try? bulkIn?.__abort(with: .synchronous)
        try? bulkOut?.__abort(with: .synchronous)
        try? bulkIn?.clearStall()
        try? bulkOut?.clearStall()
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x21
        request.bRequest = 0x66
        request.wIndex = UInt16(interface.interfaceDescriptor.pointee.bInterfaceNumber)
        do {
            try interface.__send(request, data: nil, bytesTransferred: nil, completionTimeout: 5)
        } catch {
            MTPConnection.log("device reset request failed: \(MTPConnection.code(error))")
        }
        Thread.sleep(forTimeInterval: 0.3)
        // Throw away anything the phone was still sending for the old session (this can be a
        // whole file if a download was interrupted), until it goes quiet.
        var drained = 0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, let leftover = try? read(chunk, timeout: 0.5), !leftover.isEmpty {
            drained += leftover.count
        }
        MTPConnection.log("link reset, drained \(drained) bytes")
    }

    static func log(_ message: String) {
        Log.info(message, .mtp)
    }

    /// Resets the USB link and reopens the session after a failure, without replugging.
    func recover() throws {
        try queue.sync {
            resetLink()
            do { try handshake(timeout: 10) } catch {
                throw MTPError.unresponsive
            }
        }
    }

    /// Drops the USB connection immediately without talking to the phone (used when it's stuck).
    func abandon() {
        interface?.destroy()
    }

    func close() {
        queue.sync {
            _ = try? transactionLocked(0x1003, [], expectData: false, check: false)  // CloseSession
            interface?.destroy()
            interface = nil
        }
    }

    static func code(_ error: Error) -> String {
        String(format: "0x%08X", UInt32(truncatingIfNeeded: (error as NSError).code))
    }

    private static func ownerHint(_ error: Error) -> String {
        let code = (error as NSError).code
        // kIOReturnExclusiveAccess
        if code == Int(Int32(bitPattern: 0xE00002C5)) {
            return "Another app is using it. Quit Android File Transfer, OpenMTP, MacDroid or Image Capture and try again."
        }
        return error.localizedDescription
    }

    private func findEndpoints() throws {
        guard let interface else { throw MTPError.notFound }
        let config = interface.configurationDescriptor
        let iface = interface.interfaceDescriptor
        var current = UnsafeRawPointer(iface).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let ep = IOUSBGetNextEndpointDescriptor(config, iface, current) {
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            let attributes = ep.pointee.bmAttributes & 0x03
            let address = ep.pointee.bEndpointAddress
            guard attributes == 2 else { continue }  // bulk
            let pipe = try interface.copyPipe(withAddress: Int(address))
            if address & 0x80 != 0 {
                bulkIn = pipe
                maxPacket = Int(UInt16(littleEndian: ep.pointee.wMaxPacketSize) & 0x7FF)
            } else {
                bulkOut = pipe
            }
        }
        guard bulkIn != nil, bulkOut != nil else { throw MTPError.protocolError("no bulk endpoints") }
    }

    private func parseDeviceInfo(_ data: Data) {
        var r = MTPReader(data)
        _ = r.u16(); _ = r.u32(); _ = r.u16()  // standard version, vendor ext id, vendor ext version
        _ = r.string()                         // vendor extension description
        _ = r.u16()                            // functional mode
        supportedOps = Set(r.u16Array())
        _ = r.u16Array(); _ = r.u16Array(); _ = r.u16Array(); _ = r.u16Array()  // events, device props, formats
        manufacturer = r.string()
        model = r.string()
    }

    // MARK: Transactions

    struct Response {
        let code: UInt16
        let params: [UInt32]
        let data: Data
    }

    func requestCancel() { cancelLock.withLock { cancelRequested = true } }
    private var isCancelRequested: Bool { cancelLock.withLock { cancelRequested } }

    /// Runs one MTP transaction on the I/O queue.
    func transaction(_ code: UInt16, _ params: [UInt32], dataOut: Data? = nil, expectData: Bool) throws -> Response {
        try queue.sync { try transactionLocked(code, params, dataOut: dataOut, expectData: expectData) }
    }

    /// Streams a data-in phase (e.g. GetObject) to `sink`, reporting bytes received.
    func receive(_ code: UInt16, _ params: [UInt32], sink: (Data) throws -> Void, progress: (UInt64) -> Void) throws {
        try queue.sync {
            cancelLock.withLock { cancelRequested = false }
            try sendCommand(code, params)
            try readData(sink: sink, progress: progress)
            try readResponse(check: true)
        }
    }

    /// Streams a data-out phase (e.g. SendObject) from `source`, which returns nil at the end.
    ///
    /// Every USB transfer except the last must be an exact multiple of the endpoint's packet size:
    /// the phone reads a short packet as "end of data", so a stray one mid-file makes Android stop
    /// reading after the first chunk (uploads stuck at 0%, then a wedged connection).
    private func sendLocked(_ code: UInt16, _ params: [UInt32], totalLength: UInt64,
                            source: () throws -> Data?, progress: (UInt64) -> Void) throws {
        cancelLock.withLock { cancelRequested = false }
        try sendCommand(code, params)
        let containerLength = totalLength + 12 > UInt64(UInt32.max) ? UInt32.max : UInt32(totalLength + 12)
        var header = MTPWriter()
        header.u32(containerLength); header.u16(2); header.u16(code); header.u32(transactionID)
        var framer = MTPOutFramer(header: header.data, chunk: chunk)
        var sent: UInt64 = 0
        while true {
            if isCancelRequested { try cancelTransaction(); throw MTPError.cancelled }
            guard let next = try source(), !next.isEmpty else { break }
            sent += UInt64(next.count)
            for transfer in framer.append(next) {
                try writeData(transfer)
                progress(sent - UInt64(framer.buffered))
            }
        }
        if let last = framer.finish() { try writeData(last) }  // the final, possibly short, transfer
        if (totalLength + 12) % UInt64(maxPacket) == 0 { try write(Data()) }  // zero-length packet ends the phase
        progress(sent)
        // The phone may take a while to finish writing a big file to storage before it answers.
        let saved = ioTimeout
        ioTimeout = max(ioTimeout, 180)
        defer { ioTimeout = saved }
        try readResponse(check: true)
    }

    /// A data-phase write. If the phone stops reading, see whether it already answered with an
    /// error (e.g. storage full) so we can report that instead of a vague USB timeout.
    private func writeData(_ data: Data) throws {
        do {
            try write(data)
        } catch {
            if let early = try? read(maxPacket, timeout: 1), early.count >= 12 {
                var r = MTPReader(early)
                _ = r.u32()
                if r.u16() == 3 {
                    let code = r.u16()
                    resetLink()
                    throw MTPError.response(code == 0x2001 ? 0x2002 : code)
                }
            }
            throw error
        }
    }

    @discardableResult
    private func transactionLocked(_ code: UInt16, _ params: [UInt32], dataOut: Data? = nil,
                                   expectData: Bool, check: Bool = true) throws -> Response {
        try sendCommand(code, params)
        if let dataOut {
            var w = MTPWriter()
            w.u32(UInt32(dataOut.count + 12)); w.u16(2); w.u16(code); w.u32(transactionID)
            var packet = w.data
            packet.append(dataOut)
            try write(packet)
            if packet.count % maxPacket == 0 { try write(Data()) }
        }
        var data = Data()
        if expectData {
            if let early = try readData(sink: { data.append($0) }, progress: { _ in }) { return early }
        }
        let r = try readResponse(check: check)
        return Response(code: r.code, params: r.params, data: data)
    }

    private func sendCommand(_ code: UInt16, _ params: [UInt32]) throws {
        transactionID &+= 1
        var w = MTPWriter()
        w.u32(UInt32(12 + params.count * 4)); w.u16(1); w.u16(code); w.u32(transactionID)
        params.forEach { w.u32($0) }
        try write(w.data)
    }

    /// Reads a data phase. Returns a Response if the phone skipped straight to its response.
    @discardableResult
    private func readData(sink: (Data) throws -> Void, progress: (UInt64) -> Void) throws -> Response? {
        var first = try read(chunk)
        while first.isEmpty { first = try read(chunk) }  // stray zero-length packet
        guard first.count >= 12 else { throw MTPError.protocolError("short header") }
        var h = MTPReader(first)
        let length = h.u32(), type = h.u16(), code = h.u16(); _ = h.u32()
        if type == 3 {
            // No data: the phone answered right away (usually with an error).
            var params: [UInt32] = []
            while h.remaining >= 4 { params.append(h.u32()) }
            if code != 0x2001 { throw MTPError.response(code) }
            return Response(code: code, params: params, data: Data())
        }
        guard type == 2 else { throw MTPError.protocolError("expected data, got type \(type)") }
        let unknownLength = length == UInt32.max
        let expected = UInt64(length) - 12
        var received = UInt64(first.count - 12)
        try sink(first.subdata(in: 12..<first.count))
        progress(received)
        var lastCount = first.count
        while unknownLength ? lastCount == chunk : received < expected {
            if isCancelRequested { try cancelTransaction(); throw MTPError.cancelled }
            let next = try read(chunk)
            lastCount = next.count
            if next.isEmpty { break }
            received += UInt64(next.count)
            try sink(next)
            progress(received)
        }
        return nil
    }

    @discardableResult
    private func readResponse(check: Bool) throws -> (code: UInt16, params: [UInt32]) {
        var packet = try read(maxPacket)
        while packet.isEmpty { packet = try read(maxPacket) }  // trailing zero-length packet from the data phase
        var r = MTPReader(packet)
        guard packet.count >= 12 else { throw MTPError.protocolError("short response") }
        _ = r.u32()
        let type = r.u16(), code = r.u16(); _ = r.u32()
        guard type == 3 else { throw MTPError.protocolError("expected response, got type \(type)") }
        var params: [UInt32] = []
        while r.remaining >= 4 { params.append(r.u32()) }
        if check && code != 0x2001 { throw MTPError.response(code) }
        return (code, params)
    }

    /// USB Still Image class "Cancel Request", then drain until the phone is ready again.
    private func cancelTransaction() throws {
        guard let interface else { return }
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x21
        request.bRequest = 0x64
        request.wValue = 0
        request.wIndex = UInt16(interface.interfaceDescriptor.pointee.bInterfaceNumber)
        request.wLength = 6
        var body = MTPWriter(); body.u16(0x4001); body.u32(transactionID)
        let payload = NSMutableData(data: body.data)
        try? interface.__send(request, data: payload, bytesTransferred: nil, completionTimeout: 5)
        try? bulkIn?.__abort(with: .synchronous)
        try? bulkOut?.__abort(with: .synchronous)
        try? bulkIn?.clearStall()
        try? bulkOut?.clearStall()
        // Swallow whatever the phone still has in flight (often a "transaction cancelled" response).
        for _ in 0..<4 {
            guard let leftover = try? read(chunk, timeout: 1), !leftover.isEmpty else { break }
        }
    }

    private func write(_ data: Data) throws {
        guard let bulkOut else { throw MTPError.notFound }
        let buffer = NSMutableData(data: data)
        do {
            try bulkOut.__sendIORequest(with: data.isEmpty ? nil : buffer, bytesTransferred: nil, completionTimeout: ioTimeout)
        } catch {
            if MTPConnection.isGone(error) { throw MTPError.notFound }
            throw MTPError.openFailed("USB write failed (\(MTPConnection.code(error))).")
        }
    }

    /// The phone was unplugged (or the session closed): nothing to recover, so don't try resetting the link.
    static func isGone(_ error: Error) -> Bool {
        let code = UInt32(truncatingIfNeeded: (error as NSError).code)
        return [0xE00002C0, 0xE00002D7, 0xE00002D9, 0xE00002CD].contains(code)  // no device, offline, not attached, not open
    }

    private func read(_ length: Int, timeout: TimeInterval? = nil) throws -> Data {
        guard let bulkIn else { throw MTPError.notFound }
        let size = max(maxPacket, length / maxPacket * maxPacket)
        let buffer = NSMutableData(length: size)!
        var transferred: UInt = 0
        do {
            try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout ?? ioTimeout)
        } catch {
            if MTPConnection.isGone(error) { throw MTPError.notFound }
            throw MTPError.openFailed("USB read failed (\(MTPConnection.code(error))).")
        }
        return Data(bytes: buffer.bytes, count: Int(transferred))
    }

    // MARK: Operations

    func storages() throws -> [MTPStorage] {
        let ids = MTPReader(try transaction(0x1004, [], expectData: true).data).u32ArrayValue()
        return try ids.filter { $0 & 0xFFFF != 0 }.map { id in  // low 16 bits = 0 means "no media"
            var r = MTPReader(try transaction(0x1005, [id], expectData: true).data)
            _ = r.u16(); _ = r.u16(); _ = r.u16()  // storage type, filesystem type, access
            let capacity = r.u64(), free = r.u64()
            _ = r.u32()
            let description = r.string()
            return MTPStorage(id: id, description: description.isEmpty ? "Storage" : description, capacity: capacity, free: free)
        }
    }

    /// Set once a phone's bulk property list proves unreliable, so we stop asking for it this session.
    private var propListUnreliable = false

    /// Children of `parent` (0xFFFFFFFF = storage root).
    ///
    /// The list of items always comes from GetObjectHandles. The one-shot property list is only used to
    /// fill in details quickly, because many phones (including some Android versions) implement it
    /// wrongly, e.g. returning only the folder itself, which would make folders look empty. Anything it
    /// leaves out is asked for one item at a time.
    func children(storage: UInt32, parent: UInt32) throws -> [MTPObject] {
        let handles = MTPReader(try transaction(0x1007, [storage, 0, parent], expectData: true).data).u32ArrayValue()
        guard !handles.isEmpty else { return [] }
        var known: [UInt32: MTPObject] = [:]
        if supportedOps.contains(0x9805), !propListUnreliable, handles.count > 1,
           let list = try? objectPropList(storage: storage, parent: parent) {
            known = MTPConnection.index(list, keeping: handles)
            if known.count < handles.count / 2 { propListUnreliable = true }
        }
        return try handles.compactMap { handle in
            if let object = known[handle] { return object }
            do { return try objectInfo(handle) }
            catch MTPError.response(let code) where code == 0x2009 { return nil }  // deleted while listing
        }
    }

    /// Property-list results for exactly the given handles (anything else the phone sent is ignored).
    static func index(_ objects: [MTPObject], keeping handles: [UInt32]) -> [UInt32: MTPObject] {
        let wanted = Set(handles)
        var result: [UInt32: MTPObject] = [:]
        for object in objects where wanted.contains(object.handle) { result[object.handle] = object }
        return result
    }

    func objectInfo(_ handle: UInt32) throws -> MTPObject {
        var r = MTPReader(try transaction(0x1008, [handle], expectData: true).data)
        let storage = r.u32(), format = r.u16(); _ = r.u16()
        var size = UInt64(r.u32())
        _ = r.u16(); _ = r.u32(); _ = r.u32(); _ = r.u32(); _ = r.u32(); _ = r.u32(); _ = r.u32()
        let parent = r.u32()
        _ = r.u16(); _ = r.u32(); _ = r.u32()
        let name = r.string()
        _ = r.string()
        let modified = MTPReader.date(r.string())
        if size == UInt64(UInt32.max), supportedOps.contains(0x9803),
           let big = try? transaction(0x9803, [handle, 0xDC04], expectData: true).data, big.count >= 8 {
            var br = MTPReader(big); size = br.u64()
        }
        return MTPObject(handle: handle, storage: storage, parent: parent == 0 ? 0xFFFFFFFF : parent, name: name,
                         isFolder: format == 0x3001, size: size, modified: modified ?? .distantPast)
    }

    private func objectPropList(storage: UInt32, parent: UInt32) throws -> [MTPObject] {
        // Handle = folder (0 for the storage root), any format, all properties, depth 1 = its children.
        let folder = parent == 0xFFFFFFFF ? 0 : parent
        let data = try transaction(0x9805, [folder, 0, 0xFFFFFFFF, 0, 1], expectData: true).data
        var r = MTPReader(data)
        let count = r.u32()
        var fields: [UInt32: (name: String?, format: UInt16?, size: UInt64?, parent: UInt32?, storage: UInt32?, date: Date?)] = [:]
        var order: [UInt32] = []
        for _ in 0..<count {
            guard r.remaining >= 8 else { throw MTPError.protocolError("truncated property list") }
            let handle = r.u32(), prop = r.u16(), type = r.u16()
            if fields[handle] == nil { fields[handle] = (nil, nil, nil, nil, nil, nil); order.append(handle) }
            let value = try r.value(of: type)
            switch prop {
            case 0xDC07: fields[handle]!.name = value as? String
            case 0xDC02: fields[handle]!.format = (value as? UInt64).map { UInt16(truncatingIfNeeded: $0) }
            case 0xDC04: fields[handle]!.size = value as? UInt64
            case 0xDC0B: fields[handle]!.parent = (value as? UInt64).map { UInt32(truncatingIfNeeded: $0) }
            case 0xDC01: fields[handle]!.storage = (value as? UInt64).map { UInt32(truncatingIfNeeded: $0) }
            case 0xDC09: fields[handle]!.date = (value as? String).flatMap(MTPReader.date)
            default: break
            }
        }
        // Only fully described items are used; the caller checks them against the real handle list.
        return order.compactMap { handle -> MTPObject? in
            let f = fields[handle]!
            guard handle != folder, let name = f.name, let format = f.format, let size = f.size else { return nil }
            if let s = f.storage, s != storage { return nil }
            return MTPObject(handle: handle, storage: storage, parent: parent, name: name, isFolder: format == 0x3001,
                             size: size, modified: f.date ?? .distantPast)
        }
    }

    func download(_ handle: UInt32, to url: URL, progress: (UInt64) -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try receive(0x1009, [handle], sink: { try file.write(contentsOf: $0) }, progress: progress)
    }

    /// Downloads in 16 MB pieces when the phone supports partial reads, so other requests (browsing,
    /// thumbnails, a second transfer) can run between pieces and cancelling is instant.
    func downloadInPieces(_ handle: UInt32, size: UInt64, to url: URL,
                          isCancelled: () -> Bool, progress: (UInt64) -> Void) throws {
        let piece: UInt64 = 16 << 20
        let op64 = supportedOps.contains(0x95C1), op32 = supportedOps.contains(0x101B)
        guard op64 || (op32 && size < UInt64(UInt32.max)) else {
            if isCancelled() { throw MTPError.cancelled }
            return try download(handle, to: url, progress: progress)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var offset: UInt64 = 0
        var stalls = 0
        while offset < size {
            if isCancelled() { throw MTPError.cancelled }
            let want = UInt32(min(piece, size - offset))
            let params = op64
                ? [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), want]
                : [handle, UInt32(offset), want]
            var got: UInt64 = 0
            do {
                try receive(op64 ? 0x95C1 : 0x101B, params, sink: { try file.write(contentsOf: $0); got += UInt64($0.count) },
                            progress: { progress(offset + $0) })
            } catch MTPError.cancelled where !isCancelled() {
                // Another transfer's cancel landed on this piece; rewind and retry it.
                try file.truncate(atOffset: offset)
                try file.seek(toOffset: offset)
                continue
            }
            if got == 0 { stalls += 1; if stalls > 2 { throw MTPError.protocolError("no data") } }
            offset += got
        }
    }

    func batteryLevel() -> Int? {
        guard let data = try? transaction(0x1015, [0x5001], expectData: true).data, let level = data.first else { return nil }
        return Int(level)
    }

    func readAll(_ handle: UInt32) throws -> Data {
        var data = Data()
        try receive(0x1009, [handle], sink: { data.append($0) }, progress: { _ in })
        return data
    }

    func thumbnail(_ handle: UInt32) throws -> Data {
        try transaction(0x100A, [handle], expectData: true).data
    }

    /// Creates a folder (or an empty file entry) and returns its new handle.
    func sendObjectInfo(storage: UInt32, parent: UInt32, name: String, isFolder: Bool, size: UInt64) throws -> UInt32 {
        try queue.sync { try sendObjectInfoLocked(storage: storage, parent: parent, name: name, isFolder: isFolder, size: size) }
    }

    private func sendObjectInfoLocked(storage: UInt32, parent: UInt32, name: String, isFolder: Bool, size: UInt64) throws -> UInt32 {
        var w = MTPWriter()
        w.u32(storage)
        w.u16(isFolder ? 0x3001 : 0x3000)                 // association (folder) / undefined
        w.u16(0)                                          // protection
        w.u32(size > UInt64(UInt32.max) ? UInt32.max : UInt32(size))
        w.u16(0); w.u32(0); w.u32(0); w.u32(0)            // thumb format, size, width, height
        w.u32(0); w.u32(0); w.u32(0)                      // image width, height, depth
        w.u32(parent)
        w.u16(isFolder ? 1 : 0); w.u32(0); w.u32(0)       // association type, desc, sequence
        w.string(name)
        w.string(""); w.string(MTPWriter.dateString(Date())); w.string("")
        let r = try transactionLocked(0x100C, [storage, parent], dataOut: w.data, expectData: false)
        guard r.params.count >= 3 else { throw MTPError.protocolError("no handle for new item") }
        return r.params[2]
    }

    func upload(from url: URL, storage: UInt32, parent: UInt32, name: String, progress: (UInt64) -> Void) throws -> UInt32 {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // SendObject must come straight after SendObjectInfo: any other request in between (a thumbnail,
        // a folder refresh, a second upload) makes Android drop the pending file. So hold the queue for both.
        return try queue.sync {
            let handle = try sendObjectInfoLocked(storage: storage, parent: parent, name: name, isFolder: false, size: size)
            do {
                try sendLocked(0x100D, [], totalLength: size, source: { try file.read(upToCount: 1 << 20) }, progress: progress)
            } catch {
                // Don't leave a half-written file on the phone (Android usually removes it itself).
                if !((error as? MTPError)?.isLinkFailure ?? false) {
                    _ = try? transactionLocked(0x100B, [handle, 0], expectData: false, check: false)
                }
                throw error
            }
            return handle
        }
    }

    func delete(_ handle: UInt32) throws {
        _ = try transaction(0x100B, [handle, 0], expectData: false)
    }

    func rename(_ handle: UInt32, to name: String) throws {
        var w = MTPWriter(); w.string(name)
        _ = try transaction(0x9804, [handle, 0xDC07], dataOut: w.data, expectData: false)
    }
}

// MARK: - Wire format helpers

/// Splits an outgoing data phase into USB transfers. Every transfer but the last is exactly `chunk`
/// bytes (a multiple of any USB packet size), so the phone never sees a short packet mid-file.
struct MTPOutFramer {
    let chunk: Int
    private var pending: Data

    init(header: Data, chunk: Int) {
        self.chunk = chunk
        pending = header
    }

    var buffered: Int { pending.count }

    /// Adds data and returns the full transfers that are ready to send.
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var ready: [Data] = []
        while pending.count >= chunk {
            ready.append(Data(pending.prefix(chunk)))
            pending = Data(pending.dropFirst(chunk))
        }
        return ready
    }

    /// The last transfer, if anything is left.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

struct MTPReader {
    private let data: Data
    private var offset = 0
    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    private mutating func bytes(_ n: Int) -> Data? {
        guard remaining >= n else { offset = data.count; return nil }
        defer { offset += n }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
    }

    private mutating func int<T: FixedWidthInteger>(_: T.Type) -> T {
        guard let b = bytes(MemoryLayout<T>.size) else { return 0 }
        return b.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    mutating func u8() -> UInt8 { int(UInt8.self) }
    mutating func u16() -> UInt16 { int(UInt16.self) }
    mutating func u32() -> UInt32 { int(UInt32.self) }
    mutating func u64() -> UInt64 { int(UInt64.self) }

    /// PTP string: UInt8 character count (including the terminating NUL), then UTF-16LE.
    mutating func string() -> String {
        let count = Int(u8())
        guard count > 0, let raw = bytes(count * 2) else { return "" }
        let units = raw.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }.map(UInt16.init(littleEndian:))
        return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
    }

    mutating func u16Array() -> [UInt16] { (0..<min(Int(u32()), remaining / 2)).map { _ in u16() } }

    func u32ArrayValue() -> [UInt32] {
        var copy = self
        return (0..<min(Int(copy.u32()), copy.remaining / 4)).map { _ in copy.u32() }
    }

    /// Reads one property value of MTP datatype `type`. Integers come back as UInt64, strings as String.
    mutating func value(of type: UInt16) throws -> Any? {
        switch type {
        case 0x0001, 0x0002: return UInt64(u8())
        case 0x0003, 0x0004: return UInt64(u16())
        case 0x0005, 0x0006: return UInt64(u32())
        case 0x0007, 0x0008: return u64()
        case 0x0009, 0x000A: _ = u64(); _ = u64(); return nil
        case 0xFFFF: return string()
        case 0x4001...0x400A:
            let elementSize = [1, 1, 2, 2, 4, 4, 8, 8, 16, 16][Int(type - 0x4001)]
            let n = Int(u32())
            guard remaining >= n * elementSize else { throw MTPError.protocolError("bad array") }
            _ = bytes(n * elementSize)
            return nil
        default:
            throw MTPError.protocolError(String(format: "unknown datatype 0x%04X", type))
        }
    }

    /// "YYYYMMDDThhmmss[.s][Z|±hhmm]" → Date (local time when no zone is given).
    static func date(_ s: String) -> Date? {
        let digits = s.prefix(15)
        guard digits.count == 15 else { return nil }
        return (s.hasSuffix("Z") ? utcFormatter : localFormatter).date(from: String(digits))
    }

    // Built once: making a DateFormatter per file is slow in folders with thousands of photos.
    private static let localFormatter = mtpFormatter(timeZone: .current)
    private static let utcFormatter = mtpFormatter(timeZone: TimeZone(identifier: "UTC")!)

    static func mtpFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = timeZone
        return f
    }
}

struct MTPWriter {
    private(set) var data = Data()

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    mutating func string(_ s: String) {
        guard !s.isEmpty else { data.append(0); return }
        let units = Array(s.utf16.prefix(254)) + [0]
        data.append(UInt8(units.count))
        units.forEach { u16($0) }
    }

    static func dateString(_ date: Date) -> String {
        MTPReader.mtpFormatter(timeZone: .current).string(from: date)
    }
}

// MARK: - Discovery

enum MTPDiscovery {
    struct Candidate {
        let service: io_service_t   // retained; caller releases
        /// The phone's USB serial number (matches its adb serial), or "" if it doesn't report one.
        let usbSerial: String
        let vendorID: Int
        let locationID: Int
        let productName: String
        /// Changes whenever the phone reconnects on USB; see `MTPConnection.registryID`.
        let registryID: UInt64

        /// Stable across polls: the serial number, or the USB port for phones without one.
        var key: String { usbSerial.isEmpty ? String(format: "usb-%08x", locationID) : usbSerial }
    }

    private static let appleVendor = 0x05AC
    /// Digital-camera makers whose cameras also speak PTP; leave those to Photos and Image Capture.
    private static let cameraVendors: Set<Int> = [
        0x04A9, 0x04B0, 0x04CB, 0x07B4, 0x04DA, 0x054C, 0x2672, 0x040A, 0x1A98, 0x25FB, 0x0A17, 0x0DCA,
    ]

    /// Whether a USB interface is a phone's file-transfer (MTP, or PTP) interface we should open.
    static func isPhoneTransferInterface(interfaceClass: Int, subclass: Int, name: String, vendor: Int) -> Bool {
        guard vendor != appleVendor else { return false }  // iPhones and iPads use PTP too: not ours
        let upper = name.uppercased()
        switch interfaceClass {
        case 0x06:  // Still Image: Android in File transfer (MTP) or PTP mode, or a camera
            if upper.contains("MTP") { return true }
            return !cameraVendors.contains(vendor)
        case 0xFF:  // vendor-specific: Samsung and others label their MTP interface; never take adb (subclass 0x42)
            return subclass != 0x42 && upper.contains("MTP")
        default:
            return false
        }
    }

    /// The phones' file-transfer interfaces currently on USB.
    static func candidates() -> [Candidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Candidate] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let cls = property(service, "bInterfaceClass") as? Int ?? -1
            guard cls == 0x06 || cls == 0xFF else { IOObjectRelease(service); continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { IOObjectRelease(service); continue }
            defer { IOObjectRelease(parent) }
            let vendor = property(parent, "idVendor") as? Int ?? 0
            guard isPhoneTransferInterface(interfaceClass: cls,
                                           subclass: property(service, "bInterfaceSubClass") as? Int ?? -1,
                                           name: property(service, "USB Interface Name") as? String ?? "",
                                           vendor: vendor) else { IOObjectRelease(service); continue }
            let serial = property(parent, "USB Serial Number") as? String ?? property(parent, "kUSBSerialNumberString") as? String ?? ""
            let product = property(parent, "USB Product Name") as? String ?? property(parent, "kUSBProductString") as? String ?? "Android phone"
            result.append(Candidate(service: service, usbSerial: serial, vendorID: vendor,
                                    locationID: property(parent, "locationID") as? Int ?? 0, productName: product,
                                    registryID: registryID(of: service)))
        }
        return result
    }

    /// Resets the phone's USB connection, like unplugging and replugging it. This clears a file-transfer
    /// session that Android has left stuck, and needs no special permissions.
    static func resetDevice(_ candidateKey: String) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let serial = property(service, "USB Serial Number") as? String ?? ""
            let location = property(service, "locationID") as? Int ?? 0
            guard (serial.isEmpty ? String(format: "usb-%08x", location) : serial) == candidateKey,
                  let device = try? IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            else { continue }
            do { try device.reset() } catch { MTPConnection.log("USB reset failed: \(MTPConnection.code(error))") }
            device.destroy()
            MTPConnection.log("USB reset done")
        }
    }

    static func registryID(of entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
