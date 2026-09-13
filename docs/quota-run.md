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
  `https://quota.run/api/v1/`. It verifies signatures, stores readings and
  computes runs, tiers and boards. **The server decides every result**; the app
  never uploads a finished result.
- **Web** (`site/leaderboard.html`, `site/u.html` → `web-run/`): the leaderboard
  at `quota.run` (`quota.run/zh/`) and public profiles `quota.run/@username`,
  static pages reading the public API. quota.bar is the product site only; its
  early `/leaderboard` and `/@username` addresses redirect here.

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

- **Account** = one person, one public username, created on **quota.run** by
  signing in with **Google**, **GitHub** or an **email code**, then choosing a
  username, display name and region. No passwords anywhere.
- **Sign-in identity** = `(provider, subject)`: `google` + the OpenID `sub`,
  `github` + the numeric user id as a string, `email` + the normalised address
  (trimmed, lower-case). An identity belongs to at most one account; an account
  has one or more (more are linked from the account page; the last cannot be
  removed). A new Google or GitHub identity whose **verified** email equals the
  email of an identity already on an account is attached to that account
  automatically (an email identity is verified by its code).
- **Device** = one Mac running QuotaBar with its own P-256 signing key: in the
  Secure Enclave when available (`SecureEnclave.P256.Signing.PrivateKey`), else
  a software `P256.Signing.PrivateKey` kept in the login keychain. The private
  key never leaves the Mac. An account may have several devices. A device joins
  an account only through **connect** (below): the app never takes a password,
  a username or an OAuth token.
- **Ranked device**: at most one per account; only its readings count. A device
  connected while the account has no ranked device becomes ranked. Changing it
  from one device to another has a **7-day cooldown**; making a device ranked
  when there is none is always allowed.
- **Provider account binding**: see *Provider accounts* below. Only readings
  that carry a provider account digest can rank, and each provider account
  (digest) is owned by one Quota account.
- The sign-in email is stored on quota.run to sign the person in; it is never
  shown on a profile, a board or to other users.

### Username

`^[a-z0-9][a-z0-9_-]{2,19}$`, case-folded, unique. Reserved: `account admin api
app about auth connect help leaderboard login logout me profile quota quotabar
register run settings signup support u user users www zh en`.

### Provider accounts

The app reads which account each provider is signed in with (the email, or
Codex's account id when there is no email) and uploads only its digest
(*Signing → Account digest*); the server keeps `HMAC(secret, digest)`. The
email never leaves the Mac.

- **Binding required to rank.** A run whose readings carry no digest is
  `unranked`: stored, never on a board, a profile best or recent runs. The app
  does not upload readings without a digest at all.
- **One owner per provider account.** `account_owners(account_hmac → user, via,
  claimedAt)`. The first Quota account whose counted readings carry a digest
  owns it (`via: "first"`). Readings from any other Quota account with that
  digest are stored but their runs are `flagged` with reason `account_elsewhere`;
  the owner's runs are unaffected.
- **Email claim.** The server can check, without any extra upload, whether a
  provider account's email is one of the Quota account's *verified* sign-in
  emails: for each verified identity email `e` it computes
  `HMAC(secret, hex(SHA-256("quota-run-account-v1\n" + provider + "\n" + e)))` and
  compares. A match makes the claim `via: "email"`, which beats `"first"`: the
  account moves to that Quota account and the previous owner's runs for it
  become `flagged` (`account_elsewhere`). An `"email"` claim is never taken over.
  Claims are re-checked when readings arrive and whenever an identity is
  signed up, linked or verified.
- **Account verified badge.** A run is `accountVerified: true` when every
  reading's account is owned by the run's user `via: "email"`. It is a badge,
  not a tier requirement: different emails still rank.
- **Several accounts** per provider can be bound to one Quota account; each has
  its own runs, and a board still shows one best run per person.
- **Unbinding** (`DELETE /accounts/<id>`) deletes this user's readings and runs
  for that provider account and the binding; if the user owned it, ownership
  passes to the next Quota account that uploaded it (by first upload,
  `via: "email"` if its emails match), whose runs are recomputed. The app also
  stops uploading that account (a local exclusion list) until bound again.

### Connect (device ↔ account)

Modelled on the OAuth device flow, bound to the device key instead of a client secret:

1. The app creates a key and calls `POST /connect/start` (signed like `register`:
   verified with `publicKey` from the body). The server answers with a
   `userCode` (8 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, shown as
   `ABCD-EFGH`, valid 10 minutes) and `verifyURL`
   `https://quota.run/connect?code=ABCD-EFGH` (`/zh/connect?...` when the app is in Chinese).
2. The app opens `verifyURL` in the default browser and shows the same code.
3. On quota.run the person signs in (or signs up), sees the Mac's name, app
   version and code, and approves or denies.
4. The app polls `POST /connect/poll` (signed with the same key) every
   `interval` seconds until `approved`, `denied` or `expired`. On `approved` it
   gets the `deviceId` and carries on exactly as after a registration.

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
<path, no query string, e.g. /api/v1/snapshots>
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

1. every reading has an `accountDigest` owned by this user (always true for a ranked run: see below);
2. monotonic: no reading drops more than 2 points below an earlier one in the run;
3. plausible: no rise of more than 60 points between readings less than 5 minutes apart;
4. covered: the first reading is at most 50%, and no gap between consecutive
   readings from the first reading to the 100% reading (or the last reading)
   exceeds 20 minutes;
5. active: for `codex` and `claude`, at least one activity minute with tokens > 0
   for the matching source between the first reading and completion (or last reading).

Otherwise **standard**, unless rule 2 or 3 fails or a reading's account is owned
by another Quota account (`account_elsewhere`) → **flagged** (kept for review,
excluded from boards and profiles). A run with any reading lacking a digest is
**unranked** (excluded like flagged, unless it is also flagged). `flag_reason`
lists `drop`, `jump`, `account_elsewhere`, or `no_account` for unranked.

Boards show verified and standard runs with a tier badge; `tier=verified`
filters. Readings from non-ranked devices are stored but never counted.

### Season

ISO-8601 week (UTC) of `windowStart`, written `2026-W37`. `season=current`
means the week containing now; `all` means every season (best run per user).

## API

Base `https://quota.run/api/v1` (the server also answers the early prefix
`/api/run/v1`; the signature always covers the path it received). JSON in and out, UTF-8. Errors:
`{"error": "<code>", "message": "<English sentence>"}` with 400/401/403/404/409/413/429.
Bodies above 1 MB → 413. Authenticated writes: at most one request every 10 s per
device (burst 5) → 429.

### Public

| Method & path | Returns |
|---|---|
| `GET /stats` | `{users, runs, verifiedRuns, providers, updatedAt}` |
| `GET /boards?region=global` | `{boards: [{provider, plan, planLabel, windowKey, windowSeconds, windowTitle, runners, season}]}` — boards with at least one rankable run in the current season, most runners first |
| `GET /leaderboard?provider=codex&plan=pro20x&window=604800:&metric=speed&season=current&region=global&tier=all&limit=100` | `{board: {...}, season, metric, entries: [{rank, username, displayName, value, unit, tier, accountVerified, achievedAt, peakPercent}], updatedAt}` — one entry per user (their best run); `unit` is `seconds` or `percent` |
| `GET /users/<username>` | `{username, displayName, bio, region, joinedAt, links: {website, github, x}, projects: [...], bests: [{provider, plan, planLabel, windowKey, windowSeconds, windowTitle, metric, value, rank, runners, percentile, tier, accountVerified, season}], recent: [run... (each with accountVerified)], stats: {runs, verifiedRuns, providers, activeDays}}` |

`region` is `global` or `china` (a user attribute, chosen when joining; used as a
filter). Omit it for everyone.

### Device-signed

Signed as in *Signing*, with `X-Quota-Device` except where noted.

| Method & path | Body | Returns |
|---|---|---|
| `POST /connect/start` (no device id; verified with `publicKey`) | `{publicKey, deviceName ≤60, platform: "macos", appVersion ≤40}` | `201 {requestId, userCode, verifyURL, expiresAt, interval: 3}`; `409 key_registered` |
| `POST /connect/poll` (no device id; verified with `publicKey`) | `{requestId, publicKey}` | `{status: "pending"}` · `{status: "denied"}` · `{status: "expired"}` · `{status: "approved", user: {username, displayName, region}, deviceId, ranked}`; `404 connect_request_invalid` when the id is unknown or belongs to another key |
| `POST /snapshots` | `{snapshots: [≤500], activity: [≤1440]}` | `{accepted, duplicates, rejected: [{index, reason}]}` — `observedAt` must be within the last 7 days and at most 300 s in the future; duplicates by `(device, provider, windowKey, observedAt)` |
| `DELETE /devices/current` | — | `204`; this Mac leaves the account (if it was ranked the account has none until another is chosen or connected) |

`POST /register` (username sign-up from the app) and pairing codes are gone.
The server keeps `register` only behind `QUOTA_RUN_DEVICE_SIGNUP=1` for local tests.

### Device-signed or signed-in session

These accept either a device signature or the `qr_session` cookie. With a
session no device is `current`.

| Method & path | Body | Returns |
|---|---|---|
| `GET /me` | — | `{user: {username, displayName, bio, region, links, joinedAt}, devices: [{deviceId, name, ranked, lastSeenAt, current, appVersion}], rankedChangeAvailableAt, lastUploadAt, projects, identities: [{id, provider, email, name, linkedAt}], providerAccounts: [providerAccount]}` |
| `POST /accounts/lookup` | `{digests: [≤20 lower-case hex SHA-256]}` | `{accounts: [{digest, account: providerAccount \| null}]}` — `null` when this user never uploaded it; device signature only (the web has no digests) |
| `DELETE /accounts/<id>` | — | `{providerAccounts}`; `404 account_not_found` |
| `PUT /profile` | `{displayName ≤40, bio ≤160, region, links: {website, github, x}}` | `{user}` |
| `PUT /projects` | `{projects: [≤12 {name ≤40, url, description ≤140, github?, builtWith: [provider…]}]}` | `{projects}` — URLs must be `https://` |
| `POST /devices/ranked` | `{deviceId}` | `{devices, rankedChangeAvailableAt}`; `409 {error: "cooldown", availableAt}` |
| `DELETE /devices/<deviceId>` | — | `{devices}`; with a device signature not the current device and not the ranked one; with a session any device |
| `DELETE /account` | — | `204`; every row for the user, devices, identities and sessions is deleted |

`providerAccount` = `{id, provider, firstSeenAt, lastSeenAt, status, verifiedByEmail, runs}`:
`id` is the first 16 hex characters of the account HMAC (only ever shown to its
own user); `status` is `owned` or `elsewhere` (another Quota account owns it, so
these runs are flagged); `verifiedByEmail` is true when owned `via: "email"`;
`runs` counts this user's runs for it that are not flagged or unranked.

### Web session

The session is a cookie: `qr_session=<32 random bytes, base64url>; Path=/;
HttpOnly; Secure; SameSite=Lax; Max-Age=2592000`. The server stores only its
SHA-256, refreshes the expiry at most once a day, and drops `Secure` only when
`QUOTA_RUN_INSECURE_COOKIES=1` (local http). Every session request that is not
`GET` must send `Origin` equal to `QUOTA_RUN_ORIGIN` (default
`https://quota.run`) → else `403 bad_origin`. Session responses carry
`Cache-Control: no-store`. A session belongs to an identity; until that identity
has an account the session "needs signup" and only `/session`, `/signup`,
`/usernames/…`, `/auth/logout` work (`403 needs_signup` elsewhere); without a
session → `401 not_signed_in`.

| Method & path | Body | Returns |
|---|---|---|
| `GET /auth/providers` | — | `{google: bool, github: bool, email: bool}` — which sign-ins are configured |
| `GET /session` | — | `{signedIn, needsSignup, identity: {provider, email, name} \| null, user: {username, displayName, region} \| null, suggestedUsername, suggestedDisplayName}` |
| `POST /auth/logout` | — | `204`, cookie cleared |
| `GET /auth/github/start?next=&link=` · `GET /auth/google/start?next=&link=` | — | `302` to the provider (a browser navigation, not fetch) |
| `GET /auth/github/callback` · `GET /auth/google/callback` | — | `302`: to `next`; to `/login?next=…` (`/zh/login` when `next` starts with `/zh/`) when signup is needed; to `/login?error=<code>&next=…` on `oauth_denied`, `oauth_state`, `oauth_failed`, `provider_unavailable`; with `link=1` to `next` with `?error=identity_in_use` when the identity is on another account |
| `POST /auth/email/start` | `{email ≤254, lang: "en"\|"zh", link?: bool}` | `202 {sent: true, expiresAt}` whether or not an account exists; `400 invalid_email`; `429 rate_limited {retryAfter}`; `503 email_unavailable` |
| `POST /auth/email/verify` | `{email, code}` | `200 {signedIn: true, needsSignup}` and the cookie (when `start` had `link` from a signed-in session with an account: the identity is attached instead, `{linked: true}`); `400 code_invalid`, `400 code_expired`, `429 too_many_attempts`, `409 identity_in_use` |
| `GET /usernames/<name>` | — | `{available: bool, reason: null \| "invalid" \| "reserved" \| "taken"}` |
| `POST /signup` | `{username, displayName ≤40, region}` | `201 {user}`; `400 invalid_username`, `409 username_taken`, `400 invalid_region`, `409 already_signed_up` |
| `DELETE /identities/<id>` | — | `{identities}`; `409 last_identity` |
| `GET /connect/<userCode>` | — | `{userCode, deviceName, platform, appVersion, createdAt, expiresAt, status}`; `404 connect_code_invalid` |
| `POST /connect/<userCode>/approve` | — | `{deviceName, ranked}`; the device is created on the session's account; `409 connect_code_used`, `404 connect_code_invalid` |
| `POST /connect/<userCode>/deny` | — | `{status: "denied"}` |

`next` must be a relative path that starts with `/` and not `//`; anything
else becomes `/account`. `userCode` lookups ignore case, spaces and `-`.

**OAuth details.** `start` stores a random `state` (hashed) with a PKCE S256
verifier, the provider, `next` and `link` for 10 minutes, and sets
`qr_oauth=<state>; Path=/api/v1/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=600`;
the callback requires the query `state` to equal that cookie and to exist in
the table, then deletes it. Redirect URIs are
`https://quota.run/api/v1/auth/github/callback` and
`https://quota.run/api/v1/auth/google/callback` (built from `QUOTA_RUN_ORIGIN`).

- GitHub: authorize `https://github.com/login/oauth/authorize` with
  `client_id, redirect_uri, scope="read:user user:email", state, code_challenge,
  code_challenge_method=S256`; token `POST https://github.com/login/oauth/access_token`
  (`Accept: application/json`; `client_id, client_secret, code, redirect_uri,
  code_verifier`); then `GET https://api.github.com/user` and
  `GET https://api.github.com/user/emails` (the primary verified address).
  Subject = `id`; name = `name` or `login`; suggested username = `login`.
- Google: authorize `https://accounts.google.com/o/oauth2/v2/auth` with
  `client_id, redirect_uri, response_type=code, scope="openid email profile",
  state, code_challenge, code_challenge_method=S256, prompt=select_account`;
  token `POST https://oauth2.googleapis.com/token` (`grant_type=authorization_code`);
  then `GET https://openidconnect.googleapis.com/v1/userinfo` with the bearer token.
  Subject = `sub`; the email counts as verified only when `email_verified` is true.
- The access token is used once and never stored.

**Email codes.** 6 digits, stored as HMAC-SHA256(server secret, email + code),
valid 10 minutes, 5 wrong tries then `too_many_attempts`; a new `start` replaces
the old code. At most one `start` per address per 60 s and 6 per hour, 20 per IP
per hour. The mail is plain text in the chosen language: subject
`Your Quota Run code: 123456` / `Quota Run 验证码：123456`, the code, that it
expires in 10 minutes, and that nothing happens if the reader did not ask for it.
No links carrying the code. Sent over SMTP in a background thread.

**Configuration** (environment, from `/etc/quotabar-run.env`, mode 640
`root:quotabar-run`): `QUOTA_RUN_ORIGIN`, `QUOTA_RUN_GITHUB_CLIENT_ID`,
`QUOTA_RUN_GITHUB_CLIENT_SECRET`, `QUOTA_RUN_GOOGLE_CLIENT_ID`,
`QUOTA_RUN_GOOGLE_CLIENT_SECRET`, `QUOTA_RUN_SMTP_HOST`, `QUOTA_RUN_SMTP_PORT`
(465 = TLS, otherwise STARTTLS), `QUOTA_RUN_SMTP_USER`,
`QUOTA_RUN_SMTP_PASSWORD`, `QUOTA_RUN_MAIL_FROM`. A provider without its
settings reports `false` in `/auth/providers`.

**Local testing only:** `QUOTA_RUN_DEV_LOGIN=1` adds `POST /auth/dev {email}`,
which signs in as that email identity at once (refused unless the server listens
on 127.0.0.1); `QUOTA_RUN_DEVICE_SIGNUP=1` re-enables `POST /register` with a username.

## Web

All on quota.run, English at the root and Chinese under `/zh/`; Caddy serves
`/<page>` from `/<page>.html`.

- `/` (`/zh/`): board picker (provider → plan → window), metric (fastest to 100% /
  highest peak), season (this week, last week, all time), region, verified-only
  switch; rows with rank, name, value (`2h 37m` / `98%`), tier badge, time.
  Empty state explains how to join.
- `/@username` (Caddy rewrites to `/u.html`, `/zh/@username` to `/zh/u.html`):
  name, bio, links, per-board bests with rank and top-percentile, recent runs,
  projects as cards. 404 state when the user does not exist.
- `/login`: Continue with GitHub, Continue with Google (only those configured),
  or an email address → 6-digit code; then, for a new identity, choose username
  (checked live), display name and region. Goes to `next` (default `/account`).
- `/account`: profile, projects, Macs (ranked badge, last seen, make ranked,
  remove), provider accounts (provider, first bound, "Account verified" or
  "Owned by another Quota account", runs, unbind with a note that a Mac still
  signed in to it binds it again unless it is unbound in the app), sign-in methods (link GitHub / Google / email, remove), view profile,
  sign out, delete account (type the username to confirm). Signed out → `/login?next=/account`.
- `/connect?code=`: the Mac's name, app version and code to compare, Approve /
  Deny, then "Connected — go back to QuotaBar". Without a code, a field to type it.
- Boards, profile bests and recent runs show a small **Account verified** mark
  next to the tier when `accountVerified`; the tiers card on the leaderboard
  explains that only runs bound to a provider account rank and what the mark means.
- Every page header shows **Sign in** or **@username** (→ `/account`).
- A demo mode (`?demo=1`) renders fixture data so the pages can be previewed
  without the API.

## App

- **Records** (Settings → Quota Run, no account): every successful reading is
  written to a local run ledger (Application Support, last 60 days). The page
  shows runs in progress and personal bests per provider/plan/window: fastest to
  100%, time to 50/90%, highest peak. A best can be shared as an image.
- **Sign in**: one button, "Sign in with quota.run", after a consent sheet
  listing exactly what is uploaded and what never is. The app creates the device
  key, calls `connect/start`, opens the browser and shows the code and a waiting
  state (open the browser again, cancel). Denied, expired or cancelled → the key
  is deleted and the button comes back. The app has no username, password or
  pairing fields.
- **Signed in**: "@username", how the account signs in (from `identities`),
  upload status, ranked device (with the cooldown), profile and projects
  editors, "Manage account on quota.run" (`/account`), "View my profile",
  "Disconnect this Mac" (`DELETE /devices/current`, forgets the key, keeps local
  records) and "Delete account" (`DELETE /account`). To add another Mac, sign in
  on it with the same account.
- **Provider accounts** (signed in): for each provider whose latest reading has
  an account, the masked email (`p***@gmail.com`, shown only on this Mac) with its
  status from `accounts/lookup`: not uploaded yet, bound, **Account verified**,
  or **Owned by another Quota account** (runs don't count; sign in to quota.run
  with that email to claim it). "Unbind" (confirm) → `DELETE /accounts/<id>` and
  adds the digest to a local exclusion list; "Bind again" removes it from the list.
  Personal records' "likely verified" estimate requires a digest on every reading.
- **Upload**: after each refresh, readings not yet sent plus activity minutes
  since the last upload, batched, at most every 60 s, queued on disk while offline,
  retried with backoff. Only when signed in and this Mac is the ranked device.
  Readings without an account digest, or whose digest is excluded, are not uploaded.
