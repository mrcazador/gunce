# Günce — guidance for Claude

Günce is Said's personal iPhone app for work that keeps getting interrupted. Its core idea:
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
| Backend | Supabase (Postgres + Auth with Sign in with Apple + Edge Functions) | `supabase/` |
| Claude access | Remote MCP server exposing task tools | `supabase/functions/mcp/` |
| Delivery | GitHub Actions macOS runner → TestFlight | `.github/workflows/` |

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
  index) and `start_task()` does the switch atomically. Never work around it client-side.
- Every state change writes a row to `task_events` (the "İz" history): created, started,
  parked (with note and reason), resumed, done.
- Park reasons: `waiting` (Yanıt bekliyorum), `need_info` (Bilgi lazım), `later` (Sonra devam).
- Reminders are app notifications (Said no longer uses Apple Reminders). Calendar sync is both
  ways: timed tasks go to a dedicated "Günce" calendar, and calendar events appear in "Bugün".
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

1. **Never commit secrets**: no `.p8`, certificates, provisioning profiles, Supabase
   `service_role` key, APNs key, MCP tokens, or `.env` files. Secrets live only in GitHub
   Actions secrets and Supabase function secrets. `gitleaks` runs on every push.
2. The Supabase **anon key and project URL may ship in the app** (they are public by design),
   but only because **every table has Row Level Security** with `user_id = auth.uid()`.
   A new table without RLS policies is a blocker.
3. The `service_role` key is used only inside Edge Functions, never in the app.
4. Workflows: trigger only on `push` to `main` and `workflow_dispatch`. Never add
   `pull_request_target`, never expose secrets to PRs from forks. Default
   `permissions: contents: read`. Pin third-party actions to a full commit SHA.
5. No real personal data in code, fixtures, previews or screenshots. Use invented examples.
6. Tokens on device go to the Keychain, never `UserDefaults`.
