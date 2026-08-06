import Foundation

/// The bot's top-level entry points: the continuous watcher and the one-shot `check` command.
enum FairnessBotApp {
  /// Loads configuration, applies the bot's profile, and watches Jetstream forever,
  /// judging and acting on each qualifying reply as it arrives.
  ///
  /// - Throws: `Config.ConfigError` if configuration is invalid; rethrows any error from
  ///   applying the bot's profile. Errors while handling an individual event are logged and
  ///   do not stop the watcher.
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
  ///
  /// - Parameters:
  ///   - reference: An AT-URI or `https://bsky.app/profile/<handle-or-did>/post/<rkey>` URL
  ///     identifying the reply to evaluate.
  ///   - postIfUnfair: When `true`, publishes the suggested reply and its verdict record if
  ///     the verdict is unfair and approved. Defaults to `false` (dry run).
  /// - Throws: `CommandLineError.notAReplyToTarget` if the referenced post isn't a reply to
  ///   the configured target account; rethrows any error from resolving, fetching, judging,
  ///   or posting.
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
      parentAuthorHandle: context.parentAuthorHandle ?? config.targetHandle,
      rootText: context.rootText,
      parentText: context.parentText,
      replyAuthorHandle: post.author.handle,
      replyText: post.record.text ?? "",
    )
    let verdict = try await judge.judge(judgeContext)

    if let score = verdict.score {
      let isFair = verdict.isFair(threshold: config.fairnessScoreThreshold)
      print("\(isFair ? "FAIR" : "UNFAIR") (\(score)/100)")
      print(
        "  rhetoric: \(verdict.rhetoric ?? 0)/100  relevance: \(verdict.relevance ?? 0)/100  evidence: \(verdict.evidence ?? 0)/100"
      )
    } else {
      print("N/A — general conversation, no fairness score.")
    }
    print(verdict.reasoning)
    guard
      let outcome = try await judge.reviewedReply(
        for: verdict, context: judgeContext)
    else {
      print("\nNo reply was approved for publication.")
      return
    }
    let reviewedReply: String
    switch outcome {
    case .approved(let reply):
      reviewedReply = reply
    case .verdictOverturned(let reasoning):
      print("\nReviewer overturned the unfairness finding: \(reasoning)")
      return
    case .replyRejected(let reasoning):
      print("\nReviewer rejected the candidate reply: \(reasoning)")
      return
    }
    let replyText = boundedPostText(reviewedReply)

    guard postIfUnfair else {
      print("\nSuggested reply (not posted):\n\(replyText)")
      return
    }

    let replyLog = ReplyLog(stateDirectory: config.stateDirectory)
    guard await !replyLog.hasReplied(to: uri) else {
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
        score: verdict.score ?? 0, rhetoric: verdict.rhetoric ?? 0,
        relevance: verdict.relevance ?? 0,
        evidence: verdict.evidence ?? 0, reasoning: verdict.reasoning, replyText: replyText)
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
  ///
  /// - Parameter text: The candidate reply text.
  /// - Returns: `text` unchanged if it's at or under 300 Unicode characters; otherwise a
  ///   truncated version at the best available boundary.
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
  ///
  /// - Parameters:
  ///   - text: The text to search.
  ///   - delimiters: The set of boundary characters to search for.
  ///   - minLength: The minimum acceptable length of the returned prefix.
  ///   - dropDelimiter: Whether to exclude the matched delimiter from the result.
  /// - Returns: The longest qualifying prefix, or `nil` if none meets `minLength`.
  private static func lastBoundary(
    in text: String, at delimiters: Set<Character>, minLength: Int, dropDelimiter: Bool = false,
  ) -> String? {
    guard let index = text.lastIndex(where: { delimiters.contains($0) }) else { return nil }
    let candidate = dropDelimiter ? String(text[..<index]) : String(text[...index])
    return candidate.count >= minLength ? candidate : nil
  }

  /// Resolves a parsed post reference to its canonical AT-URI, looking up the
  /// author's DID when `reference` is a Bluesky post URL.
  ///
  /// - Parameters:
  ///   - reference: The parsed post reference.
  ///   - atproto: The client used to resolve a handle to a DID, if needed.
  /// - Returns: The post's AT-URI.
  /// - Throws: Rethrows any error from resolving the handle.
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

  /// Filters a Jetstream event down to "is this a new, unhandled reply worth
  /// judging" (either an external reply to the target, or — when
  /// self-review is enabled — the target's own reply to someone else),
  /// fetches context, judges it, and acts only when the verdict is unfair.
  ///
  /// - Parameters:
  ///   - event: The Jetstream event to consider.
  ///   - config: The bot's configuration.
  ///   - atproto: The client used to fetch context and, for an external reply, post and
  ///     publish.
  ///   - judge: The fairness judge used to score the reply and run the optional review.
  ///   - replyLog: The dedupe log consulted and updated for any qualifying reply.
  /// - Throws: Rethrows any error from fetching context, judging, reviewing, posting, or
  ///   publishing, except that a failure to publish the verdict record is logged, not thrown.
  static func handle(
    _ event: JetstreamEvent,
    config: Config,
    atproto: ATProtoClient,
    judge: FairnessJudge,
    replyLog: ReplyLog,
  ) async throws {
    guard
      let qualifying =
        qualifyingReply(in: event, targetDID: config.targetDID)
        ?? (config.isSelfReviewEnabled
          ? qualifyingOwnReply(in: event, targetDID: config.targetDID) : nil)
    else { return }
    guard await !replyLog.hasReplied(to: qualifying.uri) else { return }

    // The public AppView briefly lags the firehose; give it a moment to
    // index this brand-new post before asking it for context.
    try await Task.sleep(for: .seconds(2))

    let context = try await atproto.fetchContext(
      replyURI: qualifying.uri, reply: qualifying.replyRef)
    let judgeContext = FairnessJudge.Context(
      parentAuthorHandle: context.parentAuthorHandle ?? config.targetHandle,
      rootText: context.rootText,
      parentText: context.parentText,
      replyAuthorHandle: context.replyAuthorHandle ?? qualifying.authorDID,
      replyText: qualifying.text,
    )
    let verdict = try await judge.judge(judgeContext)

    guard !verdict.isFair(threshold: config.fairnessScoreThreshold) else { return }
    guard let outcome = try await judge.reviewedReply(for: verdict, context: judgeContext) else {
      return
    }
    let rebuttalText: String
    switch outcome {
    case .approved(let reply):
      rebuttalText = reply
    case .verdictOverturned(let reasoning):
      log("Reviewer overturned the unfairness finding for \(qualifying.uri): \(reasoning)")
      return
    case .replyRejected(let reasoning):
      log("Reviewer rejected the candidate reply for \(qualifying.uri): \(reasoning)")
      return
    }

    switch qualifying.kind {
    case .external:
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
          score: verdict.score ?? 0, rhetoric: verdict.rhetoric ?? 0,
          relevance: verdict.relevance ?? 0, evidence: verdict.evidence ?? 0,
          reasoning: verdict.reasoning, replyText: replyText)
      } catch {
        log("Failed to publish verdict record for \(qualifying.uri): \(error)")
      }

    case .selfReview:
      // Never post a public counter-reply to the target's own post — that
      // would be a dishonest performance. The verdict record alone, with no
      // counter-reply, is the accountability mechanism.
      await replyLog.markReplied(qualifying.uri)
      log("Self-review flagged \(qualifying.uri): \(verdict.reasoning)")

      do {
        _ = try await atproto.publishVerdict(
          subject: StrongRef(uri: qualifying.uri, cid: qualifying.cid),
          reply: nil, score: verdict.score ?? 0, rhetoric: verdict.rhetoric ?? 0,
          relevance: verdict.relevance ?? 0, evidence: verdict.evidence ?? 0,
          reasoning: verdict.reasoning, replyText: nil, selfAssessment: true)
      } catch {
        log("Failed to publish self-assessment verdict record for \(qualifying.uri): \(error)")
      }
    }
  }

  /// A Jetstream event that has passed every synchronous, network-free check:
  /// it's a freshly created reply post either to the target account
  /// (`.external`) or, when self-review is enabled, from the target account
  /// to somebody else (`.selfReview`).
  struct QualifyingReply: Equatable {
    /// Which direction a qualifying reply was found in.
    enum Kind: Equatable {
      /// Someone else's reply to the target account.
      case external
      /// The target account's own reply to someone else, judged only when self-review is on.
      case selfReview
    }

    let uri: String
    let cid: String
    let authorDID: String
    let text: String
    let replyRef: PostRecord.ReplyRef
    let kind: Kind
  }

  /// The structural, direction-agnostic shape both `qualifyingReply` and
  /// `qualifyingOwnReply` require: a freshly created reply post with text.
  private struct CommitShape {
    let uri: String
    let cid: String
    let authorDID: String
    let text: String
    let replyRef: PostRecord.ReplyRef
  }

  /// Extracts the direction-agnostic shape common to both qualifying filters, or `nil` if
  /// `event` isn't a freshly created reply post with text.
  ///
  /// - Parameter event: The Jetstream event to inspect.
  /// - Returns: The commit's shape, or `nil` if it doesn't describe a new reply post.
  private static func qualifyingCommitShape(in event: JetstreamEvent) -> CommitShape? {
    guard event.kind == "commit", let commit = event.commit,
      commit.operation == "create", commit.collection == "app.bsky.feed.post",
      let cid = commit.cid
    else { return nil }
    guard let record = commit.record, let replyRef = record.reply, let text = record.text else {
      return nil
    }
    let uri = "at://\(event.did)/\(commit.collection)/\(commit.rkey)"
    return CommitShape(uri: uri, cid: cid, authorDID: event.did, text: text, replyRef: replyRef)
  }

  /// Pure (no I/O) filtering logic, kept separate from `handle` so it's
  /// testable without mocking any network client. Only care about direct
  /// replies whose immediate parent belongs to the target. A reply to
  /// somebody else's reply is ignored, even if that nested thread started
  /// below a target post. The bot's own replies are always parented on the
  /// *offending* reply, never on a target-account post, so they can't
  /// structurally re-enter this filter. The one self-loop worth guarding
  /// explicitly is the target account replying to itself.
  ///
  /// - Parameters:
  ///   - event: The Jetstream event to inspect.
  ///   - targetDID: The DID of the account this bot protects.
  /// - Returns: A `.external`-kind `QualifyingReply` if `event` is a direct reply to the
  ///   target from someone else, `nil` otherwise.
  static func qualifyingReply(in event: JetstreamEvent, targetDID: String) -> QualifyingReply? {
    guard let shape = qualifyingCommitShape(in: event) else { return nil }
    guard authorDID(fromURI: shape.replyRef.parent.uri) == targetDID else { return nil }
    guard shape.authorDID != targetDID else { return nil }
    return QualifyingReply(
      uri: shape.uri, cid: shape.cid, authorDID: shape.authorDID, text: shape.text,
      replyRef: shape.replyRef, kind: .external)
  }

  /// The mirror image of `qualifyingReply`: the target account itself is the
  /// author of a direct reply to someone else. Only reachable when
  /// self-review is enabled.
  ///
  /// - Parameters:
  ///   - event: The Jetstream event to inspect.
  ///   - targetDID: The DID of the account this bot protects.
  /// - Returns: A `.selfReview`-kind `QualifyingReply` if `event` is the target's own direct
  ///   reply to someone else, `nil` otherwise.
  static func qualifyingOwnReply(in event: JetstreamEvent, targetDID: String) -> QualifyingReply? {
    guard let shape = qualifyingCommitShape(in: event) else { return nil }
    guard shape.authorDID == targetDID else { return nil }
    guard authorDID(fromURI: shape.replyRef.parent.uri) != targetDID else { return nil }
    return QualifyingReply(
      uri: shape.uri, cid: shape.cid, authorDID: shape.authorDID, text: shape.text,
      replyRef: shape.replyRef, kind: .selfReview)
  }

  /// Extracts the repo DID from an AT-URI.
  ///
  /// - Parameter uri: An AT-URI, e.g. `at://did:plc:abc/app.bsky.feed.post/xyz`.
  /// - Returns: The DID component, or `nil` if `uri` doesn't start with `at://`.
  static func authorDID(fromURI uri: String) -> String? {
    guard uri.hasPrefix("at://") else { return nil }
    let rest = uri.dropFirst("at://".count)
    return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
  }

  /// Writes a diagnostic line to standard error.
  ///
  /// - Parameter message: The line to write; a trailing newline is appended.
  static func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
