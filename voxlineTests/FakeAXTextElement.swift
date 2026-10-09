// voxlineTests/FakeAXTextElement.swift
import ApplicationServices
@testable import voxline

/// Scripted AXTextElement. Attribute reads come from dictionaries; `strings`
/// entries may be queues so a value can change between reads.
final class FakeAXTextElement: AXTextElement, @unchecked Sendable {
    let ref: AXElementRef
    var strings: [String: [AXRead<String>]] = [:]
    var ranges: [String: AXRead<UTF16Range>] = [:]
    var names: AXRead<[String]> = .value([])
    var settable: [String: AXRead<Bool>] = [:]
    var setResults: [AXError] = []
    private(set) var stringSets: [(attribute: String, value: String, timeout: Float)] = []
    private(set) var rangeSets: [(attribute: String, value: UTF16Range, timeout: Float)] = []
    private(set) var reads: [String] = []

    init(pid: pid_t = 4242) { ref = AXElementRef(element: AXUIElementCreateApplication(pid)) }

    func setValue(_ s: String) { strings[kAXValueAttribute] = [.value(s)] }

    func string(_ attribute: String) -> AXRead<String> {
        reads.append(attribute)
        guard var queue = strings[attribute], let head = queue.first else { return .absent }
        if queue.count > 1 {
            queue.removeFirst()
            strings[attribute] = queue
        }
        return head
    }

    func range(_ attribute: String) -> AXRead<UTF16Range> { ranges[attribute] ?? .absent }

    func attributeNames() -> AXRead<[String]> { names }

    func isSettable(_ attribute: String) -> AXRead<Bool> { settable[attribute] ?? .value(false) }

    func set(_ attribute: String, string: String, timeout: Float) -> AXError {
        stringSets.append((attribute, string, timeout))
        return popSetResult()
    }

    func set(_ attribute: String, range: UTF16Range, timeout: Float) -> AXError {
        rangeSets.append((attribute, range, timeout))
        return popSetResult()
    }

    private func popSetResult() -> AXError {
        setResults.isEmpty ? .success : setResults.removeFirst()
    }
}
