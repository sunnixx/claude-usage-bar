# ClaudeUsageBar — Design

**Date:** 2026-08-04
**Status:** Approved

## Purpose

A macOS menu bar app that shows, at a glance, how much of the Claude
subscription rate limit has been consumed. It answers one question: *how much
headroom is left before a limit cuts off work mid-task?*

It is a readout. It does not notify, does not log history, and does not
compute cost.

## Scope

**In scope:** subscription rate limits (5-hour session window, 7-day window,
per-model weekly scopes) read live from Anthropic.

**Out of scope:** local token/cost accounting from `~/.claude/projects/*.jsonl`;
Anthropic Console org spend via the Admin API; notifications; usage history or
charts. These were considered and deliberately excluded.

## Data source

`GET https://api.anthropic.com/api/oauth/usage`

Headers:

```
Authorization: Bearer <access token>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-usage-bar/<version> (macOS)
```

The access token is the one Claude Code already stores in the login Keychain as
a generic password with service `Claude Code-credentials`. Its value is JSON;
the token is at `claudeAiOauth.accessToken`.

Verified live response (2026-08-04), abridged:

```json
{
  "five_hour": { "utilization": 37.0, "resets_at": "2026-08-04T09:00:00.782828+00:00",
                 "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
  "seven_day": { "utilization": 26.0, "resets_at": "2026-08-08T07:00:00.782854+00:00" },
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    { "kind": "session",       "group": "session", "percent": 37, "severity": "normal",
      "resets_at": "2026-08-04T09:00:00.782828+00:00", "scope": null, "is_active": true },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 26, "severity": "normal",
      "resets_at": "2026-08-08T07:00:00.782854+00:00", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 10, "severity": "normal",
      "resets_at": "2026-08-08T06:59:59.783316+00:00",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
      "is_active": false }
  ],
  "extra_usage": { "is_enabled": false, "utilization": null },
  "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
             "percent": 0, "enabled": false }
}
```

Most fields in this payload are `null` on any given plan. The decoder treats
the `limits` array as the authoritative source and the top-level `five_hour` /
`seven_day` objects as a fallback, so the app tolerates fields appearing and
disappearing.

## Architecture

A Swift package (SPM) with one executable target, built into a menu bar–only
`.app` bundle. `LSUIElement = true`: no Dock icon, no main window. Minimum
target macOS 14.

Repository: `~/Developer/claude-usage-bar`, its own git repo. Deliberately not
inside the OneDrive business-documents folder, which would sync build output.

### Components

Data flows one direction. There is no shared mutable state between components.

```
UsagePoller ──> UsageSnapshot ──> MenuBarController
     │
     ├─ KeychainTokenStore
     └─ UsageClient
```

**`KeychainTokenStore`**
Reads the generic password for service `Claude Code-credentials` via
`SecItemCopyMatching`, parses the JSON, returns the access token.
Returns a typed absence (`.noToken`) rather than throwing when the item is
missing, since "Claude Code not signed in" is an expected state, not an error.
Depends on: Security.framework.

**`UsageClient`**
Performs one HTTPS GET with the headers above and decodes the body into
`UsageSnapshot`. Maps HTTP 401 to a distinct `.unauthorized` error so the UI can
distinguish an expired token from a network failure. Depends on: URLSession,
`KeychainTokenStore`.

**`UsageSnapshot`**
An immutable value type. Fields: `session` (percent, resetsAt), `week`
(percent, resetsAt), `scopedWeekly` (array of label/percent/resetsAt), and
`fetchedAt`. Contains no networking or formatting logic — formatting lives in
the controller so the snapshot stays trivially testable.

**`UsagePoller`**
Owns a 60-second repeating timer and the error/backoff state machine. Exposes
the current state: `.loading`, `.loaded(UsageSnapshot)`, `.stale(UsageSnapshot,
since: Date)`, `.noToken`, `.unauthorized`. Takes an injected clock and an
injected client so its behaviour is testable without real time or network.

**`MenuBarController`**
Owns the `NSStatusItem`. Renders the title from poller state and rebuilds the
`NSMenu` on open. The only component that touches AppKit.

## User interface

### Menu bar item

A gauge glyph followed by the 5-hour session percentage: `◔ 37%`.

The glyph is a monochrome template image, so it adapts automatically to light
mode, dark mode, and tinted menu bars.

The percentage text renders in the default menu bar colour below 90%, and in
red at 90% or above. This is the only visual state change; the app remains
silent, with no notifications at any threshold.

When no value is available (`.noToken`, `.unauthorized`, or a first fetch that
has never succeeded), the title is `◔ —`.

### Dropdown menu

```
Session (5h)        37%  ▓▓▓▓░░░░░░   resets in 1h 12m
This week           26%  ▓▓▓░░░░░░░   resets Sat, Aug 8
  └ Fable           10%
─────────────────────────────
Updated 12:04
Refresh Now                      ⌘R
Launch at Login                   ✓
Quit                             ⌘Q
```

Per-model rows are rendered only for `weekly_scoped` entries actually present
in the response, so the menu stays short on plans that do not report them.

Reset times are formatted relative when under 24 hours away ("resets in 1h
12m") and as a weekday-and-date otherwise ("resets Sat, Aug 8"), in the user's
local timezone.

"Launch at Login" toggles via `SMAppService.mainApp`.

## Refresh policy

- Poll every 60 seconds.
- Refresh immediately when the menu is opened, so an opened menu is never
  showing data more than a moment old.
- "Refresh Now" (⌘R) forces a fetch and resets any backoff.

## Error handling

The app never blanks a good value because of a transient failure.

| Condition | Menu bar | Menu message |
|---|---|---|
| No Keychain item | `◔ —` | "Not signed in to Claude Code" |
| HTTP 401 | `◔ —` | "Token expired — open Claude Code to refresh" |
| Network error, previous value known | last value, dimmed | "Offline — updated 11:58" |
| Network error, no previous value | `◔ —` | "Can't reach Anthropic" |

On consecutive failures the poll interval backs off from 60 seconds toward a
5-minute ceiling, and resets to 60 seconds on the first success.

### Token refresh is out of scope, by design

The app reads the OAuth token and never refreshes or rewrites it. Claude Code
owns that token and rotates it; a second process attempting a refresh could
invalidate the running CLI session. When the token expires, the app says so and
defers to Claude Code.

## Testing

- **Decoding:** `UsageSnapshot` decoded from captured JSON fixtures — the full
  response above, a null-heavy variant with no `weekly_scoped` entries, and a
  variant with `limits` absent (exercising the `five_hour` / `seven_day`
  fallback).
- **Formatting:** percent → menu bar title, including the 90% red threshold at
  its boundaries; `resets_at` → relative and absolute strings, including the
  24-hour crossover.
- **Poller:** state transitions, backoff growth and reset, and retention of the
  last good snapshot across failures — driven by an injected clock and a stub
  client.
- **Not automated:** `NSStatusItem` and `NSMenu` rendering, and the
  `SMAppService` login-item toggle. Both are verified by hand; mocking AppKit
  would cost more than it detects.

## Open questions

None.
