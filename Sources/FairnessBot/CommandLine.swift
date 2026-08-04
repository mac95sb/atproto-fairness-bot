import Foundation

enum PostReference: Equatable {
  case atURI(String)
  case blueskyPost(actor: String, rkey: String)

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

enum CommandLineError: Error, CustomStringConvertible {
  case invalidPostReference(String)
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
