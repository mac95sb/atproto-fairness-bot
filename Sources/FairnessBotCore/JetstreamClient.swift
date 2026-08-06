import Foundation

/// Watches a Jetstream instance (https://github.com/bluesky-social/jetstream)
/// for `app.bsky.feed.post` creates and hands each decoded event to a callback.
///
/// Persists the `time_us` cursor to disk after each event finishes processing.
/// On any reconnect — a dropped socket, or a fresh process start after a crash —
/// it always resumes from that saved cursor, so Jetstream replays everything
/// posted during the gap instead of silently skipping it. This is bounded by
/// the chosen instance's retention window (typically several days on public
/// instances); an outage longer than that will still lose events.
actor JetstreamClient {
  private let config: Config
  private let urlSession: URLSession

  /// The on-disk location of the persisted cursor.
  private var cursorFileURL: URL {
    config.stateDirectory.appendingPathComponent("cursor.txt")
  }

  /// Creates a client for the configured Jetstream instance.
  ///
  /// - Parameters:
  ///   - config: The bot's configuration.
  ///   - urlSession: The session used for the WebSocket connection; defaults to `.shared`.
  init(config: Config, urlSession: URLSession = .shared) {
    self.config = config
    self.urlSession = urlSession
  }

  /// Runs forever, reconnecting with exponential backoff on any failure.
  /// Only returns if the surrounding task is cancelled.
  ///
  /// - Parameter onEvent: Called for each decoded event, in order, before the cursor for
  ///   that event is persisted. Any error it throws (other than cancellation) is logged and
  ///   treated as a connection failure, triggering a reconnect.
  func run(onEvent: @Sendable (JetstreamEvent) async throws -> Void) async throws {
    var backoff: Duration = .seconds(1)
    let maxBackoff: Duration = .seconds(60)

    while !Task.isCancelled {
      do {
        try await connectAndConsume(onEvent: onEvent)
        backoff = .seconds(1)
      } catch is CancellationError {
        return
      } catch {
        FileHandle.standardError.write(
          Data("Jetstream connection lost (\(error)); reconnecting in \(backoff)...\n".utf8),
        )
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, maxBackoff)
      }
    }
  }

  /// Opens one WebSocket connection, decodes events as they arrive, and hands each to
  /// `onEvent`, persisting the cursor after every successfully handled event.
  ///
  /// - Parameter onEvent: Called for each decoded event.
  /// - Throws: Rethrows any error from the WebSocket connection or from `onEvent`.
  private func connectAndConsume(onEvent: @Sendable (JetstreamEvent) async throws -> Void)
    async throws
  {
    let url = subscribeURL(cursor: loadCursor())
    let webSocketTask = urlSession.webSocketTask(with: url)
    webSocketTask.resume()
    defer { webSocketTask.cancel(with: .goingAway, reason: nil) }

    while !Task.isCancelled {
      let message = try await webSocketTask.receive()

      guard case .string(let text) = message,
        let data = text.data(using: .utf8)
      else { continue }

      guard let event = try? JSONDecoder().decode(JetstreamEvent.self, from: data) else {
        continue
      }

      try await onEvent(event)
      saveCursor(event.timeUs)
    }
  }

  /// Builds the Jetstream subscription URL, filtered to `app.bsky.feed.post` and, when
  /// available, resuming from `cursor`.
  ///
  /// - Parameter cursor: The `time_us` cursor to resume from, or `nil` to start from now.
  /// - Returns: The WebSocket URL to connect to.
  private func subscribeURL(cursor: Int64?) -> URL {
    var components = URLComponents(url: config.jetstreamURL, resolvingAgainstBaseURL: false)!
    var queryItems = [URLQueryItem(name: "wantedCollections", value: "app.bsky.feed.post")]
    if let cursor {
      queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
    }
    components.queryItems = queryItems
    return components.url!
  }

  // MARK: - Cursor persistence

  /// Reads the last persisted cursor from disk.
  ///
  /// - Returns: The saved `time_us` cursor, or `nil` if none has been persisted yet or the
  ///   file couldn't be read.
  private func loadCursor() -> Int64? {
    guard let data = try? Data(contentsOf: cursorFileURL),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Persists `cursor` to disk, overwriting any previously saved value.
  ///
  /// - Parameter cursor: The `time_us` cursor of the most recently handled event.
  private func saveCursor(_ cursor: Int64) {
    try? FileManager.default.createDirectory(
      at: config.stateDirectory, withIntermediateDirectories: true,
    )
    try? String(cursor).write(to: cursorFileURL, atomically: true, encoding: .utf8)
  }
}
