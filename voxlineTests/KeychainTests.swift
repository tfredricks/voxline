import Testing
import Foundation
@testable import voxline

@Suite struct KeychainTests {

    /// Use a per-test service identifier so tests don't trample the real keychain entries.
    private func makeKeychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    @Test func set_then_get_returns_stored_value() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("sk-test-key", forKey: "anthropic")
        #expect(try kc.string(forKey: "anthropic") == "sk-test-key")
    }

    @Test func get_unset_key_returns_nil() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        #expect(try kc.string(forKey: "missing") == nil)
    }

    @Test func set_overwrites_existing_value() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("v1", forKey: "anthropic")
        try kc.set("v2", forKey: "anthropic")
        #expect(try kc.string(forKey: "anthropic") == "v2")
    }

    @Test func delete_removes_value() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("v", forKey: "openai")
        try kc.delete(forKey: "openai")
        #expect(try kc.string(forKey: "openai") == nil)
    }

    @Test func delete_unset_key_does_not_throw() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.delete(forKey: "missing")  // No throw expected.
    }

    @Test func different_keys_in_same_service_are_isolated() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("a-val", forKey: "anthropic")
        try kc.set("o-val", forKey: "openai")
        #expect(try kc.string(forKey: "anthropic") == "a-val")
        #expect(try kc.string(forKey: "openai") == "o-val")
    }
}
