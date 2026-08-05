# atproto-fairness-bot

Watches replies to an AT Protocol / Bluesky account. Only replies that are
actually pushing back on or disagreeing with the point — debate, not general
conversation — get a fairness judgment at all; friendly agreement,
compliments, jokes, and unrelated banter are skipped entirely. For debate
replies, a configured OpenAI-compatible LLM scores how fairly the reply
engages—with evidence and substance rather than insults, sarcasm, or
strawmanning—on a scale of 0-100, and only when that score falls below a
configurable threshold, the bot posts a short, polite public reply. Every
posted reply is paired with a `dev.maclong.feed.verdict` record (see [Verdict
lexicon](#verdict-lexicon)) published to the bot's own repo, so its judging
activity is a structured, public part of the network.

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
mise run check-post https://bsky.app/profile/someone.bsky.social/post/3kxyz
mise run check-post at://did:plc:example/app.bsky.feed.post/3kxyz
# Explicitly publish the suggested response if (and only if) it is unfair:
mise run check-post --post https://bsky.app/profile/someone.bsky.social/post/3kxyz
```

Without `--post`, `check` is **dry-run**: it fetches the post and its thread
context, then prints `FAIR`/`UNFAIR` with the fairness score out of 100 (or
`N/A` if the reply isn't a debate response at all), the model reasoning, and
any suggested reply. With `--post`, it publishes the
suggested reply only for an unfair verdict, records the target URI in
`state/` so the watcher cannot post a duplicate, and publishes a
`dev.maclong.feed.verdict` record alongside it. The supplied post must be a
reply to the configured target account.

## How the watcher works

1. Subscribes to new `app.bsky.feed.post` records through Jetstream.
2. Keeps only direct replies whose **immediate parent** is authored by the
   configured target account. Replies to somebody else's reply are ignored,
   even when that nested thread appears below one of the target's posts.
3. Fetches the root and parent posts from the public Bluesky AppView.
4. Asks the configured LLM whether the reply is a debate response at all
   (disagreement, pushback, criticism) as opposed to general conversation.
   Non-debate replies stop here — no score, no reply. Debate replies get a
   fairness score (0-100) and reasoning.
5. When the score is below `FAIRNESS_SCORE_THRESHOLD`, posts the model's
   concise suggested reply from the bot account, then publishes a
   `dev.maclong.feed.verdict` record referencing both posts (see [Verdict
   lexicon](#verdict-lexicon)).
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
- `LLM_REVIEW_MODEL` — optional second-model gate. When set, the reviewer sees
  the first verdict and draft, then either rejects publication or supplies the
  final, minimally edited reply. `LLM_REVIEW_BASE_URL` and `LLM_REVIEW_API_KEY`
  are optional overrides; otherwise the primary provider credentials are used.
- `BOT_PDS_URL`, `BOT_HANDLE`, `BOT_APP_PASSWORD` — the bot PDS credentials.
- `BOT_DISPLAY_NAME`, `BOT_PROFILE_DESCRIPTION` — the bot's Bluesky profile.
  The watcher applies these through the authenticated PDS API at startup, including
  Bluesky's native `bot` self-label so the account is visibly marked as automated.
  The bot's avatar is applied the same way, uploaded from `assets/logo.png`
  (override with `BOT_AVATAR_PATH`); a missing or failed avatar upload never
  blocks the display name/description update.
- `FAIRNESS_SCORE_THRESHOLD` — optional, defaults to `60`. Replies scoring
  below this (out of 100) are treated as unfair and get a callout reply.

The target defaults to `maclong.dev` / `did:web:id.maclong.dev`. Override
`TARGET_HANDLE` and `TARGET_DID` to protect another account.

Apply the configured `BOT_DISPLAY_NAME` and `BOT_PROFILE_DESCRIPTION` immediately.
This also enables Bluesky's native automation label:

```sh
mise run setup-profile
```

The watcher also applies the profile at startup.

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
mise run check-post https://bsky.app/profile/someone.bsky.social/post/3kxyz
```

Verify that a fair reply prints `FAIR` and that an unfair reply prints `UNFAIR`
with a suggested reply. Add `--post` only when you intend to publish that reply.

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

## Verdict lexicon

Every reply the bot actually posts is paired with a `dev.maclong.feed.verdict`
record, published to the bot's own PDS repo — a structured, public log of the
bot's judging activity, distinct from the reply thread itself. Its schema
lives at [`lexicons/dev.maclong.feed.verdict.json`](lexicons/dev.maclong.feed.verdict.json)
and contains:

- `subject` — strong ref to the reply post that was judged
- `reply` — strong ref to the bot's own callout reply
- `score` — the fairness score (0-100) that triggered the reply
- `reasoning` — the judge's explanation
- `replyText` — the exact text posted
- `createdAt` — publish timestamp

Verdict records are only published when a reply is actually posted (never for
fair verdicts or dry-run `check` calls), and a publish failure never blocks or
retries the reply itself — it's a best-effort record of an action already
taken.

## Running your own instance

Fork the repository, provision a dedicated bot account (on a separate Cirrus
PDS or any PDS that supports the required account lifecycle), fill in your own
`.env`, and run the same commands. No account or LLM credential is hardcoded in
the Swift sources.
