// voxline/Output/PasteboardSnapshot.swift
import AppKit

/// In-memory snapshot of every data-bearing pasteboard type, per item.
/// Promised/lazy types are not captured (see spec §7.1).
struct PasteboardSnapshot: Equatable {

    struct ItemSnapshot: Equatable {
        /// type → raw data. Order preserved from the source item.
        let typedData: [NSPasteboard.PasteboardType: Data]
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
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            // An item with zero concrete types is a promised/dynamic-only
            // item; if the WHOLE board is like this, we'd silently destroy
            // the user's clipboard. Track for the all-promised guard below.
            captured.append(ItemSnapshot(typedData: dict))
        }

        if !captured.isEmpty && captured.allSatisfy({ $0.typedData.isEmpty }) {
            throw SnapshotError.refuseToClobber(reason: "all items contain only promised/owner-served types")
        }

        return PasteboardSnapshot(items: captured)
    }

    /// Replaces `pasteboard`'s contents with the snapshot. Caller is
    /// expected to have cleared the pasteboard already, or accept that
    /// the previous contents remain alongside.
    func restore(to pasteboard: NSPasteboard) {
        var pbItems: [NSPasteboardItem] = []
        for snap in items {
            let pbItem = NSPasteboardItem()
            for (type, data) in snap.typedData {
                pbItem.setData(data, forType: type)
            }
            pbItems.append(pbItem)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)
    }
}
