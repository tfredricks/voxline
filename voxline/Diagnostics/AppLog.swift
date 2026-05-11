import OSLog

enum AppLog {
    static let subsystem = "com.voxline.app"

    static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
    static let hotkey      = Logger(subsystem: subsystem, category: "hotkey")
    static let audio       = Logger(subsystem: subsystem, category: "audio")
    static let whisper     = Logger(subsystem: subsystem, category: "whisper")
    static let llm         = Logger(subsystem: subsystem, category: "llm")
    static let paste       = Logger(subsystem: subsystem, category: "paste")
    static let context     = Logger(subsystem: subsystem, category: "context")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    #if DEBUG
    /// Dev-only firehose for the full LLM prompt. Gated by `#if DEBUG`, so
    /// the code is stripped from Release builds entirely. Within Debug, it
    /// only fires when the `VOXLINE_TRACE_LLM` env var is set (configure via
    /// the Xcode scheme: Run → Arguments → Environment Variables).
    static let llmTrace    = Logger(subsystem: subsystem, category: "llm-trace")
    #endif

    static let pipelineSignposter = OSSignposter(subsystem: subsystem, category: "pipeline")
}
