import Foundation

/// Asks an OpenAI-compatible LLM (Chutes by default, but any provider works —
/// see `LLM_BASE_URL`/`LLM_MODEL` in `.env.example`) to judge whether a reply
/// engaged fairly with the point it was responding to, and if not, drafts a
/// short, polite callout.
struct FairnessJudge: Sendable {
  let config: Config
  var urlSession: URLSession = .shared

  /// The conversational context a single judgment is made against.
  struct Context {
    /// The handle of whoever authored the message the new reply answers.
    let parentAuthorHandle: String
    /// The text of the root post of the thread, if it could be fetched.
    let rootText: String?
    /// The text of the message the new reply answers, if it could be fetched.
    let parentText: String?
    /// The handle of whoever posted the new reply being judged.
    let replyAuthorHandle: String
    /// The text of the new reply being judged.
    let replyText: String
  }

  /// Asks the primary LLM to judge the reply in `context`.
  ///
  /// - Parameter context: The thread context and reply text to judge.
  /// - Returns: The model's fairness verdict.
  /// - Throws: `FairnessJudgeError` if the request fails or the response can't be parsed.
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

  /// The reviewer's outcome for an already-unfair verdict: it can approve the
  /// candidate reply (with minimal edits), overturn the underlying finding
  /// (it disagrees the reply was unfair at all), or agree the finding holds
  /// but reject this specific candidate text (e.g. tone, proportionality,
  /// length). `nil` from `reviewedReply` means there was nothing to review —
  /// the verdict was already fair, or had no candidate reply — a
  /// precondition, not a reviewer decision.
  enum ReviewOutcome: Equatable {
    /// The reviewer agreed the reply was unfair and approved this text, with only minimal edits.
    case approved(reply: String)
    /// The reviewer disagreed that the original reply was unfair at all.
    case verdictOverturned(reasoning: String)
    /// The reviewer agreed the reply was unfair but withheld approval of this candidate text.
    case replyRejected(reasoning: String)
  }

  /// Resolves a decoded review into one of the three possible outcomes.
  ///
  /// - Parameter review: The reviewer's decoded response.
  /// - Returns: `.verdictOverturned` when the reviewer disagrees with the underlying finding,
  ///   `.replyRejected` when it agrees but withholds approval of the candidate text (including
  ///   an empty or missing reply), or `.approved` with the reviewer's final text otherwise.
  static func reviewOutcome(from review: ReviewVerdict) -> ReviewOutcome {
    guard review.isVerdictSupported else {
      return .verdictOverturned(reasoning: review.reasoning)
    }
    guard review.isApproved, let reply = review.reply, !reply.isEmpty else {
      return .replyRejected(reasoning: review.reasoning)
    }
    return .approved(reply: reply)
  }

  /// Returns the reviewer's outcome for an already-unfair verdict, or `nil`
  /// when there's nothing to review. With no reviewer configured, the first
  /// model's draft is approved unchanged.
  ///
  /// - Parameters:
  ///   - verdict: The primary judge's verdict for the reply.
  ///   - context: The same context the verdict was judged against.
  /// - Returns: `nil` when `verdict` is already fair or has no candidate reply; otherwise the
  ///   reviewer's outcome (or the unchanged candidate, approved, when no reviewer is configured).
  /// - Throws: `FairnessJudgeError` if the reviewer request fails or its response can't be parsed.
  func reviewedReply(for verdict: FairnessVerdict, context: Context) async throws -> ReviewOutcome?
  {
    guard !verdict.isFair(threshold: config.fairnessScoreThreshold),
      let candidateReply = verdict.reply, !candidateReply.isEmpty
    else {
      return nil
    }
    guard let reviewer = config.reviewLLM else { return .approved(reply: candidateReply) }

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
    return Self.reviewOutcome(from: review)
  }

  /// Sends a single chat-completion request and returns the first choice's message content.
  ///
  /// - Parameters:
  ///   - baseURL: The provider's API base URL; `chat/completions` is appended to it.
  ///   - apiKey: The bearer token sent in the `Authorization` header.
  ///   - model: The provider's model identifier.
  ///   - messages: The conversation to send, in order.
  ///   - temperature: The sampling temperature to request.
  /// - Returns: The raw text content of the first completion choice.
  /// - Throws: `FairnessJudgeError.requestFailed` on a non-2xx HTTP status, or
  ///   `FairnessJudgeError.emptyResponse` when the response has no message content.
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
  ///
  /// - Parameter urlRequest: The request to send.
  /// - Returns: The response body and metadata, as returned by `URLSession`.
  /// - Throws: The underlying `URLError` if every attempt fails, or any other transport error.
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

  /// Parses a `FairnessVerdict` from raw model output.
  ///
  /// Models sometimes wrap JSON in prose or a markdown code fence despite
  /// instructions not to; this falls back to extracting the outermost `{...}`.
  ///
  /// - Parameter content: The model's raw message content.
  /// - Returns: The decoded verdict.
  /// - Throws: `FairnessJudgeError.unparsableVerdict` if no valid JSON object can be found.
  static func parseVerdict(from content: String) throws -> FairnessVerdict {
    try parseJSON(FairnessVerdict.self, from: content)
  }

  /// Parses a `ReviewVerdict` from raw reviewer model output, with the same
  /// prose/code-fence tolerance as `parseVerdict(from:)`.
  ///
  /// - Parameter content: The reviewer model's raw message content.
  /// - Returns: The decoded review.
  /// - Throws: `FairnessJudgeError.unparsableVerdict` if no valid JSON object can be found.
  static func parseReview(from content: String) throws -> ReviewVerdict {
    try parseJSON(ReviewVerdict.self, from: content)
  }

  /// Decodes `content` as `Value`, falling back to the outermost `{...}` substring
  /// when the whole string isn't valid JSON on its own.
  ///
  /// - Parameters:
  ///   - type: The `Decodable` type to produce.
  ///   - content: The raw text to parse.
  /// - Returns: The decoded value.
  /// - Throws: `FairnessJudgeError.unparsableVerdict` if decoding fails both ways.
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

  /// The system prompt sent to the primary judge model.
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

    If it IS a debate response, set "isDebate" to true and score it on \
    three separate axes, each from 0 to 100:

    - "rhetoric": tone. 100 means the reply is civil, even if blunt or \
      strongly worded. 0 means it relies on insults, personal attacks, pure \
      sarcasm, or mockery in place of argument.
    - "relevance": whether it engages the actual point. 100 means it \
      directly addresses what was actually said. 0 means it strawmans the \
      point or answers a different point altogether.
    - "evidence": support for its claims. 100 means it backs its position \
      with evidence, sound reasoning, or a genuine counter-argument. 0 means \
      it asserts a conclusion with no evidence or reasoning where some would \
      clearly be expected.

    Score each axis independently — a reply can be perfectly civil (high \
    rhetoric) while still strawmanning the point (low relevance), or vice \
    versa. Do not blend them into one number yourself; report all three.

    Respond with ONLY a single JSON object, no markdown fences, no commentary, \
    exactly this shape:
    {"isDebate": true|false, "rhetoric": null|0-100, "relevance": null|0-100, "evidence": null|0-100, "reasoning": "one or two sentences why", "reply": null|"string"}

    The publication gate is the *weakest* of the three axes, not their \
    average — a reply that's mostly substantive but has one severely unfair \
    aside should still gate on that aside. If "isDebate" is false, or the \
    lowest of the three scores is at or above \
    \(config.fairnessScoreThreshold), set "reply" to null — do nothing \
    further.

    If "isDebate" is true and the lowest of the three scores is below \
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

  /// The system prompt sent to the second-model reviewer.
  private var reviewSystemPrompt: String {
    """
    You are a cautious reviewer of a proposed Bluesky fairness-bot reply. Return ONLY one JSON object:
    {"verdictSupported": true|false, "approved": true|false, "reasoning": "one sentence", "reply": null|"string"}

    You are making two independent judgments, not one:

    - "verdictSupported": do you agree, from the supplied thread, that the original reply actually engaged unfairly? If you think the first model got this wrong — the reply actually engaged fairly — set this to false. In that case set "approved" to false and "reply" to null regardless of how good the candidate text is; you are overturning the finding itself, not just the reply.
    - "approved": only meaningful when "verdictSupported" is true. Is this specific candidate reply fit to post — polite, accurate, and proportionate? If not (too harsh, overreaching, or otherwise off), set "approved" to false and "reply" to null even though you agree the original reply was unfair.

    If both are true, `reply` must contain the candidate with only minimal edits for clarity, factual caution, or tone. Do not introduce a new criticism or alter the conclusion.

    The 300-Unicode-character limit is a hard platform requirement, not optional. Count the characters in the candidate reply: if it is at or over 300, you must shorten it yourself — trim a clause or sentence, tighten wording — so the `reply` you return is under 300 characters. Never pass through a reply that is over the limit, and never produce one that would need to be cut off mid-sentence when posted; a shorter reply that says slightly less is far better than one that overruns. If you cannot bring it under 300 characters while keeping it accurate and proportionate, reject it instead (`approved: false`, `reply: null`).
    """
  }

  /// Builds the reviewer's user-turn prompt: the thread context, the primary judge's
  /// scores and reasoning, and the candidate reply to review.
  private func reviewUserPrompt(
    for context: Context, verdict: FairnessVerdict, candidateReply: String
  ) -> String {
    """
    Original post (root of the thread):
    \(context.rootText ?? "(not available)")

    Message from @\(context.parentAuthorHandle) that the new reply is responding to:
    \(context.parentText ?? "(not available)")

    New reply, posted by @\(context.replyAuthorHandle):
    \(context.replyText)

    First model's scores — rhetoric: \(verdict.rhetoric ?? 0)/100, relevance: \(verdict.relevance ?? 0)/100, evidence: \(verdict.evidence ?? 0)/100:
    \(verdict.reasoning)

    Candidate reply:
    \(candidateReply)
    """
  }

  /// Builds the primary judge's user-turn prompt: the thread context and the new reply to judge.
  private func userPrompt(for context: Context) -> String {
    """
    Original post (root of the thread):
    \(context.rootText ?? "(not available)")

    Message from @\(context.parentAuthorHandle) that the new reply is responding to:
    \(context.parentText ?? "(not available)")

    New reply, posted by @\(context.replyAuthorHandle):
    \(context.replyText)
    """
  }
}

/// An error raised while asking an LLM to judge or review a reply.
enum FairnessJudgeError: Error, CustomStringConvertible {
  /// The HTTP request to the provider failed with a non-2xx status.
  case requestFailed(status: Int)
  /// The provider's response contained no message content to parse.
  case emptyResponse
  /// The model's output could not be parsed as the expected JSON shape.
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
