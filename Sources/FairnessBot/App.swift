import Foundation

enum FairnessBotApp {
  static func run() async throws {
    let config = try Config()
    log("Starting fairness bot")
    log(config.description)

    let atproto = ATProtoClient(config: config)
    let jetstream = JetstreamClient(config: config)
    let judge = FairnessJudge(config: config)
    let replyLog = ReplyLog(stateDirectory: config.stateDirectory)
    try await atproto.configureProfile()

    try await jetstream.run { event in
      do {
        try await handle(event, config: config, atproto: atproto, judge: judge, replyLog: replyLog)
      } catch {
        log("Error processing event at \(event.timeUs): \(error)")
      }
    }
  }

  /// Evaluates one existing reply. This is dry-run unless `postIfUnfair` is
  /// explicit, in which case the posted reply is added to the dedupe log.
  static func check(_ reference: String, postIfUnfair: Bool = false) async throws {
    let config = try Config()
    let atproto = ATProtoClient(config: config)
    let uri = try await resolvePostURI(PostReference.parse(reference), using: atproto)
    let post = try await atproto.fetchPost(uri: uri)

    guard let reply = post.record.reply,
      authorDID(fromURI: reply.parent.uri) == config.targetDID,
      post.author.did != config.targetDID
    else {
      throw CommandLineError.notAReplyToTarget(uri)
    }

    let context = try await atproto.fetchContext(replyURI: uri, reply: reply)
    let judge = FairnessJudge(config: config)
    let judgeContext = FairnessJudge.Context(
      targetHandle: config.targetHandle,
      rootText: context.rootText,
      parentText: context.parentText,
      replyAuthorHandle: post.author.handle,
      replyText: post.record.text ?? "",
    )
    let verdict = try await judge.judge(judgeContext)

    if let score = verdict.score {
      let isFair = verdict.isFair(threshold: config.fairnessScoreThreshold)
      print("\(isFair ? "FAIR" : "UNFAIR") (\(score)/100)")
    } else {
      print("N/A — general conversation, no fairness score.")
    }
    print(verdict.reasoning)
    guard
      let reviewedReply = try await judge.reviewedReply(
        for: verdict, context: judgeContext)
    else {
      print("\nNo reply was approved for publication.")
      return
    }
    let replyText = boundedPostText(reviewedReply)

    guard postIfUnfair else {
      print("\nSuggested reply (not posted):\n\(replyText)")
      return
    }

    let replyLog = ReplyLog(stateDirectory: config.stateDirectory)
    guard await !replyLog.alreadyReplied(uri) else {
      print("\nA bot reply was already posted for this post; nothing was published.")
      return
    }

    try await atproto.configureProfile()
    let offendingReply = PostRecord.ReplyRef(
      root: reply.root,
      parent: StrongRef(uri: uri, cid: post.cid),
    )
    let response = try await atproto.postReply(text: replyText, replyingTo: offendingReply)
    await replyLog.markReplied(uri)
    print("\nPosted reply:\n\(replyText)")

    do {
      _ = try await atproto.publishVerdict(
        subject: StrongRef(uri: uri, cid: post.cid),
        reply: StrongRef(uri: response.uri, cid: response.cid),
        score: verdict.score ?? 0, reasoning: verdict.reasoning, replyText: replyText)
    } catch {
      print("Failed to publish verdict record: \(error)")
    }
  }

  /// Bluesky's hard 300-Unicode-character post limit. The LLM (and reviewer,
  /// when configured) are instructed to stay under this themselves, so this
  /// should rarely trigger — but as a last-resort safety net it truncates
  /// any overrun. Rather than a blind character cut, it prefers the last
  /// sentence boundary, then the last word boundary, so a rare overrun
  /// degrades gracefully instead of chopping off mid-word.
  static func boundedPostText(_ text: String) -> String {
    guard text.count > 300 else { return text }
    log(
      "LLM reply exceeded the 300-character limit (\(text.count) chars); truncating at a boundary.")

    let hardLimit = String(text.prefix(300))
    // Don't truncate so aggressively that a boundary far from the limit
    // leaves almost nothing — require the kept text to be a reasonable
    // majority of the budget.
    let minKeptLength = 150

    if let sentence = lastBoundary(in: hardLimit, at: [".", "!", "?"], minLength: minKeptLength) {
      return sentence
    }
    if let word = lastBoundary(
      in: hardLimit, at: [" "], minLength: minKeptLength, dropDelimiter: true)
    {
      return word
    }
    return hardLimit
  }

  /// Returns the text up to and including the last occurrence of any
  /// character in `delimiters`, provided that prefix is at least
  /// `minLength` characters. When `dropDelimiter` is true, the delimiter
  /// itself is excluded (used for word boundaries, where trailing
  /// whitespace shouldn't be kept; sentence punctuation is kept).
  private static func lastBoundary(
    in text: String, at delimiters: Set<Character>, minLength: Int, dropDelimiter: Bool = false,
  ) -> String? {
    guard let index = text.lastIndex(where: { delimiters.contains($0) }) else { return nil }
    let candidate = dropDelimiter ? String(text[..<index]) : String(text[...index])
    return candidate.count >= minLength ? candidate : nil
  }

  private static func resolvePostURI(_ reference: PostReference, using atproto: ATProtoClient)
    async throws -> String
  {
    switch reference {
    case .atURI(let uri):
      return uri
    case .blueskyPost(let actor, let rkey):
      let did = actor.hasPrefix("did:") ? actor : try await atproto.resolveHandle(actor)
      return "at://\(did)/app.bsky.feed.post/\(rkey)"
    }
  }

  /// Filters a Jetstream event down to "is this a new, unhandled reply to
  /// the target account", fetches context, judges it, and posts a reply
  /// only when the verdict is unfair.
  static func handle(
    _ event: JetstreamEvent,
    config: Config,
    atproto: ATProtoClient,
    judge: FairnessJudge,
    replyLog: ReplyLog,
  ) async throws {
    guard let qualifying = qualifyingReply(in: event, targetDID: config.targetDID) else { return }
    guard await !replyLog.alreadyReplied(qualifying.uri) else { return }

    // The public AppView briefly lags the firehose; give it a moment to
    // index this brand-new post before asking it for context.
    try await Task.sleep(for: .seconds(2))

    let context = try await atproto.fetchContext(
      replyURI: qualifying.uri, reply: qualifying.replyRef)
    let judgeContext = FairnessJudge.Context(
      targetHandle: config.targetHandle,
      rootText: context.rootText,
      parentText: context.parentText,
      replyAuthorHandle: context.replyAuthorHandle ?? qualifying.authorDID,
      replyText: qualifying.text,
    )
    let verdict = try await judge.judge(judgeContext)

    guard !verdict.isFair(threshold: config.fairnessScoreThreshold) else { return }
    guard let rebuttalText = try await judge.reviewedReply(for: verdict, context: judgeContext)
    else {
      log("Reviewer did not approve a reply to \(qualifying.uri)")
      return
    }

    let offendingReply = PostRecord.ReplyRef(
      root: qualifying.replyRef.root,
      parent: StrongRef(uri: qualifying.uri, cid: qualifying.cid),
    )
    let replyText = boundedPostText(rebuttalText)
    let response = try await atproto.postReply(text: replyText, replyingTo: offendingReply)
    await replyLog.markReplied(qualifying.uri)
    log("Replied to \(qualifying.uri): \(verdict.reasoning)")

    do {
      _ = try await atproto.publishVerdict(
        subject: StrongRef(uri: qualifying.uri, cid: qualifying.cid),
        reply: StrongRef(uri: response.uri, cid: response.cid),
        score: verdict.score ?? 0, reasoning: verdict.reasoning, replyText: replyText)
    } catch {
      log("Failed to publish verdict record for \(qualifying.uri): \(error)")
    }
  }

  /// A Jetstream event that has passed every synchronous, network-free check:
  /// it's a freshly created post, it's a reply directly to the target
  /// account, and it isn't the target account replying to itself.
  struct QualifyingReply: Equatable {
    let uri: String
    let cid: String
    let authorDID: String
    let text: String
    let replyRef: PostRecord.ReplyRef
  }

  /// Pure (no I/O) filtering logic, kept separate from `handle` so it's
  /// testable without mocking any network client.
  static func qualifyingReply(in event: JetstreamEvent, targetDID: String) -> QualifyingReply? {
    guard event.kind == "commit", let commit = event.commit,
      commit.operation == "create", commit.collection == "app.bsky.feed.post",
      let cid = commit.cid
    else { return nil }
    guard let record = commit.record, let replyRef = record.reply, let text = record.text else {
      return nil
    }

    // Only care about direct replies whose immediate parent belongs to the
    // target. A reply to somebody else's reply is ignored, even if that
    // nested thread started below a target post.
    guard authorDID(fromURI: replyRef.parent.uri) == targetDID else { return nil }

    // The bot's own replies are always parented on the *offending* reply,
    // never on a target-account post, so they can't structurally re-enter
    // this filter. The one self-loop worth guarding explicitly is the
    // target account replying to itself.
    guard event.did != targetDID else { return nil }

    let uri = "at://\(event.did)/\(commit.collection)/\(commit.rkey)"
    return QualifyingReply(uri: uri, cid: cid, authorDID: event.did, text: text, replyRef: replyRef)
  }

  static func authorDID(fromURI uri: String) -> String? {
    guard uri.hasPrefix("at://") else { return nil }
    let rest = uri.dropFirst("at://".count)
    return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
  }

  static func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
