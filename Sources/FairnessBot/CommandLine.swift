import Foundation

/// A post identified either directly by its AT-URI or by a Bluesky post URL.
enum PostReference: Equatable {
  /// An AT-URI, e.g. `at://did:plc:abc/app.bsky.feed.post/xyz`.
  case atURI(String)
  /// A Bluesky post URL's actor (handle or DID) and record key.
  case blueskyPost(actor: String, rkey: String)

  /// Parses a command-line post reference.
  ///
  /// - Parameter input: An AT-URI or an `https://bsky.app/profile/<handle-or-did>/post/<rkey>`
  ///   URL.
  /// - Returns: The parsed reference.
  /// - Throws: `CommandLineError.invalidPostReference` if `input` matches neither shape.
  static func parse(_ input: String) throws -> Self {
    if input.hasPrefix("at://") {
      let components = input.dropFirst("at://".count).split(separator: "/")
      guard components.count == 3, components[1] == "app.bsky.feed.post", !components[0].isEmpty,
        !components[2].isEmpty
      else {
        throw CommandLineError.invalidPostReference(input)
      }
      return .atURI(input)
    }

    guard let url = URL(string: input),
      url.scheme == "https",
      url.host == "bsky.app"
    else {
      throw CommandLineError.invalidPostReference(input)
    }

    let path = url.pathComponents.filter { $0 != "/" }
    guard path.count == 4, path[0] == "profile", path[2] == "post", !path[1].isEmpty,
      !path[3].isEmpty
    else {
      throw CommandLineError.invalidPostReference(input)
    }
    return .blueskyPost(actor: path[1], rkey: path[3])
  }
}

/// An error raised while parsing or validating a command-line argument.
enum CommandLineError: Error, CustomStringConvertible {
  /// The given string is neither a valid AT-URI nor a Bluesky post URL.
  case invalidPostReference(String)
  /// The referenced post is not a direct reply to the configured target account.
  case notAReplyToTarget(String)

  var description: String {
    switch self {
    case .invalidPostReference(let reference):
      "Expected an AT-URI or https://bsky.app/profile/<handle-or-did>/post/<rkey>; got: \(reference)"
    case .notAReplyToTarget(let uri):
      "\(uri) is not a reply to the configured target account."
    }
  }
}
