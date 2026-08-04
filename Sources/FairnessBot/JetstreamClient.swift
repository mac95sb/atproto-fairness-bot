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

  private var cursorFileURL: URL {
    config.stateDirectory.appendingPathComponent("cursor.txt")
  }

  init(config: Config, urlSession: URLSession = .shared) {
    self.config = config
    self.urlSession = urlSession
  }

  /// Runs forever, reconnecting with exponential backoff on any failure.
  /// Only returns if the surrounding task is cancelled.
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

  private func loadCursor() -> Int64? {
    guard let data = try? Data(contentsOf: cursorFileURL),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func saveCursor(_ value: Int64) {
    try? FileManager.default.createDirectory(
      at: config.stateDirectory, withIntermediateDirectories: true,
    )
    try? String(value).write(to: cursorFileURL, atomically: true, encoding: .utf8)
  }
}
