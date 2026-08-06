import ArgumentParser
import Foundation
import FairnessBotCore

/// The `fairness-bot` command-line interface: continuous watching, one-shot checks, and
/// one-time profile setup.
public struct FairnessBotCLI: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "fairness-bot",
    abstract: "Watch Bluesky replies and flag unfair engagement.",
    subcommands: [Watch.self, Check.self, SetupProfile.self],
    defaultSubcommand: Watch.self,
  )

  public init() {}

  /// Watches Jetstream continuously, replying only to unfair replies. The default subcommand.
  public struct Watch: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Watch Jetstream continuously and reply only to unfair replies.",
    )

    public init() {}

    public func run() async throws {
      try await FairnessBotApp.run()
    }
  }

  /// Applies the bot's configured display name, description, avatar, and automation label.
  public struct SetupProfile: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      commandName: "setup-profile",
      abstract: "Apply the configured profile and Bluesky automation label.",
    )

    public init() {}

    public func run() async throws {
      let config = try Config()
      let atproto = ATProtoClient(config: config)
      try await atproto.configureProfile()
      print("Bot profile updated for @\(config.botHandle).")
    }
  }

  /// Evaluates a single existing reply, dry-run unless `--post` is given.
  public struct Check: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Evaluate one reply, dry-run by default.",
    )

    public init() {}

    @Flag(name: .customLong("post"), help: "Post the suggested reply when the verdict is unfair.")
    var shouldPostReply = false

    @Argument(help: "An AT-URI or https://bsky.app/profile/<handle-or-did>/post/<rkey> URL.")
    var postReference: String

    public func run() async throws {
      try await FairnessBotApp.check(postReference, postIfUnfair: shouldPostReply)
    }
  }
}
