import OSLog

enum AppLog {
    static let subsystem = "com.fredricks.voxline"

    static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
    static let hotkey      = Logger(subsystem: subsystem, category: "hotkey")
    static let audio       = Logger(subsystem: subsystem, category: "audio")
    static let whisper     = Logger(subsystem: subsystem, category: "whisper")
    static let llm         = Logger(subsystem: subsystem, category: "llm")
    static let paste       = Logger(subsystem: subsystem, category: "paste")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    static let pipelineSignposter = OSSignposter(subsystem: subsystem, category: "pipeline")
}
