import Foundation
import FoundationModels

/// ``LiveAnalyst`` on Apple Foundation Models — the production engine
/// (docs/live-intelligence.md D1): zero setup, runs on the **Neural Engine**
/// (live ML stays off the GPU), and `@Generable` guided generation means the
/// output always parses, even from a ~3B model.
///
/// Each fold pass is a fresh, single-turn session: the fold *is* the memory
/// (the previous brief rides in the prompt), so there is nothing for a session
/// transcript to add except token pressure against the 4096 window.
///
/// Coverage-excluded like every hardware/system adapter — the logic worth
/// testing (cadence, diff, prompt) lives upstream in the pure core.
public struct FoundationModelsAnalystAdapter: LiveAnalyst {
    public init() {}

    public func fold(
        _ brief: LiveBrief,
        delta: String,
        dismissed: [String]
    ) async throws -> LiveBrief {
        if case let .unavailable(reason) = SystemLanguageModel.default.availability {
            throw LiveAnalystError.modelUnavailable(String(describing: reason))
        }
        let session = LanguageModelSession(instructions: LiveBriefPrompt.instructions)
        let response = try await session.respond(
            to: LiveBriefPrompt.prompt(brief: brief, delta: delta, dismissed: dismissed),
            generating: GeneratedBrief.self
        )
        return response.content.brief
    }
}

/// Why a fold pass could not run at all (generation errors from the framework
/// propagate as-is).
public enum LiveAnalystError: Error, CustomStringConvertible {
    /// Apple Intelligence is off, unsupported, or the model is still
    /// downloading — the brief simply stays empty. Carries the framework's
    /// reason so the skip is diagnosable.
    case modelUnavailable(String)

    public var description: String {
        switch self {
        case let .modelUnavailable(reason):
            "Apple Intelligence model unavailable: \(reason)"
        }
    }
}

/// The constrained-decoding mirror of ``LiveBrief``. Kept lean on purpose: the
/// schema itself costs context tokens on every pass (DESIGN.md §8.1), so no
/// timestamps, ids, or pins here — those are mechanical, layered on by the
/// diff (``BriefDiff``).
@Generable
private struct GeneratedBrief {
    @Generable
    struct Item {
        @Guide(description: "The item itself, one short sentence.")
        var text: String
        @Guide(description: "Who said or owns it, only when the transcript makes it clear.")
        var speaker: String?
        @Guide(description: "True once it has been answered or done.")
        var resolved: Bool
    }

    @Guide(description: "Concrete action items that were agreed, with owner.")
    var nextSteps: [Item]
    @Guide(description: "Questions raised but not yet answered; mark answered ones resolved.")
    var openQuestions: [Item]
    @Guide(description: "At most three short questions worth asking next.")
    var suggestedQuestions: [Item]

    var brief: LiveBrief {
        LiveBrief(
            nextSteps: nextSteps.map(\.item),
            openQuestions: openQuestions.map(\.item),
            suggestedQuestions: suggestedQuestions.map(\.item)
        )
    }
}

extension GeneratedBrief.Item {
    var item: LiveBrief.Item {
        LiveBrief.Item(text: text, speaker: speaker, resolved: resolved)
    }
}
