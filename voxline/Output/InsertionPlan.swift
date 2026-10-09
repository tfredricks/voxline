// voxline/Output/InsertionPlan.swift
import Foundation

enum InsertStrategy: String, Equatable, Sendable {
    case accessibility = "ax"
    case paste
    case typing
}

/// Picks the order of insertion strategies for the focused field. Pure.
enum InsertionPlan {

    /// Electron/Chromium apps, browsers, and terminals. AX writes into a web
    /// DOM fire no input events, so React editors drop them; terminals reject
    /// AX writes.
    static let pasteFirstBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "org.whispersystems.signal-desktop",
        "com.microsoft.teams2", "com.microsoft.teams", "notion.id", "md.obsidian",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox",
        "com.apple.Terminal", "com.googlecode.iterm2",
    ]

    /// Terminal emulators. A selection there is scrollback output, not
    /// editable text: neither a paste nor the delete key removes it, and a
    /// Backspace deletes before the shell's cursor instead.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "net.kovidgoyal.kitty", "org.alacritty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
    ]

    static func isTerminal(_ bundleID: String?) -> Bool {
        bundleID.map(terminalBundleIDs.contains) ?? false
    }

    /// Attributes only web content exposes; catches WebKit views inside
    /// native apps, such as Mail compose.
    static let webContentAttributes: Set<String> = ["AXDOMClassList", "AXDOMIdentifier"]

    /// Hidden defaults with no Settings UI.
    struct Overrides: Equatable, Sendable {
        var axFirst: Bool = true
        var extraPasteFirst: Set<String> = []

        /// `false` restores 0.5.0's paste → accessibility → typing order everywhere.
        static let axFirstKey = "voxline.insert.axFirst"
        /// A string array of bundle IDs added to the built-in paste-first list.
        static let pasteFirstExtraKey = "voxline.insert.pasteFirstExtra"

        /// An absent `axFirst` reads as `true`.
        static func load(from defaults: UserDefaults) -> Overrides {
            Overrides(
                axFirst: defaults.object(forKey: axFirstKey) == nil ? true : defaults.bool(forKey: axFirstKey),
                extraPasteFirst: Set(defaults.stringArray(forKey: pasteFirstExtraKey) ?? [])
            )
        }
    }

    struct Traits: Equatable, Sendable {
        var bundleID: String?
        var attributeNames: [String]
        var selectedTextSettable: Bool
    }

    static func strategies(for traits: Traits, overrides: Overrides = Overrides()) -> [InsertStrategy] {
        guard overrides.axFirst else { return [.paste, .accessibility, .typing] }
        if isPasteFirst(traits, overrides: overrides) { return [.paste, .typing] }
        return [.accessibility, .paste, .typing]
    }

    private static func isPasteFirst(_ traits: Traits, overrides: Overrides) -> Bool {
        if let bundleID = traits.bundleID,
           pasteFirstBundleIDs.contains(bundleID) || overrides.extraPasteFirst.contains(bundleID) {
            return true
        }
        if !webContentAttributes.isDisjoint(with: traits.attributeNames) { return true }
        return !traits.selectedTextSettable
    }
}
