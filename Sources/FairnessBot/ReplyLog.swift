import Foundation

/// Tracks which offending posts the bot has already replied to, so a crash
/// between posting a reply and Jetstream's cursor advancing (which would
/// otherwise cause that same event to be redelivered on reconnect) never
/// results in a duplicate public reply.
actor ReplyLog {
  private let fileURL: URL
  private var repliedURIs: Set<String>?

  init(stateDirectory: URL) {
    fileURL = stateDirectory.appendingPathComponent("replied.txt")
  }

  func alreadyReplied(_ uri: String) -> Bool {
    loaded().contains(uri)
  }

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
