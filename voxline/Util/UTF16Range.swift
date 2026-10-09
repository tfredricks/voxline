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

    var end: Int { location + length }
    var cfRange: CFRange { CFRange(location: location, length: length) }
    var nsRange: NSRange { NSRange(location: location, length: length) }

    /// True when the range lies inside a value of `length` units.
    func fits(in length: Int) -> Bool { location >= 0 && self.length >= 0 && end <= length }
}
