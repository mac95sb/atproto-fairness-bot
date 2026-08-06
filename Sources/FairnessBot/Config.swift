import Foundation

/// All bot behavior is driven by environment variables so anyone can point this
/// at their own PDS/account and LLM provider without touching source. See `.env.example`.
public struct Config: CustomStringConvertible, Sendable {
  /// The OpenAI-compatible provider's API base URL; `chat/completions` is appended to it.
  let llmBaseURL: URL
  /// The bearer token for the primary LLM provider.
  let llmAPIKey: String
  /// The primary LLM provider's model identifier.
  let llmModel: String
  /// The optional second-model reviewer, configured only when `LLM_REVIEW_MODEL` is set.
  let reviewLLM: ReviewLLM?

  /// The handle of the account this bot protects.
  let targetHandle: String
  /// The DID of the account this bot protects.
  let targetDID: String

  /// The bot's own PDS service endpoint.
  let botPDSURL: URL
  /// The bot's own handle.
  public let botHandle: String
  /// An app password for the bot's own account.
  let botAppPassword: String
  /// The display name applied to the bot's Bluesky profile.
  let botDisplayName: String
  /// The description applied to the bot's Bluesky profile.
  let botProfileDescription: String
  /// The local file path of the image uploaded as the bot's avatar.
  let botAvatarPath: URL

  /// The Jetstream instance to subscribe to.
  let jetstreamURL: URL
  /// The public Bluesky AppView used to fetch thread context.
  let appViewURL: URL
  /// The directory used to persist the Jetstream cursor and the reply dedupe log.
  let stateDirectory: URL
  /// The minimum gate score (0-100) a reply must meet to be treated as fair.
  let fairnessScoreThreshold: Int
  /// Whether the bot also judges the target account's own outgoing replies. Off by default.
  let isSelfReviewEnabled: Bool

  /// The optional second-model reviewer's provider configuration.
  struct ReviewLLM: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
  }

  /// An error raised while loading configuration from the environment.
  public enum ConfigError: Error, CustomStringConvertible {
    /// One or more required environment variables were missing or invalid; lists them by name.
    case missing([String])

    public var description: String {
      switch self {
      case .missing(let keys):
        "Missing required environment variable(s): \(keys.joined(separator: ", "))"
      }
    }
  }

  /// Loads configuration from the given environment, applying documented defaults for
  /// every optional variable.
  ///
  /// - Parameter environment: The environment variables to read; defaults to the process
  ///   environment.
  /// - Throws: `ConfigError.missing` if a required variable is absent, or if a variable
  ///   that must parse as a URL or integer does not.
  public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    func required(_ key: String, missing: inout [String]) -> String {
      guard let value = environment[key], !value.isEmpty else {
        missing.append(key)
        return ""
      }
      return value
    }

    func optional(_ key: String) -> String? {
      guard let value = environment[key], !value.isEmpty else { return nil }
      return value
    }

    var missing: [String] = []
    let llmBaseURLString = required("LLM_BASE_URL", missing: &missing)
    let llmAPIKey = required("LLM_API_KEY", missing: &missing)
    let llmModel = required("LLM_MODEL", missing: &missing)
    let botPDSURLString = required("BOT_PDS_URL", missing: &missing)
    let botHandle = required("BOT_HANDLE", missing: &missing)
    let botAppPassword = required("BOT_APP_PASSWORD", missing: &missing)
    guard missing.isEmpty else { throw ConfigError.missing(missing) }

    guard let botPDSURL = URL(string: botPDSURLString) else {
      throw ConfigError.missing(["BOT_PDS_URL (not a valid URL)"])
    }
    guard let llmBaseURL = URL(string: llmBaseURLString) else {
      throw ConfigError.missing(["LLM_BASE_URL (not a valid URL)"])
    }

    self.llmBaseURL = llmBaseURL
    self.llmAPIKey = llmAPIKey
    self.llmModel = llmModel

    if let reviewModel = optional("LLM_REVIEW_MODEL") {
      let reviewBaseURLString = optional("LLM_REVIEW_BASE_URL") ?? llmBaseURLString
      guard let reviewBaseURL = URL(string: reviewBaseURLString) else {
        throw ConfigError.missing(["LLM_REVIEW_BASE_URL (not a valid URL)"])
      }
      reviewLLM = ReviewLLM(
        baseURL: reviewBaseURL,
        apiKey: optional("LLM_REVIEW_API_KEY") ?? llmAPIKey,
        model: reviewModel,
      )
    } else {
      reviewLLM = nil
    }

    targetHandle = environment["TARGET_HANDLE"] ?? "maclong.dev"
    targetDID = environment["TARGET_DID"] ?? "did:web:id.maclong.dev"

    self.botPDSURL = botPDSURL
    self.botHandle = botHandle
    self.botAppPassword = botAppPassword
    botDisplayName = environment["BOT_DISPLAY_NAME"] ?? "Fairness Bot"
    botProfileDescription =
      environment["BOT_PROFILE_DESCRIPTION"]
      ?? "Automated account that encourages fair, evidence-based discussion."
    botAvatarPath = URL(
      fileURLWithPath: environment["BOT_AVATAR_PATH"] ?? "assets/logo.png",
    )

    jetstreamURL = URL(
      string: environment["JETSTREAM_URL"]
        ?? "wss://jetstream2.us-east.bsky.network/subscribe",
    )!
    appViewURL = URL(
      string: environment["APP_VIEW_URL"] ?? "https://public.api.bsky.app",
    )!
    stateDirectory = URL(
      fileURLWithPath: environment["STATE_DIR"] ?? "state",
      isDirectory: true,
    )

    if let thresholdString = optional("FAIRNESS_SCORE_THRESHOLD") {
      guard let threshold = Int(thresholdString) else {
        throw ConfigError.missing(["FAIRNESS_SCORE_THRESHOLD (not a valid integer)"])
      }
      fairnessScoreThreshold = threshold
    } else {
      fairnessScoreThreshold = 60
    }

    isSelfReviewEnabled = ["true", "1"].contains(
      (optional("SELF_REVIEW_ENABLED") ?? "false").lowercased())
  }

  /// Redacted on purpose: never let the app password or API key end up in logs,
  /// error messages, or an accidental `print(config)`.
  public var description: String {
    """
    Config(
      targetHandle: \(targetHandle), targetDID: \(targetDID),
      botHandle: \(botHandle), botPDSURL: \(botPDSURL.absoluteString),
      botDisplayName: \(botDisplayName),
      botProfileDescription: \(botProfileDescription),
      llmBaseURL: \(llmBaseURL.absoluteString), llmModel: \(llmModel),
      reviewLLM: \(reviewLLM?.model ?? "<disabled>"),
      jetstreamURL: \(jetstreamURL.absoluteString), appViewURL: \(appViewURL.absoluteString),
      stateDirectory: \(stateDirectory.path), fairnessScoreThreshold: \(fairnessScoreThreshold),
      isSelfReviewEnabled: \(isSelfReviewEnabled),
      botAppPassword: <redacted>, llmAPIKey: <redacted>
    )
    """
  }
}
