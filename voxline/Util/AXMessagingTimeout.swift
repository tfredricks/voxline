import ApplicationServices

/// Caps how long any Accessibility request may block on a busy target app.
/// The system default is about six seconds per call, long enough to beachball
/// voxline on the main actor while an Electron app is busy.
enum AXMessagingTimeout {

    static let seconds: Float = 0.5

    /// Setting the timeout on the system-wide element makes it the default for
    /// every element this process creates that does not set its own.
    static func install() {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}
