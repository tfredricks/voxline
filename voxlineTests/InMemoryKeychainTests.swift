import Testing
import Foundation
@testable import voxline

@Suite struct InMemoryKeychainTests {

    @Test func set_then_get_returns_stored_value() throws {
        let kc = InMemoryKeychain()
        try kc.set("sk-test", forKey: KeychainAccount.anthropic)
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-test")
    }

    @Test func get_unset_key_returns_nil() throws {
        let kc = InMemoryKeychain()
        #expect(try kc.string(forKey: "missing") == nil)
    }

    @Test func set_overwrites_existing_value() throws {
        let kc = InMemoryKeychain()
        try kc.set("v1", forKey: KeychainAccount.anthropic)
        try kc.set("v2", forKey: KeychainAccount.anthropic)
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "v2")
    }

    @Test func delete_removes_value() throws {
        let kc = InMemoryKeychain()
        try kc.set("v", forKey: KeychainAccount.openai)
        try kc.delete(forKey: KeychainAccount.openai)
        #expect(try kc.string(forKey: KeychainAccount.openai) == nil)
    }

    @Test func delete_unset_key_does_not_throw() throws {
        let kc = InMemoryKeychain()
        try kc.delete(forKey: "missing")
    }

    @Test func different_accounts_are_isolated() throws {
        let kc = InMemoryKeychain()
        try kc.set("a", forKey: KeychainAccount.anthropic)
        try kc.set("o", forKey: KeychainAccount.openai)
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "a")
        #expect(try kc.string(forKey: KeychainAccount.openai) == "o")
    }

    @Test func seed_initializer_preloads_values() throws {
        let kc = InMemoryKeychain(seed: [KeychainAccount.openai: "sk-seed"])
        #expect(try kc.string(forKey: KeychainAccount.openai) == "sk-seed")
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == nil)
    }
}
