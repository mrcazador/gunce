# Setup

One-time steps that only the account owner can do. Nothing here is ever committed.

## 1. Repository settings (public repo hardening)

- Settings → Code security: enable **Secret scanning** and **Push protection**, **Dependabot alerts**.
- Settings → Actions → General:
  - Fork pull request workflows: **Require approval for all external contributors**.
  - Workflow permissions: **Read repository contents** (default token read-only).
- Settings → Rules → Rulesets: protect `main` — block force pushes and deletion.

## 2. App Store Connect

1. Create the app record: App Store Connect → Apps → + → New App
   (iOS, name "Günce", bundle ID `com.<you>.gunce`, SKU `gunce`).
2. Create an API key: Users and Access → Integrations → App Store Connect API →
   Team Keys → +, role **Admin**. Each TestFlight build creates its own Apple Distribution
   certificate and App Store profile through this key and revokes both when it finishes
   (`ci/signing.py`), so no signing key is stored anywhere. Download the `.p8` once. Note the **Key ID** and
   **Issuer ID**.
3. Note your **Team ID** (developer.apple.com → Membership details).

## 3. GitHub Actions secrets

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | API key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` output |
| `APPLE_TEAM_ID` | Team ID |
| `CLOUDFLARE_API_TOKEN` | Custom token `gunce-github-deploy`: Account → Workers Scripts Edit, D1 Edit, Account Settings Read; only your account |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare → Workers & Pages → Account ID |
| `DIST_CERT_P12_BASE64` | Optional. The fixed Apple Distribution certificate, see below |
| `DIST_CERT_P12_PASSWORD` | Optional. Its export password |

### Fixed distribution certificate (optional)

Without these two secrets each build creates its own certificate and revokes it. To sign with
one long-lived certificate instead (it lasts a year; Apple allows three distribution
certificates per team):

1. On the Mac: Xcode → Settings → Accounts → your team → Manage Certificates → **+** →
   **Apple Distribution**.
2. Keychain Access → login → My Certificates → right-click "Apple Distribution: …" →
   Export → `.p12`, with a strong password.
3. `base64 -i Certificates.p12 | pbcopy` and paste it as `DIST_CERT_P12_BASE64`; the password
   goes in `DIST_CERT_P12_PASSWORD`. Then delete the `.p12` file.

CI still creates and deletes the App Store profiles on every build. When the certificate
expires or is revoked the build fails with a clear message; make a new one the same way.

Repository **variables** (Secrets and variables → Actions → Variables):

| Variable | Value |
| --- | --- |
| `APPLE_BUNDLE_ID` | The app's bundle ID. The Worker accepts Sign in with Apple tokens only for this audience, and the app is built with it. The widget extension uses `<bundle ID>.widgets`; CI registers it and creates its profile |
| `API_HOST` | Optional. API host without `https://`. When unset, the TestFlight build uses `gunce.<subdomain>.workers.dev` |

In the Apple Developer portal, the App ID needs the **Sign in with Apple** capability. CI signs
manually with the profiles it creates, so if the archive step fails on provisioning, turn it on by hand
(Certificates, Identifiers & Profiles → Identifiers → the app → Sign in with Apple).

After saving, delete the downloaded `.p8` from Downloads or move it to a password manager.

## 4. Cloudflare (Workers Paid)

Nothing to click. The `Deploy Worker` workflow finds or creates the `gunce` D1 database
(location hint: Eastern Europe), applies `worker/migrations/`, deploys the Worker to
`https://gunce.<subdomain>.workers.dev` and checks `/health`. Run it once by hand from
Actions → Deploy Worker → Run workflow, or push a change under `worker/`.

A custom domain later: add a `routes` entry in `worker/wrangler.jsonc` and give the token
Zone → Workers Routes → Edit for that zone.
