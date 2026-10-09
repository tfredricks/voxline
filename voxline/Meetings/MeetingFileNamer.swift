import Foundation

enum MeetingFileNamer {

    static let maxTitleLength = 80

    private static let disallowed = CharacterSet(charactersIn: "/:\\")
        .union(.controlCharacters)
        .union(.newlines)

    static func sanitize(_ title: String) -> String {
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.compactMap { scalar in
            if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) { return nil }
            return disallowed.contains(scalar) ? "-" : scalar
        }))
        let trimmed = String(replaced.trimmingCharacters(in: .whitespaces).prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.whitespaces)).isEmpty
            ? "Meeting"
            : trimmed
    }

    static func fileName(startedAt: Date, title: String, suffix: String? = nil, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let base = "\(formatter.string(from: startedAt)) \(sanitize(title))"
        return suffix.map { "\(base) (\($0)).md" } ?? "\(base).md"
    }

    static func uniqueURL(in folder: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let first = folder.appending(path: fileName)
        guard exists(first) else { return first }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var n = 2
        while true {
            let candidate = folder.appending(path: "\(stem) (\(n)).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
