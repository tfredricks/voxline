// voxline/Util/AXTextElement.swift
import AppKit
import ApplicationServices

/// Tri-state result of one AX read. `absent` is the app saying "no such
/// value"; `failed` is the app not answering (timeout) or answering with an
/// error or a value of the wrong type. Callers that gate safety on a read
/// treat `failed` as a refusal, never as "no".
enum AXRead<T> {
    case value(T)
    case absent
    case failed

    var value: T? { if case .value(let v) = self { return v } else { return nil } }
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}
extension AXRead: Equatable where T: Equatable {}

/// Every AX access the edit path makes, behind one protocol so tests script it.
protocol AXTextElement: Sendable {
    var ref: AXElementRef { get }
    func string(_ attribute: String) -> AXRead<String>
    func range(_ attribute: String) -> AXRead<UTF16Range>
    func attributeNames() -> AXRead<[String]>
    /// `.absent` and `.failed` both mean "do not try to set it".
    func isSettable(_ attribute: String) -> AXRead<Bool>
    /// Sets the attribute with `timeout` seconds of messaging timeout on this
    /// element, then restores `AXMessagingTimeout.seconds`.
    func set(_ attribute: String, string: String, timeout: Float) -> AXError
    func set(_ attribute: String, range: UTF16Range, timeout: Float) -> AXError
}

struct LiveAXTextElement: AXTextElement, @unchecked Sendable {
    let element: AXUIElement
    var ref: AXElementRef { AXElementRef(element: element) }

    /// `.success` → value (type-checked), `.noValue` / `.attributeUnsupported` /
    /// `.notImplemented` → `.absent`, anything else → `.failed`.
    static func classify<T>(_ status: AXError, _ value: CFTypeRef?, as cast: (CFTypeRef) -> T?) -> AXRead<T> {
        guard status == .success else { return unanswered(status) }
        guard let value, let typed = cast(value) else { return .failed }
        return .value(typed)
    }

    /// A CFRange carried in an AXValue, or nil for any other payload.
    static func rangeValue(_ value: CFTypeRef) -> UTF16Range? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return UTF16Range(range)
    }

    func string(_ attribute: String) -> AXRead<String> {
        let (status, value) = copy(attribute)
        return Self.classify(status, value) { $0 as? String }
    }

    func range(_ attribute: String) -> AXRead<UTF16Range> {
        let (status, value) = copy(attribute)
        return Self.classify(status, value, as: Self.rangeValue)
    }

    func attributeNames() -> AXRead<[String]> {
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &names)
        return Self.classify(status, names) { $0 as? [String] }
    }

    func isSettable(_ attribute: String) -> AXRead<Bool> {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard status == .success else { return Self.unanswered(status) }
        return .value(settable.boolValue)
    }

    func set(_ attribute: String, string: String, timeout: Float) -> AXError {
        withTimeout(timeout) {
            AXUIElementSetAttributeValue(element, attribute as CFString, string as CFString)
        }
    }

    func set(_ attribute: String, range: UTF16Range, timeout: Float) -> AXError {
        var cfRange = range.cfRange
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return .failure }
        return withTimeout(timeout) {
            AXUIElementSetAttributeValue(element, attribute as CFString, value)
        }
    }

    private static func unanswered<T>(_ status: AXError) -> AXRead<T> {
        switch status {
        case .noValue, .attributeUnsupported, .notImplemented: return .absent
        default: return .failed
        }
    }

    private func copy(_ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (status, value)
    }

    private func withTimeout(_ timeout: Float, _ body: () -> AXError) -> AXError {
        _ = AXUIElementSetMessagingTimeout(element, timeout)
        defer { _ = AXUIElementSetMessagingTimeout(element, AXMessagingTimeout.seconds) }
        return body()
    }
}

/// What the edit path needs to know about the focused element before reading
/// text. App and window fields are nil when unknown; the element is the seam.
struct FocusedElementSnapshot: @unchecked Sendable {
    let element: any AXTextElement
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
}

enum LiveFocusedElementSource {
    /// System-wide focused element with the app's name/bundle ID from its pid
    /// and the window title read the way `DefaultAXContextProbe` reads it
    /// (element's window, then the app's focused window). `.noValue` on the
    /// focused-element read is `.absent`; any other error is `.failed`.
    static func read() -> AXRead<FocusedElementSnapshot> {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value
        )
        switch status {
        case .success: break
        case .noValue: return .absent
        default: return .failed
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failed }
        let element = value as! AXUIElement

        var pid: pid_t = 0
        let hasPid = AXUIElementGetPid(element, &pid) == .success
        let app = hasPid ? NSRunningApplication(processIdentifier: pid) : nil

        return .value(FocusedElementSnapshot(
            element: LiveAXTextElement(element: element),
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            windowTitle: windowTitle(of: element, pid: hasPid ? pid : nil)
        ))
    }

    private static func windowTitle(of element: AXUIElement, pid: pid_t?) -> String? {
        if let window = element.elementAttribute(kAXWindowAttribute as CFString),
           let title = clip(window.stringAttribute(kAXTitleAttribute)) {
            return title
        }
        guard let pid,
              let window = AXUIElementCreateApplication(pid).elementAttribute(kAXFocusedWindowAttribute as CFString)
        else { return nil }
        return clip(window.stringAttribute(kAXTitleAttribute))
    }

    private static func clip(_ s: String?) -> String? {
        let maxLen = DefaultAXContextProbe.windowTitleMax
        guard let s, !s.isEmpty else { return nil }
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen - 1)) + "…"
    }
}
