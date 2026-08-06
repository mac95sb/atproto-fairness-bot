import Foundation

/// Tracks which offending posts the bot has already replied to, so a crash
/// between posting a reply and Jetstream's cursor advancing (which would
/// otherwise cause that same event to be redelivered on reconnect) never
/// results in a duplicate public reply.
actor ReplyLog {
  private let fileURL: URL
  private var repliedURIs: Set<String>?

  /// Creates a reply log persisted under `stateDirectory`.
  ///
  /// - Parameter stateDirectory: The directory the dedupe file is stored in.
  init(stateDirectory: URL) {
    fileURL = stateDirectory.appendingPathComponent("replied.txt")
  }

  /// Whether the bot has already posted a reply to `uri`.
  ///
  /// - Parameter uri: The AT-URI of the offending post.
  /// - Returns: `true` if `markReplied(_:)` was previously called with `uri`.
  func hasReplied(to uri: String) -> Bool {
    loaded().contains(uri)
  }

  /// Records that the bot has posted a reply to `uri`, so a future
  /// `hasReplied(to:)` call for the same URI returns `true`.
  ///
  /// - Parameter uri: The AT-URI of the offending post that was replied to.
  func markReplied(_ uri: String) {
    var uris = loaded()
    guard uris.insert(uri).inserted else { return }
    repliedURIs = uris

    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
    )
    let content = uris.sorted().joined(separator: "\n") + "\n"
    try? content.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  /// The cached set of already-replied-to URIs, loading it from disk on first access.
  private func loaded() -> Set<String> {
    if let repliedURIs {
      return repliedURIs
    }
    let uris: Set<String> =
      if let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) {
        Set(text.split(separator: "\n").map(String.init))
      } else {
        []
      }
    repliedURIs = uris
    return uris
  }
}
