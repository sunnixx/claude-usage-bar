# ClaudeUsageBar — ChatGPT Codex as a Second Provider

**Date:** 2026-08-15
**Status:** Approved
**Extends:** `2026-08-04-claude-usage-bar-design.md` (what the app does and why)
and `2026-08-15-cross-platform-design.md` (the three-platform architecture).
Both remain authoritative where this document is silent.

## Purpose

Show ChatGPT Codex subscription usage beside Claude usage, in the same app,
using the same pattern: one glanceable readout per provider in the menu bar,
detail in the dropdown, silent, read-only.

## Scope

**In scope:** Codex rate-limit windows read live from OpenAI, rendered with the
existing row treatment; both providers' marks and percentages in the menu bar.

**Out of scope:** OpenAI Platform API-key billing (a different product with a
different endpoint), credit balances, spend controls, plan upgrades, and any
write action against either provider.

## Data source

Verified live on 2026-08-15:

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access token>
ChatGPT-Account-Id: <account id>
User-Agent: claude-usage-bar/<version> (<platform>)
```

Abridged 200 response, with the numbers replaced by fabricated ones:

```json
{
  "plan_type": "free",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 12,
      "limit_window_seconds": 2592000,
      "reset_after_seconds": 1900000,
      "reset_at": 1789416863
    },
    "secondary_window": null
  },
  "additional_rate_limits": null,
  "credits": { "has_credits": false, "unlimited": false, "balance": null }
}
```

Codex normally surfaces rate limits as HTTP **response headers**
(`x-codex-primary-used-percent` and family) on ordinary API calls. Those are
useless here — reading them costs quota. The endpoint above returns the same
data on a plain GET, which is why this feature is possible at all.

Like Anthropic's usage endpoint, this one is undocumented and can change
without notice. The decoder must fail cleanly rather than crash.

### Credentials

`~/.codex/auth.json`, mode 0600, on **every** platform — there is no Keychain
path for Codex, so one file store serves macOS, Linux and Windows. Shape:

```
auth_mode, tokens.{access_token, id_token, refresh_token, account_id}, last_refresh
```

`$CODEX_HOME` overrides the directory when set.

## Constraints

**Read-only, on both providers.** Codex owns its token and rotates it — the
file carries `refresh_token` and `last_refresh`. The store opens the file
read-only and contains no write, create, truncate or delete call, exactly as
`CredentialsFileTokenStore` does for Claude.

**No credential material in logs, errors, or on disk.** Unchanged.

**The Codex response carries PII** — `email`, `user_id`, `account_id`. The
decoder reads only `plan_type` and the rate-limit windows. Those fields are
never stored, logged, displayed, or written to a test fixture. The committed
fixtures use fabricated identifiers.

**The Claude readout does not change.** Its decoder, its windows, its wording
and its row rendering stay as they are. This work is additive; the existing
tests are the guard.

## Model changes

The core is currently Anthropic-shaped (`session`, `week`, `scopedWeekly`).
Two providers with different window structures make that dishonest, so the
model generalises:

```swift
public enum Provider: String, CaseIterable, Sendable {
    case anthropic
    case codex
}

public struct UsageWindow: Equatable, Sendable {
    public let label: String      // "Session (5h)", "This week", "Fable", "30 days"
    public let percent: Int
    public let resetsAt: Date?
    public let isScoped: Bool     // renders indented
}

public struct ProviderSnapshot: Equatable, Sendable {
    public let provider: Provider
    public let planName: String?  // Codex "free"; nil for Anthropic
    public let windows: [UsageWindow]
    public let fetchedAt: Date
}
```

The Anthropic decoder keeps its existing logic — including the `limits`-array
preference and the `five_hour`/`seven_day` fallback — and maps its result into
`ProviderSnapshot` with the labels it already produces.

`ScopedWindow` is absorbed: a per-model row becomes a `UsageWindow` with
`isScoped = true`, which is what the existing `MenuRow.isIndented` already
consumes. The first window a provider reports is its primary, which is what the
menu bar segment reads — Anthropic emits session first today, so that ordering
is already correct and must be preserved by the mapping.

### Codex window labels

Codex window names are not fixed: the plan decides them. `primary_window` is a
30-day window on `free` and a 5-hour window on paid plans. Labels are therefore
**derived from `limit_window_seconds`** rather than hardcoded:

| Seconds | Label |
|---|---|
| < 86400 | `"{n}h"` — e.g. `5h` |
| exactly 604800 | `"This week"` |
| multiple of 86400 | `"{n} days"` — e.g. `30 days` |
| anything else | `"{n}h"` rounded |

`secondary_window` and each entry in `additional_rate_limits` follow the same
rule; `additional_rate_limits` entries render scoped (indented), matching
Anthropic's per-model rows.

`reset_at` is a Unix epoch integer, not an ISO 8601 string. It converts to
`Date` directly and then reuses the existing relative/absolute formatting.

## Refresh policy

`UsageRefreshPolicy` becomes **per provider**. Two independent state machines,
each with its own backoff, staleness and token-rotation tolerance.

This is the point of the split: Codex being rate-limited, signed out, or
unreachable must never blank the Claude reading, and the reverse. The two
rulings already recorded apply to each provider separately — a confirmed
sign-out drops that provider's value permanently, a single auth failure does
not.

Poll cadence stays 60s. Both providers are fetched per tick, each behind its
own in-flight guard, so a slow provider cannot stall the other.

## Menu bar

```
⚹ 37%   ◉ 0%
```

Each available provider contributes a mark plus **its primary window's**
percentage, in fixed order — Anthropic, then Codex — so the shape never moves.

"Primary" means the window that gates you soonest: Anthropic's five-hour
session, Codex's `primary_window`. For Anthropic this is exactly what the menu
bar shows today, which is what keeps the promise that the Claude readout does
not change. It is deliberately *not* "whichever window is highest" — that would
make the Claude number start moving between the session and weekly figures.

Existing colour rules apply per segment: red at or above 90%, dimmed while that
provider's data is stale, critical beating stale.

A provider that is not signed in is **omitted entirely**. With neither
available the item shows today's `—`.

### The marks

Drawn in code as monochrome template images, not bundled brand assets, so they
adapt to light mode, dark mode and tinted menu bars like the current gauge
glyph. They are recognisable renditions rather than pixel-exact logos.

Using each company's mark to label whose usage is whose is nominative — it
identifies the service the number came from. This is noted here because the
repository is public. Monochrome letter marks are a drop-in alternative if that
is ever preferred; nothing else in the design depends on the choice.

## Dropdown

Provider sections in the same fixed order, each headed by the provider name and
its plan when one is reported. Row rendering is unchanged — drawn meters on
macOS, text rows on Linux and Windows.

```
CLAUDE
  Session (5h)   37%  ▓▓▓░░░░░  4h 55m
  This week      26%  ▓▓░░░░░░  Sat, Aug 22
    └ Fable      10%  ▓░░░░░░░

CODEX  ·  free
  30 days         0%  ░░░░░░░░  resets Sep 14
────────────────────────────
Updated 13:44
```

A provider in an error state shows its existing message row under its own
heading, so a Claude failure and a Codex failure are never confused.

## Error handling

Per provider, unchanged in substance from the existing table: missing
credentials read as "not signed in" rather than an error; 401 as an expired
token; transport, bad status and decode failures retain the last good value and
mark it stale.

One wording correction applies to both providers, carried over from a known
defect: a stale row currently reads `Offline` regardless of cause, which is
wrong when the cause is an HTTP 429 or a decode failure. Stale rows name the
actual cause.

## Testing

- **Codex decoding** — captured fixtures with fabricated identifiers: the full
  response, a `secondary_window: null` variant (the free-plan shape observed
  live), one with `additional_rate_limits` populated, and a malformed body.
- **Window labels** — the seconds-to-label table above, at its boundaries.
- **Token store** — reuses the injected-path pattern: valid, absent, malformed,
  empty token, `$CODEX_HOME` override.
- **Policy independence** — one provider failing, being signed out, or going
  stale leaves the other's state untouched.
- **Menu bar composition** — both providers, Claude only, Codex only, neither.
- **PII** — a test asserts the decoder's output contains no e-mail, user id or
  account id.
- **Not automated** — the drawn marks and the tray backends, as before.

## Out of scope

Unchanged from the earlier designs: no notifications, no history, no cost
accounting, no token refresh, no writes. Additionally: no OpenAI Platform
API-key support, no credits or spend-control display, and no per-provider
configuration UI — if both are signed in, both are shown.

## Open questions

None.
