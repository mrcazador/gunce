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
   Team Keys → +, role **App Manager**. Download the `.p8` once. Note the **Key ID** and
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
| `SUPABASE_URL` | `https://<project>.supabase.co` |
| `SUPABASE_ANON_KEY` | Supabase anon (public) key |

After saving, delete the downloaded `.p8` from Downloads or move it to a password manager.

## 4. Supabase

1. Create a project (region: Frankfurt `eu-central-1`).
2. Authentication → Providers → **Apple**: enable, bundle ID as client ID.
3. Apply `supabase/migrations/` (SQL editor, or `supabase db push`).
4. Never share the `service_role` key; it is only set as an Edge Function secret.
