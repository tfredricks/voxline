import Cocoa
import CoreGraphics

// Minimal sandboxed CGEventTap test.
// Goal: confirm we can observe flagsChanged events from a sandboxed binary
// on the current Xcode/macOS combo. Prints any flagsChanged event seen.
// Run for ~10 seconds, then exits.

let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        let flags = event.flags
        FileHandle.standardOutput.write(Data("flagsChanged: \(flags.rawValue)\n".utf8))
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    FileHandle.standardError.write(Data("FAIL: CGEvent.tapCreate returned nil (likely missing Accessibility permission for this binary, or sandbox blocking)\n".utf8))
    exit(2)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

FileHandle.standardOutput.write(Data("OK: tap created, watching flagsChanged for 10s. Press/release modifiers now.\n".utf8))

// Run for 10 seconds.
let deadline = Date().addingTimeInterval(10)
while Date() < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.5, false)
}

FileHandle.standardOutput.write(Data("DONE\n".utf8))
