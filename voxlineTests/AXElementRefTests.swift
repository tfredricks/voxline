// voxlineTests/AXElementRefTests.swift
import ApplicationServices
import Testing
@testable import voxline

@Suite struct AXElementRefTests {

    @Test func refs_over_equal_elements_are_equal_with_equal_hashes() {
        let a = AXElementRef(element: AXUIElementCreateApplication(1))
        let b = AXElementRef(element: AXUIElementCreateApplication(1))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }

    @Test func refs_over_different_pids_differ() {
        let a = AXElementRef(element: AXUIElementCreateApplication(1))
        let b = AXElementRef(element: AXUIElementCreateApplication(2))
        #expect(a != b)
    }

    @Test func classify_success_with_matching_type_is_value() {
        let read: AXRead<String> = LiveAXTextElement.classify(.success, "hi" as CFString) { $0 as? String }
        #expect(read == .value("hi"))
    }

    @Test func classify_success_with_wrong_type_is_failed() {
        let read: AXRead<String> = LiveAXTextElement.classify(.success, 42 as CFNumber) { $0 as? String }
        #expect(read == .failed)
    }

    @Test func classify_success_without_value_is_failed() {
        let read: AXRead<String> = LiveAXTextElement.classify(.success, nil) { $0 as? String }
        #expect(read == .failed)
    }

    @Test func classify_missing_value_statuses_are_absent() {
        for status: AXError in [.noValue, .attributeUnsupported, .notImplemented] {
            let read: AXRead<String> = LiveAXTextElement.classify(status, nil) { $0 as? String }
            #expect(read == .absent)
        }
    }

    @Test func classify_other_errors_are_failed() {
        for status: AXError in [.cannotComplete, .failure, .apiDisabled, .invalidUIElement, .illegalArgument] {
            let read: AXRead<String> = LiveAXTextElement.classify(status, nil) { $0 as? String }
            #expect(read == .failed)
        }
    }

    @Test func focused_read_without_ax_support_is_absent() {
        for status: AXError in [.noValue, .notImplemented, .attributeUnsupported] {
            #expect(LiveFocusedElementSource.classify(status, nil) == .absent)
        }
    }

    @Test func focused_read_timeouts_and_other_errors_are_failed() {
        for status: AXError in [.cannotComplete, .failure, .apiDisabled, .invalidUIElement, .illegalArgument] {
            #expect(LiveFocusedElementSource.classify(status, nil) == .failed)
        }
    }

    @Test func focused_read_success_needs_an_element() {
        let app = AXUIElementCreateApplication(5)
        #expect(LiveFocusedElementSource.classify(.success, app) == .value(AXElementRef(element: app)))
        #expect(LiveFocusedElementSource.classify(.success, "text" as CFString) == .failed)
        #expect(LiveFocusedElementSource.classify(.success, nil) == .failed)
    }

    @Test func ax_error_log_names() {
        #expect(AXError.notImplemented.logName == "notImplemented")
        #expect(AXError.noValue.logName == "noValue")
        #expect(AXError.cannotComplete.logName == "cannotComplete")
        #expect(AXError.attributeUnsupported.logName == "attributeUnsupported")
    }

    @Test func ax_read_accessors() {
        #expect(AXRead<Int>.value(3).value == 3)
        #expect(AXRead<Int>.absent.value == nil)
        #expect(AXRead<Int>.failed.value == nil)
        #expect(AXRead<Int>.failed.isFailed)
        #expect(!AXRead<Int>.absent.isFailed)
        #expect(!AXRead<Int>.value(0).isFailed)
    }

    @Test func range_cast_accepts_only_cf_range_ax_values() {
        var cf = CFRange(location: 4, length: 2)
        let rangeValue = AXValueCreate(.cfRange, &cf)!
        #expect(LiveAXTextElement.rangeValue(rangeValue) == UTF16Range(location: 4, length: 2))

        var point = CGPoint(x: 1, y: 2)
        let pointValue = AXValueCreate(.cgPoint, &point)!
        #expect(LiveAXTextElement.rangeValue(pointValue) == nil)
        #expect(LiveAXTextElement.rangeValue("text" as CFString) == nil)
    }

    @Test func live_element_ref_matches_its_element() {
        let element = AXUIElementCreateApplication(3)
        #expect(LiveAXTextElement(element: element).ref == AXElementRef(element: AXUIElementCreateApplication(3)))
    }

    @Test func fake_string_queue_repeats_last_value_and_records_reads() {
        let fake = FakeAXTextElement()
        fake.strings[kAXValueAttribute] = [.value("a"), .failed, .value("b")]
        #expect(fake.string(kAXValueAttribute) == .value("a"))
        #expect(fake.string(kAXValueAttribute) == .failed)
        #expect(fake.string(kAXValueAttribute) == .value("b"))
        #expect(fake.string(kAXValueAttribute) == .value("b"))
        #expect(fake.string(kAXSubroleAttribute) == .absent)
        #expect(fake.reads == [kAXValueAttribute, kAXValueAttribute, kAXValueAttribute, kAXValueAttribute, kAXSubroleAttribute])
    }

    @Test func fake_set_value_replaces_queue() {
        let fake = FakeAXTextElement()
        fake.strings[kAXValueAttribute] = [.value("a"), .value("b")]
        fake.setValue("z")
        #expect(fake.string(kAXValueAttribute) == .value("z"))
    }

    @Test func fake_sets_record_and_pop_results() {
        let fake = FakeAXTextElement()
        fake.setResults = [.cannotComplete]
        #expect(fake.set(kAXSelectedTextAttribute, string: "x", timeout: 1.5) == .cannotComplete)
        #expect(fake.set(kAXSelectedTextRangeAttribute, range: UTF16Range(location: 1, length: 0), timeout: 0.5) == .success)
        #expect(fake.stringSets.count == 1)
        #expect(fake.stringSets.first?.attribute == kAXSelectedTextAttribute)
        #expect(fake.stringSets.first?.value == "x")
        #expect(fake.stringSets.first?.timeout == 1.5)
        #expect(fake.rangeSets.first?.value == UTF16Range(location: 1, length: 0))
    }

    @Test func fake_defaults() {
        let fake = FakeAXTextElement(pid: 7)
        #expect(fake.ref == AXElementRef(element: AXUIElementCreateApplication(7)))
        #expect(fake.isSettable(kAXValueAttribute) == .value(false))
        #expect(fake.range(kAXSelectedTextRangeAttribute) == .absent)
        #expect(fake.attributeNames() == .value([]))
    }
}
