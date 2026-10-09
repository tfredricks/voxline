// voxline/Util/UTF16Range.swift
import CoreFoundation
import Foundation

/// A range in NSString UTF-16 units, 1:1 with the CFRange that AX exchanges.
struct UTF16Range: Equatable, Hashable, Sendable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) { self.location = location; self.length = length }
    init(_ range: CFRange) { self.init(location: range.location, length: range.length) }
    init(_ range: NSRange) { self.init(location: range.location, length: range.length) }

    /// `location + length`. Traps on overflow, so check a range from AX with
    /// `fits(in:)` before using it.
    var end: Int { location + length }
    var cfRange: CFRange { CFRange(location: location, length: length) }
    var nsRange: NSRange { NSRange(location: location, length: length) }

    /// True when the range lies inside a value of `total` units. Never traps,
    /// so hostile AX answers such as `{NSNotFound, 1}` are safe to test.
    func fits(in total: Int) -> Bool {
        location >= 0 && length >= 0 && location <= total && length <= total - location
    }
}
