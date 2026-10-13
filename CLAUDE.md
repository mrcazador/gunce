# PickUp — guidance for Claude

PickUp (code name Günce; the repo, targets and Worker keep that name) is Said's personal iPhone app for work that keeps getting interrupted. Its core idea:
**never lose the place you left off.** Tasks are captured in seconds, *parked* with a one-line
"where I left off" note when you switch away, and *resumed* from that note later.

Said usually talks to you from his phone. Reply in **Turkish**, short and direct. Code,
comments, commit messages and README stay in English.

**This repository is PUBLIC.** Read "Security rules" before every change.

## Architecture

| Part | Tech | Path |
| --- | --- | --- |
| iOS app | SwiftUI, iOS 26+, SwiftData cache, WidgetKit, ActivityKit, EventKit, App Intents | `App/`, `Widgets/` |
| Project file | XcodeGen (`project.yml`). Never hand-edit or commit `.xcodeproj` | `project.yml` |
| Backend | Cloudflare Worker (TypeScript) + D1 (SQLite). Sign in with Apple → opaque session tokens | `worker/` |
| Claude access | Remote MCP endpoint on the same Worker (planned) | `worker/src/` |
| Delivery | App: GitHub Actions macOS runner → TestFlight. Backend: `deploy-worker.yml` → Cloudflare | `.github/workflows/` |

API reference: `docs/API.md`. Schema changes are new files in `worker/migrations/` (never edit an
applied migration). Run `npm run typecheck` and test locally with `wrangler dev` before pushing;
a push to `main` that touches `worker/` migrates the remote D1 database and deploys.

The cloud session that edits this repo runs on Linux: it cannot build or run the app.
A push to `main` triggers `testflight.yml`, which builds on macOS and uploads to TestFlight;
Said installs the update from TestFlight. So **every push to `main` must compile**. Keep
changes small, check Swift syntax carefully, and say in your reply that the build takes
about 15–20 minutes. If a build fails, read the Actions log (`gh run view --log-failed`)
and fix it.

## Domain rules

- Areas (alanlar): **İş, Hayat, Spor, Yatırım**. Users can add more later; colors and SF Symbols
  live in `areas` rows.
- A task has a status: `inbox`, `active`, `parked`, `done`, `archived`. Subtasks use `parent_id`.
- **Exactly one active task per user.** Starting a task while another is active auto-parks the
  previous one and asks for a "nerede kaldın?" note. The database enforces this (partial unique
  index) and `POST /v1/tasks/:id/start` does the switch atomically in one D1 batch. Never work around it client-side.
- Every state change writes a row to `task_events` (the "İz" history): created, started,
  parked (with note and reason), resumed, done.
- Park reasons: `waiting` (Yanıt bekliyorum), `need_info` (Bilgi lazım), `later` (Sonra devam).
- Reminders are app notifications (Said no longer uses Apple Reminders). Calendar sync is both
  ways: timed tasks go to a dedicated "PickUp" calendar, and calendar events appear in "Bugün".
- Tasks Claude creates have `created_via = 'claude'`.

## Design rules

Design source: the "Günce — ekran taslakları" canvas. Follow Apple HIG; use system components.

- Navigation: tab bar with **Şimdi, Görevler, Bugün** + a separate search tab. A floating capture
  bar ("Aklına geleni yaz…") sits above the tab bar (`tabViewBottomAccessory`).
- Liquid Glass only on floating chrome (tab bar, capture bar), never on content.
- App accent is near-black (`.primary`). Color means *area* only:
  İş indigo, Hayat pink, Spor orange, Yatırım green — always paired with its SF Symbol
  (`briefcase`, `heart`, `figure.run`, `chart.line.uptrend.xyaxis`).
- Signature: park notes are shown in **New York italic** (`.font(.system(.body, design: .serif).italic())`).
  Nothing else uses serif.
- One prominent (filled) button per screen. Targets ≥ 44 pt. Dynamic Type, Dark Mode,
  Reduce Motion and VoiceOver labels are required, not optional.
- UI copy is Turkish, sentence case, verbs that say what happens ("Park et", "Devam et", "Bitti").

## Security rules (public repo)

1. **Never commit secrets**: no `.p8`, certificates, provisioning profiles, Cloudflare API
   tokens, APNs key, session/MCP tokens, `.dev.vars` or `.env` files. Secrets live only in
   GitHub Actions secrets and Worker secrets (`wrangler secret put`). `gitleaks` runs on every push.
2. **D1 has no row level security.** Isolation lives in the Worker: every query that touches
   user data must bind `user_id = ?` from the authenticated session — never from the request
   body or URL. A query without that scope is a blocker. Ownership triggers in the schema are
   a second line of defence, not a replacement.
3. Session tokens are random, stored only as SHA-256 hashes, and travel only in the
   `Authorization: Bearer` header. The app ships only the API host, no keys.
4. Workflows: trigger only on `push` to `main` and `workflow_dispatch`. Never add
   `pull_request_target`, never expose secrets to PRs from forks. Default
   `permissions: contents: read`. Pin third-party actions to a full commit SHA.
5. No real personal data in code, fixtures, previews or screenshots. Use invented examples.
6. Tokens on device go to the Keychain, never `UserDefaults`.
