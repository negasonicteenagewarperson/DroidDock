import Foundation
import IOKit

/// Tells Cablehop the moment a USB device is plugged in or removed, so a phone shows up right away
/// instead of at the next poll. A phone also reconnects over USB when you pick "File transfer" on it,
/// so this covers that too.
final class USBWatcher {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let onChange: () -> Void

    /// Whether macOS accepted both the "plugged in" and "removed" notifications.
    var isArmed: Bool { iterators.count == 2 }

    /// `onChange` is called on the main queue.
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            USBWatcher.drain(iterator)  // reading the iterator re-arms the notification
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostInterface"),
                                                   callback, context, &iterator) == KERN_SUCCESS else { continue }
            USBWatcher.drain(iterator)  // skip what's already connected and arm the notification
            iterators.append(iterator)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        IONotificationPortDestroy(port)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
