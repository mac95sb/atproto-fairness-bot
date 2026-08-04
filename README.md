# atproto-fairness-bot

Watches replies to an AT Protocol / Bluesky account, asks a configured
OpenAI-compatible LLM whether each reply engages fairly—with evidence and
substance rather than insults, sarcasm, or strawmanning—and only when it is
judged **unfair**, posts a short, polite public reply. Fair replies get no
response.

The bot is a Swift process that watches the network through
[Jetstream](https://github.com/bluesky-social/jetstream), a filtered JSON
firehose. It uses [pitchfork](https://pitchfork.jdx.dev) for restart and
login-time supervision.

The target account, bot account, and LLM provider are configured only through
`.env`. Chutes is supplied as the template configuration, but any
OpenAI-compatible chat-completions endpoint works. Its command-line interface
uses [swift-argument-parser](https://github.com/apple/swift-argument-parser),
with built-in `--help` support.

## Commands

```sh
fairness-bot watch                         # default: watch Jetstream continuously
fairness-bot check <at-uri-or-bsky-url>    # inspect one existing reply
```

`check` accepts either an AT-URI or a standard Bluesky post URL:

```sh
mise run check-post -- https://bsky.app/profile/someone.bsky.social/post/3kxyz
mise run check-post -- at://did:plc:example/app.bsky.feed.post/3kxyz
```

It is always **dry-run**: it fetches the post and its thread context, prints
`FAIR` or `UNFAIR`, the model reasoning, and any suggested reply—but never posts
and never changes the reply-deduplication log. The supplied post must be a reply
to the configured target account. This is the safe way to assess a model result
before running the watcher.

## How the watcher works

1. Subscribes to new `app.bsky.feed.post` records through Jetstream.
2. Keeps only direct replies whose **immediate parent** is authored by the
   configured target account. Replies to somebody else's reply are ignored,
   even when that nested thread appears below one of the target's posts.
3. Fetches the root and parent posts from the public Bluesky AppView.
4. Requests a fairness verdict from the configured LLM.
5. When unfair, posts the model's concise suggested reply from the bot account.
6. Persists its Jetstream cursor and replied-to URIs in `state/`, so restart
   recovery catches up on retained events without duplicate replies.

Jetstream retention is finite. After downtime longer than the selected public
instance retains events, replies from that gap cannot be replayed.

## One-time setup

### 1. Provision a separate bot PDS

The existing `id.maclong.dev` deployment is [Cirrus](https://github.com/ascorbic/cirrus),
which is intentionally **single-user**. It does not implement
`com.atproto.server.createAccount`, so trying to create a second account there
returns `MethodNotImplemented`.

Provision `fairness.maclong.dev` as its own Cirrus Worker instead. The template
and instructions live at [`../portfolio/pds/fairness`](../portfolio/pds/fairness/README.md).
Once deployed, use its CLI to generate an app password:

```sh
cd ../portfolio/pds/fairness
npx pds app-password create --name fairness-bot
```

Treat every password previously entered in a terminal transcript or chat as
compromised and rotate it. Store only the generated app password in `.env`.

### 2. Configure the bot

```sh
cp .env.example .env
```

Set all required values:

- `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL` — the OpenAI-compatible provider.
  The template uses Chutes; override all three together for another provider.
- `BOT_PDS_URL`, `BOT_HANDLE`, `BOT_APP_PASSWORD` — the bot PDS credentials.

The target defaults to `maclong.dev` / `did:web:id.maclong.dev`. Override
`TARGET_HANDLE` and `TARGET_DID` to protect another account.

### 3. Install and validate

```sh
mise install
mise run fmt
mise run check
mise run build
```

Formatting uses the Swift toolchain's built-in formatter: `swift format` and
`swift format lint`. No separate SwiftFormat dependency is installed.

### 4. Try a one-shot dry run

```sh
mise run check-post -- https://bsky.app/profile/someone.bsky.social/post/3kxyz
```

Verify that a fair reply prints `FAIR` and that an unfair reply prints `UNFAIR`
with a suggested reply. Neither result posts anything.

### 5. Run the watcher

Run in the foreground first:

```sh
mise run run
```

Once satisfied, enable permanent supervision:

```sh
pitchfork boot enable
mise run start
mise run logs
pitchfork boot status
```

Useful commands:

```sh
mise run stop
mise run logs
pitchfork list
```

## Development

- `mise run fmt` / `mise run fmt:check` — `swift format` / `swift format lint`
- `mise run test` — Swift Testing suite
- `mise run check` — formatter lint plus tests
- `hk` runs the same built-in Swift formatter before commits

## Running your own instance

Fork the repository, provision a dedicated bot account (on a separate Cirrus
PDS or any PDS that supports the required account lifecycle), fill in your own
`.env`, and run the same commands. No account or LLM credential is hardcoded in
the Swift sources.
