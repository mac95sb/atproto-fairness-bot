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
    let content = try await sendChatCompletion(
      baseURL: config.llmBaseURL, apiKey: config.llmAPIKey, model: config.llmModel,
      messages: [
        .init(role: "system", content: systemPrompt),
        .init(role: "user", content: userPrompt(for: context)),
      ],
      temperature: 0.2,
    )
    return try Self.parseVerdict(from: content)
  }

  /// Returns the reviewer's minimally edited reply, or `nil` when the reviewer
  /// rejects the first model's unfairness finding. With no reviewer configured,
  /// the first model's draft is used unchanged.
  func reviewedReply(for verdict: FairnessVerdict, context: Context) async throws -> String? {
    guard !verdict.isFair(threshold: config.fairnessScoreThreshold),
      let candidateReply = verdict.reply, !candidateReply.isEmpty
    else {
      return nil
    }
    guard let reviewer = config.reviewLLM else { return candidateReply }

    let content = try await sendChatCompletion(
      baseURL: reviewer.baseURL, apiKey: reviewer.apiKey, model: reviewer.model,
      messages: [
        .init(role: "system", content: reviewSystemPrompt),
        .init(
          role: "user",
          content: reviewUserPrompt(for: context, verdict: verdict, candidateReply: candidateReply)),
      ],
      temperature: 0,
    )
    let review = try Self.parseReview(from: content)
    guard review.approved, let reply = review.reply, !reply.isEmpty else { return nil }
    return reply
  }

  private func sendChatCompletion(
    baseURL: URL, apiKey: String, model: String,
    messages: [ChatCompletionRequest.Message], temperature: Double,
  ) async throws -> String {
    let request = ChatCompletionRequest(model: model, messages: messages, temperature: temperature)

    var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = try JSONEncoder().encode(request)

    let (data, response) = try await sendWithRetry(urlRequest)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw FairnessJudgeError.requestFailed(status: http.statusCode)
    }

    let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    guard let content = completion.choices.first?.message.content else {
      throw FairnessJudgeError.emptyResponse
    }
    return content
  }

  /// Retries transient transport failures (timeouts, dropped/unreachable connections)
  /// with short exponential backoff. Non-transient errors — bad HTTP status, decode
  /// failures, or any other `URLError` — are not retried.
  private func sendWithRetry(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
    let retryableCodes: Set<URLError.Code> = [
      .timedOut, .networkConnectionLost, .cannotConnectToHost,
      .notConnectedToInternet, .dnsLookupFailed,
    ]
    var backoff: Duration = .seconds(1)
    var attempt = 0
    while true {
      do {
        return try await urlSession.data(for: urlRequest)
      } catch let error as URLError where retryableCodes.contains(error.code) && attempt < 2 {
        attempt += 1
        try await Task.sleep(for: backoff)
        backoff *= 2
      }
    }
  }

  /// Models sometimes wrap JSON in prose or a markdown code fence despite
  /// instructions not to; fall back to extracting the outermost `{...}`.
  static func parseVerdict(from content: String) throws -> FairnessVerdict {
    try parseJSON(FairnessVerdict.self, from: content)
  }

  static func parseReview(from content: String) throws -> ReviewVerdict {
    try parseJSON(ReviewVerdict.self, from: content)
  }

  private static func parseJSON<Value: Decodable>(_ type: Value.Type, from content: String) throws
    -> Value
  {
    let decoder = JSONDecoder()
    if let data = content.data(using: .utf8),
      let value = try? decoder.decode(Value.self, from: data)
    {
      return value
    }

    guard let start = content.firstIndex(of: "{"),
      let end = content.lastIndex(of: "}"),
      start < end,
      let data = String(content[start...end]).data(using: .utf8),
      let value = try? decoder.decode(Value.self, from: data)
    else {
      throw FairnessJudgeError.unparsableVerdict(content)
    }
    return value
  }

  private var systemPrompt: String {
    """
    You are a fairness referee for reply threads on Bluesky. You'll see the \
    original post, the message it's a reply to, and a NEW reply someone just \
    posted. Judge only the NEW reply.

    First decide whether the NEW reply is actually disagreeing with, pushing \
    back on, or criticizing the point it's responding to — a debate \
    response. General conversation is NOT a debate response: agreement, \
    compliments, jokes, questions, unrelated banter, or other friendly \
    replies don't get a fairness judgment at all, no matter how they're \
    phrased.

    If it is NOT a debate response, set "isDebate" to false, "score" and \
    "reply" to null, and briefly explain why in "reasoning" (for example, \
    "Friendly agreement, not a critical response.").

    If it IS a debate response, set "isDebate" to true and score it from 0 \
    to 100 on how fairly it engaged: 100 means it engaged with the actual \
    substance using evidence, sound reasoning, or a genuine counter-argument \
    — even if blunt or strongly worded. 0 means it relies entirely on \
    insults or personal attacks instead of argument, pure sarcasm or mockery \
    in place of substance, a strawman of what was actually said, or claims \
    asserted with no evidence/reasoning where some would clearly be \
    expected. Score in between for a mix of both.

    Respond with ONLY a single JSON object, no markdown fences, no commentary, \
    exactly this shape:
    {"isDebate": true|false, "score": null|0-100, "reasoning": "one or two sentences why", "reply": null|"string"}

    If "isDebate" is false, or the score is at or above \
    \(config.fairnessScoreThreshold), set "reply" to null — do nothing \
    further.

    If "isDebate" is true and the score is below \
    \(config.fairnessScoreThreshold), set "reply" to a short reply (2-4 \
    sentences, no hashtags). The reply text MUST be under 300 Unicode \
    characters — this is a hard platform limit enforced by Bluesky, not a \
    style target. Before you finalize the JSON, count the characters in \
    your drafted reply; if it is at or over 300, cut content and rewrite it \
    shorter rather than letting it run long. A shorter reply that fits the \
    limit is always better than a longer one that doesn't. Do not start \
    with a name, handle, label, or signature (for example, \
    "\(config.botDisplayName):"). Politely name what specifically was unfair \
    about the reply, without being harsh or superior yourself, and — if it \
    fits naturally — give a brief concrete example of what a fair, \
    evidence-based version of the same point could have looked like. Model \
    the fairness you're asking for; never use insults, sarcasm, or a \
    condescending tone.
    """
  }

  private var reviewSystemPrompt: String {
    """
    You are a cautious reviewer of a proposed Bluesky fairness-bot reply. Return ONLY one JSON object:
    {"approved": true|false, "reasoning": "one sentence", "reply": null|"string"}

    Approve only if the original unfairness finding is supported by the supplied thread and the candidate reply is polite, accurate, and proportionate. If approved, `reply` must contain the candidate with only minimal edits for clarity, factual caution, or tone. Do not introduce a new criticism or alter the conclusion.

    The 300-Unicode-character limit is a hard platform requirement, not optional. Count the characters in the candidate reply: if it is at or over 300, you must shorten it yourself — trim a clause or sentence, tighten wording — so the `reply` you return is under 300 characters. Never pass through a reply that is over the limit, and never produce one that would need to be cut off mid-sentence when posted; a shorter reply that says slightly less is far better than one that overruns. If you cannot bring it under 300 characters while keeping it accurate and proportionate, reject it instead (`approved: false`, `reply: null`).

    If you reject it, set `reply` to null.
    """
  }

  private func reviewUserPrompt(
    for context: Context, verdict: FairnessVerdict, candidateReply: String
  ) -> String {
    """
    Original post (root of the thread):
    \(context.rootText ?? "(not available)")

    Message from @\(context.targetHandle) that the new reply is responding to:
    \(context.parentText ?? "(not available)")

    New reply, posted by @\(context.replyAuthorHandle):
    \(context.replyText)

    First model's unfairness reasoning:
    \(verdict.reasoning)

    Candidate reply:
    \(candidateReply)
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
