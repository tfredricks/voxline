// voxline/Output/PasteboardSnapshot.swift
import AppKit

/// In-memory snapshot of every data-bearing pasteboard type, per item.
/// A promised type is captured by asking its owner for the data at capture
/// time; a type that yields no data is left out.
struct PasteboardSnapshot: Equatable {

    struct Entry: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    struct ItemSnapshot: Equatable {
        /// Source order, restored in the same order (issue 17).
        let entries: [Entry]

        func data(forType type: NSPasteboard.PasteboardType) -> Data? {
            entries.first { $0.type == type }?.data
        }
    }

    enum SnapshotError: Error, Equatable {
        case refuseToClobber(reason: String)

        var reason: String {
            switch self {
            case .refuseToClobber(let reason): return reason
            }
        }
    }

    let items: [ItemSnapshot]

    static func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
        guard let pbItems = pasteboard.pasteboardItems else {
            throw SnapshotError.refuseToClobber(reason: "pasteboardItems was nil")
        }

        var captured: [ItemSnapshot] = []
        for item in pbItems {
            var entries: [Entry] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append(Entry(type: type, data: data))
                }
            }
            // An item with zero concrete types is a promised/dynamic-only
            // item; if the WHOLE board is like this, we'd silently destroy
            // the user's clipboard. Track for the all-promised guard below.
            captured.append(ItemSnapshot(entries: entries))
        }

        if !captured.isEmpty && captured.allSatisfy({ $0.entries.isEmpty }) {
            throw SnapshotError.refuseToClobber(reason: "all items contain only promised/owner-served types")
        }

        return PasteboardSnapshot(items: captured)
    }

    /// Replaces `pasteboard`'s contents with the snapshot: clears the board,
    /// then writes one item per captured item, its types in source order.
    func restore(to pasteboard: NSPasteboard) {
        var pbItems: [NSPasteboardItem] = []
        for snap in items {
            let pbItem = NSPasteboardItem()
            for entry in snap.entries {
                pbItem.setData(entry.data, forType: entry.type)
            }
            pbItems.append(pbItem)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)
    }
}
