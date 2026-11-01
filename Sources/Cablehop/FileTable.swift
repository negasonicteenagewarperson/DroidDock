import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sorting

struct FileSort: Equatable {
    enum Key: String { case name, size, modified, kind }
    var key: Key = .name
    var ascending = true

    /// Folders first, then by the chosen column, like Finder.
    func apply(_ files: [RemoteFile]) -> [RemoteFile] {
        let sorted = files.sorted { a, b in
            let ordered: Bool
            switch key {
            case .name: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: ordered = a.size == b.size ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.size < b.size
            case .modified: ordered = a.modified < b.modified
            case .kind: ordered = a.kind.localizedStandardCompare(b.kind) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }
}

// MARK: - Menus

/// A context-menu entry that can be shown as an AppKit menu (list, grid items) or a SwiftUI menu.
struct MenuSpec {
    enum Kind { case item, separator }
    var kind: Kind = .item
    var title = ""
    var enabled = true
    var action: () -> Void = {}

    static var separator: MenuSpec { MenuSpec(kind: .separator) }
    static func item(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) -> MenuSpec {
        MenuSpec(title: title, enabled: enabled, action: action)
    }

    static func menu(_ specs: [MenuSpec]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for spec in specs {
            if spec.kind == .separator { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: spec.title, handler: spec.action)
            item.isEnabled = spec.enabled
            menu.addItem(item)
        }
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

struct MenuSpecView: View {
    let specs: [MenuSpec]

    var body: some View {
        ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
            if spec.kind == .separator {
                Divider()
            } else {
                Button(spec.title, action: spec.action).disabled(!spec.enabled)
            }
        }
    }
}

// MARK: - Dragging files out to Finder

/// Carries an error from the main actor back to the waiting promise thread (ordered by a semaphore).
private final class ErrorBox: @unchecked Sendable { var error: Error? }

/// Hands Finder (or any app) a promise for each dragged phone item; the file is copied from the
/// phone straight to wherever it's dropped. This is how Finder expects virtual files to be dragged.
final class PhoneFilePromises: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = PhoneFilePromises()

    private struct Payload {
        let serial: String
        let file: RemoteFile
    }

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Cablehop drag-out"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    func provider(serial: String, file: RemoteFile) -> NSFilePromiseProvider {
        let type = file.isDirectory ? UTType.folder.identifier : file.utType.identifier
        let provider = NSFilePromiseProvider(fileType: type, delegate: self)
        provider.userInfo = Payload(serial: serial, file: file)
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        RemotePath.safeLocalName((provider.userInfo as? Payload)?.file.name ?? "File")
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let payload = provider.userInfo as? Payload else { completionHandler(nil); return }
        let done = DispatchSemaphore(value: 0)
        let outcome = ErrorBox()
        Task { @MainActor in
            let tracker = TransferManager.current?.beginExternal(serial: payload.serial, file: payload.file, destination: url)
            do {
                try await PhoneFiles.download(serial: payload.serial, file: payload.file, to: url) { fraction in
                    Task { @MainActor in tracker?.updateProgress(fraction) }
                }
                Quarantine.mark(url)
                TransferManager.current?.endExternal(tracker, error: nil)
            } catch {
                outcome.error = error
                TransferManager.current?.endExternal(tracker, error: error)
            }
            done.signal()
        }
        done.wait()  // we're on the promise queue, not the main thread
        completionHandler(outcome.error)
    }
}

// MARK: - List view

/// The Finder-style file list. It's AppKit underneath so dragging to and from Finder, dropping on
/// folders, type-to-select, and Copy/Paste/Delete all behave exactly like a native Mac list.
struct FileTable: NSViewRepresentable {
    var files: [RemoteFile]
    @Binding var selection: Set<RemoteFile.ID>
    @Binding var sort: FileSort
    var serial: String
    var showLocation: Bool
    var onOpen: ([RemoteFile]) -> Void
    var onQuickLook: (RemoteFile) -> Void
    var menu: (Set<RemoteFile.ID>) -> [MenuSpec]
    /// Files dropped from Finder; the folder path is set when dropped onto a folder row.
    var onDrop: ([URL], String?) -> Void
    var onCopy: () -> Void
    var onCut: () -> Void
    var onPaste: () -> Void
    var canCopy: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 24
        table.autosaveName = "CablehopFileTable"
        table.autosaveTableColumns = true

        let columns: [(String, String, CGFloat, CGFloat, FileSort.Key)] = [
            ("name", "Name", 340, 180, .name),
            ("size", "Size", 90, 60, .size),
            ("modified", "Date Modified", 170, 120, .modified),
            ("kind", "Kind", 150, 80, .kind),
        ]
        for (id, title, width, min, key) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = min
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.reload(force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileTable
        weak var table: FileTableView?
        private var rows: [RemoteFile] = []
        private var syncingSelection = false
        private var lastShowLocation: Bool?

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            return f
        }()

        init(_ parent: FileTable) { self.parent = parent }

        func reload(force: Bool) {
            guard let table else { return }
            if force || rows != parent.files || lastShowLocation != parent.showLocation {
                rows = parent.files
                lastShowLocation = parent.showLocation
                table.tableColumn(withIdentifier: .init("kind"))?.title = parent.showLocation ? "Location" : "Kind"
                syncingSelection = true
                table.reloadData()
                syncingSelection = false
            }
            let descriptor = NSSortDescriptor(key: parent.sort.key.rawValue, ascending: parent.sort.ascending)
            if table.sortDescriptors.first?.key != descriptor.key || table.sortDescriptors.first?.ascending != descriptor.ascending {
                syncingSelection = true
                table.sortDescriptors = [descriptor]
                syncingSelection = false
            }
            let wanted = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            if wanted != table.selectedRowIndexes {
                syncingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                syncingSelection = false
            }
        }

        func files(at indexes: IndexSet) -> [RemoteFile] { indexes.compactMap { $0 < rows.count ? rows[$0] : nil } }
        var selectedFiles: [RemoteFile] { files(at: table?.selectedRowIndexes ?? []) }

        // Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < rows.count else { return nil }
            let file = rows[row]
            let id = column.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = file.name
                cell.textField?.alphaValue = file.isHidden ? 0.55 : 1
                cell.imageView?.image = IconCache.icon(for: file)
                cell.toolTip = file.path
            case "size":
                cell.textField?.stringValue = file.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            case "modified":
                cell.textField?.stringValue = file.modified == .distantPast ? "--" : Self.dateFormatter.string(from: file.modified)
            default:
                cell.textField?.stringValue = parent.showLocation ? FileTable.displayLocation(file.parentPath) : file.kind
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = id.rawValue == "kind" ? .byTruncatingHead : .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            if id.rawValue != "name" {
                text.textColor = .secondaryLabelColor
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            if id.rawValue == "size" { text.alignment = .right }
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    image.heightAnchor.constraint(equalToConstant: 18),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier.rawValue == "name" && row < rows.count ? rows[row].name : nil
        }

        // Selection & sorting

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection, let table else { return }
            parent.selection = Set(files(at: table.selectedRowIndexes).map(\.id))
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncingSelection, let d = tableView.sortDescriptors.first, let key = d.key.flatMap(FileSort.Key.init) else { return }
            parent.sort = FileSort(key: key, ascending: d.ascending)
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            parent.onOpen(selectedFiles)
        }

        func menu(forRow row: Int) -> NSMenu? {
            guard let table else { return nil }
            var ids: Set<RemoteFile.ID> = []
            if row >= 0 && row < rows.count {
                if !table.selectedRowIndexes.contains(row) {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                }
                ids = Set(selectedFiles.map(\.id))
            }
            return MenuSpec.menu(parent.menu(ids))
        }

        // Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rows.count else { return nil }
            return PhoneFilePromises.shared.provider(serial: parent.serial, file: rows[row])
        }

        // Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }  // our own rows
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly) else { return [] }
            if op == .on, row >= 0, row < rows.count, rows[row].isDirectory {
                return .copy  // drop into that folder
            }
            tableView.setDropRow(-1, dropOperation: .on)  // anywhere else: the folder being shown
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            let folder = row >= 0 && row < rows.count && rows[row].isDirectory ? rows[row].path : nil
            parent.onDrop(urls, folder)
            return true
        }

        static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    }

    static func displayLocation(_ path: String) -> String {
        path == "/sdcard" || path.hasPrefix("/sdcard/")
            ? "Internal Storage" + path.dropFirst("/sdcard".count).replacingOccurrences(of: "/", with: " › ")
            : path
    }
}

/// NSTableView with Finder-like keys: Space for Quick Look, Return / ⌘↓ to open, and the standard
/// Edit menu actions (Copy, Cut, Paste) routed to the browser.
final class FileTableView: NSTableView {
    weak var coordinator: FileTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 49 where flags.isEmpty:  // space
            if let file = coordinator.selectedFiles.first(where: { !$0.isDirectory }) { coordinator.parent.onQuickLook(file) }
        case 36, 76:  // return, enter
            coordinator.parent.onOpen(coordinator.selectedFiles)
        case 125 where flags.contains(.command):  // ⌘↓
            coordinator.parent.onOpen(coordinator.selectedFiles)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    @objc func copy(_ sender: Any?) { coordinator?.parent.onCopy() }
    @objc func cut(_ sender: Any?) { coordinator?.parent.onCut() }
    @objc func paste(_ sender: Any?) { coordinator?.parent.onPaste() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return coordinator?.parent.canCopy == true && !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

// MARK: - Grid item interaction

/// Sits on top of a grid item and handles clicks, double-clicks, right-clicks and dragging with AppKit,
/// so grid items can be dragged into Finder as real files just like list rows.
struct GridItemInteraction: NSViewRepresentable {
    var file: RemoteFile
    var onSelect: (NSEvent.ModifierFlags) -> Void
    /// A plain click that didn't turn into a drag: narrow the selection to this item.
    var onClickUp: () -> Void
    var onOpen: () -> Void
    var menu: () -> NSMenu
    var dragFiles: () -> [RemoteFile]
    var serial: String

    func makeNSView(context: Context) -> GridItemView { GridItemView() }

    func updateNSView(_ view: GridItemView, context: Context) { view.config = self }

    final class GridItemView: NSView, NSDraggingSource {
        var config: GridItemInteraction?
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            if event.clickCount == 2 { config?.onOpen(); return }
            config?.onSelect(event.modifierFlags)
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownEvent = nil }
            guard let down = mouseDownEvent, down.clickCount == 1,
                  down.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            config?.onClickUp()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let config, let down = mouseDownEvent else { return }
            let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
            guard distance > 4 else { return }
            mouseDownEvent = nil
            let files = config.dragFiles()
            var offset: CGFloat = 0
            let items = files.map { file -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: PhoneFilePromises.shared.provider(serial: config.serial, file: file))
                let icon = IconCache.icon(for: file)
                item.setDraggingFrame(NSRect(x: bounds.midX - 32 + offset, y: bounds.midY - 32 - offset, width: 64, height: 64), contents: icon)
                offset += 6
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func menu(for event: NSEvent) -> NSMenu? { config?.menu() }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}
