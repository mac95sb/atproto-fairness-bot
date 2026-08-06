import ArgumentParser
import Foundation

/// The `fairness-bot` command-line interface: continuous watching, one-shot checks, and
/// one-time profile setup.
@main
struct FairnessBotCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fairness-bot",
    abstract: "Watch Bluesky replies and flag unfair engagement.",
    subcommands: [Watch.self, Check.self, SetupProfile.self],
    defaultSubcommand: Watch.self,
  )

  /// Watches Jetstream continuously, replying only to unfair replies. The default subcommand.
  struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Watch Jetstream continuously and reply only to unfair replies.",
    )

    func run() async throws {
      try await FairnessBotApp.run()
    }
  }

  /// Applies the bot's configured display name, description, avatar, and automation label.
  struct SetupProfile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "setup-profile",
      abstract: "Apply the configured profile and Bluesky automation label.",
    )

    func run() async throws {
      let config = try Config()
      let atproto = ATProtoClient(config: config)
      try await atproto.configureProfile()
      print("Bot profile updated for @\(config.botHandle).")
    }
  }

  /// Evaluates a single existing reply, dry-run unless `--post` is given.
  struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Evaluate one reply, dry-run by default.",
    )

    @Flag(name: .customLong("post"), help: "Post the suggested reply when the verdict is unfair.")
    var shouldPostReply = false

    @Argument(help: "An AT-URI or https://bsky.app/profile/<handle-or-did>/post/<rkey> URL.")
    var postReference: String

    func run() async throws {
      try await FairnessBotApp.check(postReference, postIfUnfair: shouldPostReply)
    }
  }
}
