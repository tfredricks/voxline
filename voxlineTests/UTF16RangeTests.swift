// voxlineTests/UTF16RangeTests.swift
import CoreFoundation
import Foundation
import Testing
@testable import voxline

@Suite struct UTF16RangeTests {

    @Test func init_from_cf_range() {
        let range = UTF16Range(CFRange(location: 5, length: 3))
        #expect(range.location == 5)
        #expect(range.length == 3)
        #expect(range.end == 8)
    }

    @Test func init_from_ns_range() {
        let range = UTF16Range(NSRange(location: 2, length: 4))
        #expect(range == UTF16Range(location: 2, length: 4))
    }

    @Test func cf_and_ns_ranges_round_trip() {
        let range = UTF16Range(location: 7, length: 11)
        #expect(UTF16Range(range.cfRange) == range)
        #expect(UTF16Range(range.nsRange) == range)
        #expect(range.cfRange.location == 7 && range.cfRange.length == 11)
        #expect(range.nsRange == NSRange(location: 7, length: 11))
    }

    @Test func fits_inside_value_length() {
        #expect(UTF16Range(location: 0, length: 10).fits(in: 10))
        #expect(UTF16Range(location: 10, length: 0).fits(in: 10))
        #expect(!UTF16Range(location: 8, length: 3).fits(in: 10))
        #expect(!UTF16Range(location: -1, length: 2).fits(in: 10))
        #expect(!UTF16Range(location: 2, length: -1).fits(in: 10))
    }

    @Test func fits_rejects_overflowing_ranges_without_trapping() {
        #expect(!UTF16Range(location: Int.max, length: 1).fits(in: 10))
        #expect(!UTF16Range(location: 5, length: Int.max).fits(in: 10))
        #expect(!UTF16Range(location: NSNotFound, length: 1).fits(in: 10))
        #expect(!UTF16Range(location: 11, length: 0).fits(in: 10))
        #expect(!UTF16Range(location: 0, length: 0).fits(in: -1))
    }

    @Test func units_are_utf16_not_characters() {
        let value = "a👍b" as NSString
        #expect(value.length == 4)
        #expect(UTF16Range(location: 1, length: 2).fits(in: value.length))
        #expect(value.substring(with: UTF16Range(location: 1, length: 2).nsRange) == "👍")
    }
}
