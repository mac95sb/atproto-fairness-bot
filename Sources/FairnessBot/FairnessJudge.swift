import Foundation

/// Asks an OpenAI-compatible LLM (Chutes by default, but any provider works —
/// see `LLM_BASE_URL`/`LLM_MODEL` in `.env.example`) to judge whether a reply
/// engaged fairly with the point it was responding to, and if not, drafts a
/// short, polite callout.
struct FairnessJudge {
  let config: Config
  var urlSession: URLSession = .shared

  struct Context {
    let targetHandle: String
    let rootText: String?
    let parentText: String?
    let replyAuthorHandle: String
    let replyText: String
  }

  func judge(_ context: Context) async throws -> FairnessVerdict {
    let request = ChatCompletionRequest(
      model: config.llmModel,
      messages: [
        .init(role: "system", content: systemPrompt),
        .init(role: "user", content: userPrompt(for: context)),
      ],
      temperature: 0.2,
    )

    var urlRequest = URLRequest(url: config.llmBaseURL.appending(path: "chat/completions"))
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(config.llmAPIKey)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = try JSONEncoder().encode(request)

    let (data, response) = try await urlSession.data(for: urlRequest)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw FairnessJudgeError.requestFailed(status: http.statusCode)
    }

    let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    guard let content = completion.choices.first?.message.content else {
      throw FairnessJudgeError.emptyResponse
    }
    return try Self.parseVerdict(from: content)
  }

  /// Models sometimes wrap JSON in prose or a markdown code fence despite
  /// instructions not to; fall back to extracting the outermost `{...}`.
  static func parseVerdict(from content: String) throws -> FairnessVerdict {
    let decoder = JSONDecoder()
    if let data = content.data(using: .utf8),
      let verdict = try? decoder.decode(FairnessVerdict.self, from: data)
    {
      return verdict
    }

    guard let start = content.firstIndex(of: "{"),
      let end = content.lastIndex(of: "}"),
      start < end
    else {
      throw FairnessJudgeError.unparsableVerdict(content)
    }

    let jsonSubstring = String(content[start...end])
    guard let data = jsonSubstring.data(using: .utf8),
      let verdict = try? decoder.decode(FairnessVerdict.self, from: data)
    else {
      throw FairnessJudgeError.unparsableVerdict(content)
    }
    return verdict
  }

  private var systemPrompt: String {
    """
    You are a fairness referee for reply threads on Bluesky. You'll see the \
    original post, the message it's a reply to, and a NEW reply someone just \
    posted. Judge only the NEW reply.

    A reply is FAIR if it engages with the actual substance using evidence, \
    sound reasoning, or a genuine counter-argument — even if blunt or strongly \
    worded. A reply is UNFAIR if it relies on insults or personal attacks \
    instead of argument, uses sarcasm or mockery in place of substance, \
    misrepresents or strawmans what was actually said, ignores the point \
    entirely, or asserts claims with no evidence/reasoning where some would \
    be expected.

    Respond with ONLY a single JSON object, no markdown fences, no commentary, \
    exactly this shape:
    {"fair": true|false, "reasoning": "one or two sentences why", "reply": null|"string"}

    If fair, set "reply" to null — do nothing further.

    If unfair, set "reply" to a short reply (2-4 sentences, no hashtags, at \
    most 300 Unicode characters). Do not start with a name, handle, label, or \
    signature (for example, "\(config.botDisplayName):"). Politely name what \
    specifically was unfair about the reply, without being harsh or superior \
    yourself, and — if it fits naturally — give a brief concrete example of \
    what a fair, evidence-based version of the same point could have looked \
    like. Model the fairness you're asking for; never use insults, sarcasm, \
    or a condescending tone.
    """
  }

  private func userPrompt(for context: Context) -> String {
    """
    Original post (root of the thread):
    \(context.rootText ?? "(not available)")

    Message from @\(context.targetHandle) that the new reply is responding to:
    \(context.parentText ?? "(not available)")

    New reply, posted by @\(context.replyAuthorHandle):
    \(context.replyText)
    """
  }
}

enum FairnessJudgeError: Error, CustomStringConvertible {
  case requestFailed(status: Int)
  case emptyResponse
  case unparsableVerdict(String)

  var description: String {
    switch self {
    case .requestFailed(let status):
      "LLM request failed with status \(status)"
    case .emptyResponse:
      "LLM response had no message content"
    case .unparsableVerdict(let content):
      "Could not parse a fairness verdict from model output: \(content)"
    }
  }
}
