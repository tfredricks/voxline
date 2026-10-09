import Foundation

enum CommandAction: String, Codable, CaseIterable, Equatable, Sendable {
    case replaceSelection = "replace_selection"
    case insert
    case rewrite

    /// The spec's allowed-actions table.
    static func allowed(fieldReadable: Bool, hasSelection: Bool, isPreset: Bool) -> [CommandAction] {
        if isPreset { return [.replaceSelection] }
        switch (fieldReadable, hasSelection) {
        case (true, true):   return [.replaceSelection, .insert]
        case (true, false):  return [.insert, .rewrite]
        case (false, true):  return [.replaceSelection, .insert]
        case (false, false): return [.insert]
        }
    }
}

struct CommandRequest: Equatable, Sendable {
    var instruction: String
    var context: EditContext
    var actions: [CommandAction]
    var vocabulary: [String]
    var model: String
    var includesField: Bool
}

struct CommandResult: Equatable, Sendable {
    var action: CommandAction
    var text: String

    static let schemaJSON = """
    {"type":"object","additionalProperties":false,"required":["action","text"],"properties":{"action":{"type":"string","enum":["replace_selection","insert","rewrite"]},"text":{"type":"string"}}}
    """
}
