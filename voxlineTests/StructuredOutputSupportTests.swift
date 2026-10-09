import Foundation
import Testing
@testable import voxline

@Suite struct StructuredOutputSupportTests {

    @Test func a_fresh_instance_rejects_nothing() {
        let support = StructuredOutputSupport()
        #expect(!support.rejects("claude-haiku-4-5"))
        #expect(!support.rejects("gpt-4.1-nano"))
    }

    @Test func marking_a_model_makes_it_rejected_and_only_that_model() {
        let support = StructuredOutputSupport()
        support.markRejected("gpt-3.5-turbo")
        #expect(support.rejects("gpt-3.5-turbo"))
        #expect(!support.rejects("gpt-4.1-nano"))
    }

    @Test func marking_twice_is_harmless() {
        let support = StructuredOutputSupport()
        support.markRejected("m")
        support.markRejected("m")
        #expect(support.rejects("m"))
    }

    @Test func instances_do_not_share_state() {
        let a = StructuredOutputSupport()
        let b = StructuredOutputSupport()
        a.markRejected("m")
        #expect(!b.rejects("m"))
    }

    @Test func rejection_is_a_400_naming_json_schema() {
        #expect(StructuredOutputSupport.isStructuredOutputRejection(.badStatus(code: 400, body: "json_schema is not supported")))
    }

    @Test func rejection_is_a_400_naming_output_config_or_response_format_in_any_case() {
        #expect(StructuredOutputSupport.isStructuredOutputRejection(.badStatus(code: 400, body: #"{"error":{"message":"Output_Config.format: Extra inputs are not permitted"}}"#)))
        #expect(StructuredOutputSupport.isStructuredOutputRejection(.badStatus(code: 400, body: "Invalid parameter: 'RESPONSE_FORMAT'")))
    }

    @Test func a_400_about_something_else_is_not_a_rejection() {
        #expect(!StructuredOutputSupport.isStructuredOutputRejection(.badStatus(code: 400, body: "model not found")))
    }

    @Test func a_500_naming_output_config_is_not_a_rejection() {
        #expect(!StructuredOutputSupport.isStructuredOutputRejection(.badStatus(code: 500, body: "output_config")))
    }

    @Test func other_errors_are_not_rejections() {
        for error: LLMError in [.invalidAPIKey, .rateLimited, .truncated, .refused, .missingAPIKey,
                                .badResponseShape(reason: "json_schema"), .network(URLError(.timedOut))] {
            #expect(!StructuredOutputSupport.isStructuredOutputRejection(error), "\(error)")
        }
    }
}
