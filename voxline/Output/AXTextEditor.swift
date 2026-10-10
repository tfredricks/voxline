// voxline/Output/AXTextEditor.swift
import ApplicationServices
import Foundation

/// Replaces the focused element's selection through `kAXSelectedText` and
/// reports whether the write landed.
struct AXTextEditor: Sendable {

    /// `applied` finishes the insert; `rejected` lets the next strategy run;
    /// `unknown` means a timed-out write may still land, so nothing else may
    /// be tried.
    enum Outcome: Equatable {
        case applied(verified: Bool)
        case rejected
        case unknown
    }

    var writeTimeout: Float = 2
    var settleDelay: Duration = .milliseconds(150)
    var pollInterval: Duration = .milliseconds(100)
    var pollTimeout: Duration = .seconds(1)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> ContinuousClock.Instant = { .now }

    /// Verified means the read-back value equals the old value with the old
    /// selection replaced. A success that leaves the value unchanged across a
    /// `settleDelay` re-read is `rejected`. A `cannotComplete` write is polled
    /// for `pollTimeout`, reads included, and is `unknown` if it never shows
    /// up (it never falls through, so it can't insert twice).
    func replaceSelection(of element: any AXTextElement, with text: String) async -> Outcome {
        guard element.isSettable(kAXSelectedTextAttribute) == .value(true) else { return .rejected }

        let original = element.string(kAXValueAttribute).value
        let selection = element.range(kAXSelectedTextRangeAttribute).value
        let expected = Self.expectedValue(original: original, selection: selection, text: text)

        switch element.set(kAXSelectedTextAttribute, string: text, timeout: writeTimeout) {
        case .success:
            if let outcome = Self.judge(element.string(kAXValueAttribute), original: original, expected: expected) {
                return outcome
            }
            try? await sleep(settleDelay)
            return Self.judge(element.string(kAXValueAttribute), original: original, expected: expected) ?? .rejected
        case .cannotComplete:
            return await awaitLateWrite(on: element, original: original, expected: expected)
        default:
            return .rejected
        }
    }

    static func expectedValue(original: String?, selection: UTF16Range?, text: String) -> String? {
        guard let original, let selection else { return nil }
        let value = original as NSString
        guard selection.fits(in: value.length) else { return nil }
        return value.replacingCharacters(in: selection.nsRange, with: text)
    }

    /// nil when the value still reads as `original`.
    private static func judge(_ read: AXRead<String>, original: String?, expected: String?) -> Outcome? {
        guard let value = read.value else { return .applied(verified: false) }
        if value == expected { return .applied(verified: true) }
        if value != original { return .applied(verified: false) }
        return nil
    }

    private func awaitLateWrite(on element: any AXTextElement, original: String?, expected: String?) async -> Outcome {
        var waited: Duration = .zero
        while waited < pollTimeout {
            try? await sleep(pollInterval)
            let readStart = now()
            let read = element.string(kAXValueAttribute)
            waited += pollInterval + readStart.duration(to: now())
            guard let value = read.value else { continue }
            if let expected, value == expected { return .applied(verified: true) }
            if let original, value != original { return .applied(verified: false) }
        }
        return .unknown
    }
}
