import Foundation
import Testing

@testable import PlumeKit

@Suite("Ollama error decoding")
struct OllamaErrorTests {
    private func decode(_ json: String) -> OllamaClient.ClientError {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let error = (object as? [String: Any])?["error"] ?? object
        return OllamaClient.decodeError(error, fallback: json)
    }

    @Test("context overflow decodes with its token counts")
    func contextExceeded() {
        // Captured verbatim from Ollama 0.32.9. The counts are what let the
        // summarizer switch to chunking instead of guessing at a budget.
        let error = decode("""
            {"error":{"code":400,
              "message":"request (6626 tokens) exceeds the available context size (2048 tokens)",
              "type":"exceed_context_size_error","n_prompt_tokens":6626,"n_ctx":2048}}
            """)
        #expect(error == .contextExceeded(promptTokens: 6626, contextTokens: 2048))
    }

    @Test("a missing model is distinguished from a generic failure")
    func modelMissing() {
        // Different remedy: `ollama pull`, not a retry.
        if case .modelMissing = decode(#"{"error":"model 'gemma9' not found"}"#) {
        } else {
            Issue.record("expected .modelMissing")
        }
    }

    @Test("an unrecognised error still surfaces its message")
    func genericError() {
        let error = decode(#"{"error":{"code":500,"message":"something broke"}}"#)
        #expect(error == .http(status: 500, message: "something broke"))
    }

    @Test("errors describe the remedy, not just the failure")
    func errorsAreActionable() {
        // These strings reach the menu bar, where there is no console to
        // investigate in — so each has to say what to do.
        #expect(OllamaClient.ClientError.unreachable.description.contains("ollama list"))
        #expect(OllamaClient.ClientError.modelMissing("gemma4").description
            .contains("ollama pull"))
    }
}

@Suite("Summary templates")
struct TemplateStoreTests {
    @Test("a template file round-trips through render and parse")
    func roundTrip() {
        let original = TemplateStore.seeds[0]
        let parsed = TemplateStore.parse(TemplateStore.render(original), id: original.id)
        #expect(parsed?.name == original.name)
        #expect(parsed?.prompt == original.prompt)
    }

    @Test("the body after frontmatter is the whole prompt")
    func bodyIsPrompt() {
        let parsed = TemplateStore.parse(
            """
            ---
            name: Custom
            ---

            Summarize tersely.

            Second paragraph survives.
            """, id: "custom")
        #expect(parsed?.name == "Custom")
        #expect(parsed?.prompt.contains("Second paragraph survives") == true)
    }

    @Test("a file without frontmatter still works, using its filename")
    func noFrontmatter() {
        // Dropping a plain .md file into the folder should just work.
        let parsed = TemplateStore.parse("Just the prompt.", id: "bare")
        #expect(parsed?.id == "bare")
        #expect(parsed?.name == "bare")
        #expect(parsed?.prompt == "Just the prompt.")
    }

    @Test("an empty file is rejected rather than becoming an empty prompt")
    func emptyRejected() {
        #expect(TemplateStore.parse("---\nname: Broken\n---\n\n   ", id: "broken") == nil)
    }

    @Test("seeded prompts forbid invention and allow omission")
    func promptsGuardAgainstFabrication() {
        // The transcript can be wrong or thin; a summary that invents decisions
        // is worse than one that says it couldn't summarize.
        for template in TemplateStore.seeds {
            #expect(template.prompt.localizedCaseInsensitiveContains("never invent"))
            #expect(template.prompt.localizedCaseInsensitiveContains("omit"))
        }
    }
}
