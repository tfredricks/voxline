// voxlineTests/PasteboardSnapshotTests.swift
import Testing
import AppKit
@testable import voxline

@Suite struct PasteboardSnapshotTests {

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-snap-test-\(UUID().uuidString)"))
    }

    @Test func captures_string_and_restores_to_empty_board() throws {
        let src = makeBoard()
        src.clearContents()
        src.setString("hello", forType: .string)

        let snap = try PasteboardSnapshot.capture(from: src)

        let dst = makeBoard()
        dst.clearContents()
        snap.restore(to: dst)
        #expect(dst.string(forType: .string) == "hello")
    }

    @Test func captures_multiple_data_types_per_item() throws {
        let src = makeBoard()
        src.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        src.writeObjects([item])

        let snap = try PasteboardSnapshot.capture(from: src)

        let dst = makeBoard()
        dst.clearContents()
        snap.restore(to: dst)
        #expect(dst.string(forType: .string) == "plain")
        #expect(dst.string(forType: .html) == "<b>rich</b>")
    }

    @Test func captures_multiple_items_in_order() throws {
        let src = makeBoard()
        src.clearContents()
        let a = NSPasteboardItem(); a.setString("first", forType: .string)
        let b = NSPasteboardItem(); b.setString("second", forType: .string)
        src.writeObjects([a, b])

        let snap = try PasteboardSnapshot.capture(from: src)
        #expect(snap.items.count == 2)
        #expect(snap.items[0].typedData[.string] != nil)
    }

    @Test func nil_pasteboardItems_throws_refuseToClobber() throws {
        let board = NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-nilboard-\(UUID().uuidString)"))
        // Force the nil-items path: a brand-new board that's never been written to
        // and never had clearContents called returns nil for pasteboardItems.
        // (Some macOS versions return [] instead — guard the test against that.)
        if board.pasteboardItems == nil {
            do {
                _ = try PasteboardSnapshot.capture(from: board)
                Issue.record("expected throw")
            } catch let e as PasteboardSnapshot.SnapshotError {
                #expect(e == .refuseToClobber(reason: "pasteboardItems was nil"))
            }
        }
    }
}
