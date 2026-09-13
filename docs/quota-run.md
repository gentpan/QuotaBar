# Quota Run — design and wire contract

Quota Run is QuotaBar's opt-in leaderboard: how fast people burn through a
subscription's quota window (Codex Pro's week, Claude Max's 5 hours…), with a
public profile that lists the builder's projects. Track on Quota Bar, compete on
Quota Run.

This document is the contract between three parts built in parallel. When code
and this file disagree, this file wins until it is changed on purpose.

- **App** (`Sources/`): records every quota reading locally (personal records,
  no account needed), and — only after the owner joins — signs and uploads
  them from one ranked device.
- **Server** (`server/run/`): a Python 3.13 service (standard library +
  `cryptography`, both on the host) with SQLite, behind Caddy at
  `https://quota.bar/api/run/v1/`. It verifies signatures, stores readings and
  computes runs, tiers and boards. **The server decides every result**; the app
  never uploads a finished result.
- **Web** (`site/`, `web/`): `quota.bar/leaderboard` (`/zh/leaderboard`) and
  public profiles `quota.bar/@username`, static pages reading the public API.

## Principles

1. **Local first, opt-in upload.** Personal records work with no account. The
   upload is off until the owner joins and agrees on a consent screen that says
   exactly what leaves the Mac. The site's "usage stays on this Mac" promise
   stays true for everyone who has not joined.
2. **Never uploaded:** credentials, tokens, cookies, API keys, prompts, code,
   file or project paths, model outputs, the account email in the clear.
3. **Uploaded after joining:** provider, plan name, per-window used percent,
   reset time, observation time, the window's length and scope, a one-way digest
   of the provider account, and per-minute token counts from local CLI logs.
4. **Readings, not results.** The server turns a time series into a run; a
   client claiming "100% in 2h" is meaningless.
5. **No money prizes.** Cheating a desktop client cannot be made impossible,
   only expensive and visible. Honour and sharing, not cash.

## Identity

- **Account** = one person, one public username.
- **Device** = one Mac running QuotaBar with its own P-256 signing key: in the
  Secure Enclave when available (`SecureEnclave.P256.Signing.PrivateKey`), else
  a software `P256.Signing.PrivateKey` kept in the login keychain. The private
  key never leaves the Mac. An account may have several devices.
- **Ranked device**: exactly one per account; only its readings count. The first
  device is ranked. Changing it has a **7-day cooldown**.
- **Provider account binding**: the digest of the provider's account (email)
  can belong to one Quota account only. Seen under two Quota accounts → both
  runs for that digest are `flagged` ("disputed") until resolved.
- No passwords and no third-party sign-in in v1: the device key *is* the login.
  Adding a Mac: on a joined Mac, "Pair another Mac" shows an 8-character code
  (valid 10 minutes); the new Mac registers with that code instead of a username.

### Username

`^[a-z0-9][a-z0-9_-]{2,19}$`, case-folded, unique. Reserved: `admin api app
about help leaderboard run quota quotabar settings support www zh en me user
users login logout signup register profile u`.

## Signing

All keys and signatures are base64url **without padding**.

- Public key: X9.63 uncompressed point, 65 bytes (`publicKey.x963Representation`).
- Signature: ECDSA P-256 over SHA-256, DER encoded (`signature.derRepresentation`).
  Python: `EllipticCurvePublicKey.from_encoded_point(SECP256R1(), raw).verify(der, message, ECDSA(SHA256()))`.

Every authenticated request carries:

| Header | Value |
|---|---|
| `X-Quota-Device` | device id from registration (absent on `register`) |
| `X-Quota-Timestamp` | Unix seconds, within ±300 s of the server clock |
| `X-Quota-Nonce` | 16 random bytes, base64url; unique per device for 10 minutes |
| `X-Quota-Signature` | signature of the canonical string below |

Canonical string (UTF-8, lines joined by `\n`, no trailing newline):

```
quota-run-v1
<METHOD upper-case>
<path, no query string, e.g. /api/run/v1/snapshots>
<X-Quota-Timestamp>
<X-Quota-Nonce>
<lower-case hex SHA-256 of the raw body bytes; of the empty string when there is no body>
```

For `register`, the server verifies with `publicKey` from the body.

Account digest (computed on the Mac):

```
accountDigest = hex(SHA-256("quota-run-account-v1\n" + provider + "\n" + account.trimmed.lowercased))
```

The server stores `HMAC-SHA256(server_secret, accountDigest)`, never the digest as received.

## Data model

### Snapshot (one window, one reading)

```json
{
  "provider": "codex",
  "plan": "Pro 20x",
  "accountDigest": "3f1c…",
  "windowKey": "604800:",
  "windowTitle": "Weekly window",
  "windowSeconds": 604800,
  "scope": null,
  "usedPercent": 36.5,
  "resetsAt": 1789999200,
  "observedAt": 1789420000,
  "source": "api"
}
```

- `provider`: a `ProviderID` raw value (`codex`, `claude`, `cursor`, `kimi`, …).
- `windowKey`: `"<windowSeconds or 0>:<scope or empty>"` — language-independent
  for plan windows; scoped windows carry the provider's own scope name (model
  names are not translated).
- `plan` may be null. The server normalises it for grouping: lower-case,
  keep `[a-z0-9]` only (`"Pro 20x"` → `pro20x`, `"Pro_Plus"` → `proplus`).
- `usedPercent` 0–100. `resetsAt` may be null (balances, some monthly plans).
- `source`: `api` (read from the provider) or `local` (derived from local files).

### Activity (evidence of real work)

```json
{ "minute": 1789419960, "source": "codex", "tokens": 12840 }
```

`minute` is floored to the minute; `source` is a cost source (`claude`, `codex`,
`opencode`); `tokens` are all tokens that minute from the local session logs.

### Run (computed by the server, and by the app for personal records)

A run is one reset period of one window for one provider account:
group key `(user, provider, planNorm, windowKey, resetsAt rounded to 5 minutes)`.

- **Rankable** when `windowSeconds` is between 3,600 and 2,764,800 (1 h – 32 d)
  and `resetsAt` is not null. `windowStart = resetsAt − windowSeconds`.
- `peakPercent` = highest `usedPercent` observed.
- `secondsTo50/90/100` = first `observedAt` with `usedPercent ≥ 50 / 90 / 99.5`,
  minus `windowStart`. Null when not reached.
- `completedAt` = `windowStart + secondsTo100`.
- **Speed board** ranks `secondsTo100` ascending (only runs that reached 100%).
  **Peak board** ranks `peakPercent` descending, ties by earlier `completedAt`
  or last observation.

### Tiers

A run is **verified** when all of:

1. `accountDigest` present and bound to this user only;
2. monotonic: no reading drops more than 2 points below an earlier one in the run;
3. plausible: no rise of more than 60 points between readings less than 5 minutes apart;
4. covered: the first reading is at most 50%, and no gap between consecutive
   readings from the first reading to the 100% reading (or the last reading)
   exceeds 20 minutes;
5. active: for `codex` and `claude`, at least one activity minute with tokens > 0
   for the matching source between the first reading and completion (or last reading).

Otherwise **standard**, unless rule 2 or 3 fails or the account is disputed →
**flagged** (kept for review, excluded from boards and profiles).

Boards show verified and standard runs with a tier badge; `tier=verified`
filters. Readings from non-ranked devices are stored but never counted.

### Season

ISO-8601 week (UTC) of `windowStart`, written `2026-W37`. `season=current`
means the week containing now; `all` means every season (best run per user).

## API

Base `https://quota.bar/api/run/v1`. JSON in and out, UTF-8. Errors:
`{"error": "<code>", "message": "<English sentence>"}` with 400/401/403/404/409/413/429.
Bodies above 1 MB → 413. Authenticated writes: at most one request every 10 s per
device (burst 5) → 429.

### Public

| Method & path | Returns |
|---|---|
| `GET /stats` | `{users, runs, verifiedRuns, providers, updatedAt}` |
| `GET /boards?region=global` | `{boards: [{provider, plan, planLabel, windowKey, windowSeconds, windowTitle, runners, season}]}` — boards with at least one rankable run in the current season, most runners first |
| `GET /leaderboard?provider=codex&plan=pro20x&window=604800:&metric=speed&season=current&region=global&tier=all&limit=100` | `{board: {...}, season, metric, entries: [{rank, username, displayName, value, unit, tier, achievedAt, peakPercent}], updatedAt}` — one entry per user (their best run); `unit` is `seconds` or `percent` |
| `GET /users/<username>` | `{username, displayName, bio, region, joinedAt, links: {website, github, x}, projects: [...], bests: [{provider, plan, planLabel, windowKey, windowSeconds, windowTitle, metric, value, rank, runners, percentile, tier, season}], recent: [run...], stats: {runs, verifiedRuns, providers, activeDays}}` |

`region` is `global` or `china` (a user attribute, chosen when joining; used as a
filter). Omit it for everyone.

### Authenticated

| Method & path | Body | Returns |
|---|---|---|
| `POST /register` | `{username, displayName, region, publicKey, deviceName, platform: "macos", appVersion}` or `{pairCode, publicKey, deviceName, platform, appVersion}` | `201 {user: {username, displayName, region}, deviceId, ranked}`; `409 username_taken`, `400 invalid_username`, `404 pair_code_invalid` |
| `GET /me` | — | `{user: {username, displayName, bio, region, links, joinedAt}, devices: [{deviceId, name, ranked, lastSeenAt, current}], rankedChangeAvailableAt, lastUploadAt, projects}` |
| `POST /snapshots` | `{snapshots: [≤500], activity: [≤1440]}` | `{accepted, duplicates, rejected: [{index, reason}]}` — `observedAt` must be within the last 7 days and at most 300 s in the future; duplicates by `(device, provider, windowKey, observedAt)` |
| `PUT /profile` | `{displayName ≤40, bio ≤160, region, links: {website, github, x}}` | `{user}` |
| `PUT /projects` | `{projects: [≤12 {name ≤40, url, description ≤140, github?, builtWith: [provider…]}]}` | `{projects}` — URLs must be `https://` |
| `POST /devices/ranked` | `{deviceId}` | `{devices}`; `409 {error: "cooldown", availableAt}` |
| `POST /pair` | — | `{code, expiresAt}` |
| `DELETE /devices/<deviceId>` | — | `{devices}` (not the current device) |
| `DELETE /account` | — | `204`; every row for the user and devices is deleted |

## Web

- `quota.bar/leaderboard` and `quota.bar/zh/leaderboard`: board picker (provider
  → plan → window), metric (fastest to 100% / highest peak), season (this week,
  last week, all time), region, verified-only switch; rows with rank, name, value
  (`2h 37m` / `98%`), tier badge, time. Empty state explains how to join from the
  app. `quota.run` redirects here.
- `quota.bar/@username` (Caddy rewrites to `/u.html`, `/zh/@username` to
  `/zh/u.html`): name, bio, links, per-board bests with rank and top-percentile,
  recent runs, projects as cards. 404 state when the user does not exist.
- A demo mode (`?demo=1`) renders fixture data so the pages can be previewed
  without the API.

## App

- **Records** (Settings → Quota Run, no account): every successful reading is
  written to a local run ledger (Application Support, last 60 days). The page
  shows runs in progress and personal bests per provider/plan/window: fastest to
  100%, time to 50/90%, highest peak. A best can be shared as an image.
- **Join**: username, display name, region, then a consent sheet listing exactly
  what is uploaded and what never is. Joining creates the device key and
  registers. After that: upload status, ranked device (with the cooldown),
  profile and projects editors, "Pair another Mac", "View my profile", and
  "Leave Quota Run" (deletes all server data, forgets the key).
- **Upload**: after each refresh, readings not yet sent plus activity minutes
  since the last upload, batched, at most every 60 s, queued on disk while offline,
  retried with backoff. Only when joined and this Mac is the ranked device.
