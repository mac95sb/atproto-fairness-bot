import Foundation

// MARK: - Chat completions request (OpenAI-compatible; works with Chutes or any other provider)

/// A request body for an OpenAI-compatible `chat/completions` endpoint.
struct ChatCompletionRequest: Encodable {
  let model: String
  let messages: [Message]
  let temperature: Double

  /// A single turn in the conversation sent to the model.
  struct Message: Encodable {
    let role: String
    let content: String
  }
}

/// A response from an OpenAI-compatible `chat/completions` endpoint.
struct ChatCompletionResponse: Decodable {
  let choices: [Choice]

  /// One candidate completion returned by the model.
  struct Choice: Decodable {
    let message: Message

    /// The message content of a single completion choice.
    struct Message: Decodable {
      let content: String
    }
  }
}

/// The structured verdict the model is prompted to return as its message content (JSON text).
struct FairnessVerdict: Decodable {
  /// Whether the judged reply is a debate response at all, as opposed to
  /// general conversation. General conversation never receives a fairness
  /// score, regardless of tone.
  let isDebate: Bool
  /// Tone, 0-100: insults, sarcasm, or mockery in place of argument score low.
  let rhetoric: Int?
  /// Engagement with the actual point, 0-100: a strawman or a different point scores low.
  let relevance: Int?
  /// Support for the reply's claims, 0-100: an unsupported assertion scores low.
  let evidence: Int?
  /// The judge's explanation for its scores, or for why the reply isn't a debate response.
  let reasoning: String
  /// A drafted callout reply, present only when the reply is unfair.
  let reply: String?

  /// The gate score is the weakest of the three axes, not their average — a
  /// reply that's mostly substantive but has one severely unfair aside
  /// should still gate on that aside rather than have it averaged away.
  var score: Int? {
    guard let rhetoric, let relevance, let evidence else { return nil }
    return min(rhetoric, relevance, evidence)
  }

  /// Whether this verdict clears the given publication threshold.
  ///
  /// No callout is warranted for general conversation (`isDebate == false`)
  /// — only actual pushback/disagreement gets a fairness judgment at all.
  ///
  /// - Parameter threshold: The minimum gate score (0-100) required to count as fair.
  /// - Returns: `true` when the reply is not a debate response, or when its gate score
  ///   meets or exceeds `threshold`.
  func isFair(threshold: Int) -> Bool {
    guard isDebate, let score else { return true }
    return score >= threshold
  }
}

/// A second model's review of an unfair verdict and its drafted reply.
///
/// `isVerdictSupported` and `isApproved` are independent judgments: a reviewer
/// can disagree that the original reply was unfair at all
/// (`isVerdictSupported == false`), or agree it was unfair but still withhold
/// approval of this specific candidate text
/// (`isVerdictSupported == true, isApproved == false`).
struct ReviewVerdict: Decodable {
  let isVerdictSupported: Bool
  let isApproved: Bool
  /// The reviewer's one-sentence explanation for its judgment.
  let reasoning: String
  /// The reviewer's minimally edited reply, present only when both
  /// `isVerdictSupported` and `isApproved` are `true`.
  let reply: String?

  enum CodingKeys: String, CodingKey {
    case isVerdictSupported = "verdictSupported"
    case isApproved = "approved"
    case reasoning, reply
  }
}
