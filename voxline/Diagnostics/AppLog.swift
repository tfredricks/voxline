import Foundation
import OSLog

/// Thin shim that fans out a single log call to both Apple's unified
/// logging (Console.app, `log stream`) and the on-disk `RollingFileLog`.
/// `debug` is OSLog-only and never reaches disk — it exists for verbose
/// development output that would otherwise burn the 250-entry file cap.
struct CategoryLog {

    let category: String
    private let osLogger: Logger
    private let file: RollingFileLog

    init(category: String, file: RollingFileLog) {
        self.category = category
        self.osLogger = Logger(subsystem: AppLog.subsystem, category: category)
        self.file = file
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        file.info(message, category: category)
    }

    func notice(_ message: String) {
        osLogger.notice("\(message, privacy: .public)")
        file.notice(message, category: category)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        file.error(message, category: category)
    }

    func fault(_ message: String) {
        osLogger.fault("\(message, privacy: .public)")
        file.fault(message, category: category)
    }
}

enum AppLog {
    static let subsystem = "com.voxline.app"

    /// Lazy singleton. Resolves the file URL at first access. If
    /// `AppPaths.applicationSupportDirectory()` throws (extremely
    /// unlikely — it creates the directory), falls back to a path under
    /// the temp directory so the OSLog sink keeps working and disk
    /// writes silently fail (per `RollingFileLog`'s never-throw rule).
    static let fileLog: RollingFileLog = {
        let url: URL
        if let supportDir = try? AppPaths.applicationSupportDirectory() {
            url = supportDir.appending(path: "voxline.log")
        } else {
            url = FileManager.default.temporaryDirectory
                .appending(path: "voxline.log")
        }
        return RollingFileLog(fileURL: url)
    }()

    static let pipeline    = CategoryLog(category: "pipeline",    file: fileLog)
    static let hotkey      = CategoryLog(category: "hotkey",      file: fileLog)
    static let audio       = CategoryLog(category: "audio",       file: fileLog)
    static let whisper     = CategoryLog(category: "whisper",     file: fileLog)
    static let llm         = CategoryLog(category: "llm",         file: fileLog)
    static let paste       = CategoryLog(category: "paste",       file: fileLog)
    static let context     = CategoryLog(category: "context",     file: fileLog)
    static let permissions = CategoryLog(category: "permissions", file: fileLog)

    static let pipelineSignposter = OSSignposter(subsystem: subsystem, category: "pipeline")
}
