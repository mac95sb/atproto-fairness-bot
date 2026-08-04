import Foundation

// MARK: - Chat completions request (OpenAI-compatible; works with Chutes or any other provider)

struct ChatCompletionRequest: Encodable {
  let model: String
  let messages: [Message]
  let temperature: Double

  struct Message: Encodable {
    let role: String
    let content: String
  }
}

struct ChatCompletionResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message

    struct Message: Decodable {
      let content: String
    }
  }
}

/// The structured verdict the model is prompted to return as its message content (JSON text).
struct FairnessVerdict: Decodable {
  let fair: Bool
  let reasoning: String
  let reply: String?
}

/// A second model's approval of an unfair verdict and minimally edited reply.
struct ReviewVerdict: Decodable {
  let approved: Bool
  let reasoning: String
  let reply: String?
}
