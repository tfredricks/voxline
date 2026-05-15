import Foundation
import OSLog

/// Persistent rolling text log. Appends formatted lines to a file on disk,
/// keeping at most `maxEntries` lines (oldest evicted first). Thread-safe.
/// Never throws to callers; disk failures are reported once per kind via OSLog.
final class RollingFileLog {

    enum Level: String {
        case info   = "INFO"
        case notice = "NOTICE"
        case error  = "ERROR"
        case fault  = "FAULT"
    }

    private enum FailureKind: String, Hashable {
        case notFound    // ENOENT or parent dir missing
        case permission  // EACCES / EPERM
        case diskFull    // ENOSPC / NSFileWriteOutOfSpaceError / read-only volume
        case other
    }

    private static let internalLog = Logger(
        subsystem: "com.voxline.app",
        category: "rolling-file-log"
    )

    private let fileURL: URL
    private let clock: () -> Date
    private let maxEntries: Int
    private let formatter: DateFormatter

    private var ring: [String] = []
    private var initializedFromDisk = false
    private var reportedFailures: Set<FailureKind> = []
    private var lock = os_unfair_lock_s()

    init(
        fileURL: URL,
        clock: @escaping () -> Date = Date.init,
        maxEntries: Int = 250
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.maxEntries = maxEntries

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = f
    }

    func info(_ message: String, category: String) {
        append(level: .info, category: category, message: message)
    }

    func notice(_ message: String, category: String) {
        append(level: .notice, category: category, message: message)
    }

    func error(_ message: String, category: String) {
        append(level: .error, category: category, message: message)
    }

    func fault(_ message: String, category: String) {
        append(level: .fault, category: category, message: message)
    }

    private func append(level: Level, category: String, message: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if !initializedFromDisk {
            seedFromDiskLocked()
            initializedFromDisk = true
        }

        let line = "[\(formatter.string(from: clock()))] [\(level.rawValue)] [\(category)] \(message)"
        ring.append(line)
        while ring.count > maxEntries {
            ring.removeFirst()
        }

        let body = ring.joined(separator: "\n") + "\n"
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            reportFailureLocked(error: error)
        }
    }

    /// Loads up to `maxEntries` lines from `fileURL` into `ring`. Tolerates
    /// missing or unreadable files by leaving `ring` empty. Caller must
    /// hold `lock`.
    private func seedFromDiskLocked() {
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.count > maxEntries {
            lines = Array(lines.suffix(maxEntries))
        }
        ring = lines
    }

    /// Emits an OSLog `.error` the first time each `FailureKind` occurs
    /// in this instance's lifetime (per-process when used via the
    /// `AppLog.fileLog` singleton). Caller must hold `lock`.
    private func reportFailureLocked(error: Error) {
        let kind = Self.classify(error)
        guard reportedFailures.insert(kind).inserted else { return }
        Self.internalLog.error(
            "RollingFileLog write failed (\(kind.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)"
        )
    }

    private static func classify(_ error: Error) -> FailureKind {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return .notFound
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            return .permission
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError),
             (NSPOSIXErrorDomain, Int(ENOSPC)):
            return .diskFull
        default:
            return .other
        }
    }
}
