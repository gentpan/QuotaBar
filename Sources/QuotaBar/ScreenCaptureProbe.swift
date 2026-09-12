import Foundation

/// "Is anything capturing the screen right now?" — a screen share, a
/// recording, macOS Screen Sharing. After openusage: AppKit has no public
/// signal for it, and the window server's own watcher flag is what the
/// system's capture indicator rides, so it is bound through `dlsym` and a
/// missing symbol simply reads as "not captured".
enum ScreenCaptureProbe {
    private typealias IsWatcherPresent = @convention(c) () -> Bool

    private static let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let isWatcherPresent: IsWatcherPresent? = {
        for name in ["SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent"] {
            if let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: IsWatcherPresent.self)
            }
        }
        return nil
    }()

    static var isAvailable: Bool { isWatcherPresent != nil }

    static func isScreenCaptured() -> Bool {
        isWatcherPresent?() ?? false
    }
}
