#!/usr/bin/env python3
"""Short-lived App Store signing for CI.

`create` makes App Store provisioning profiles (app and widget extension) through the
App Store Connect API and writes a .p12, `<uuid>.mobileprovision` files and state.json.
`revoke` deletes the profiles again.

The certificate is the fixed one from the DIST_CERT_P12_BASE64 / DIST_CERT_P12_PASSWORD
secrets when they are set (never revoked). Otherwise a fresh Apple Distribution certificate
is created for the run and revoked by `revoke`.

Nothing identifying is printed: Apple puts the account holder's name into the
certificate, and CI logs of this repository are public.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, APPLE_BUNDLE_ID,
optionally DIST_CERT_P12_BASE64 and DIST_CERT_P12_PASSWORD.
"""

import base64
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"], "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"
    der = key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{signing_input}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def call(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            raw = res.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        # Only the error codes and details; never the full payload.
        try:
            errors = json.loads(err.read()).get("errors", [])
            detail = "; ".join(f"{e.get('code')}: {e.get('detail')}" for e in errors)
        except Exception:
            detail = ""
        sys.exit(f"App Store Connect {method} {path.split('?')[0]} failed ({err.code}) {detail}")


def create(out: str) -> None:
    os.makedirs(out, exist_ok=True)
    mac = os.environ.get("SIGNING_PLATFORM", "ios") == "mac"
    if os.environ.get("DIST_CERT_P12_BASE64"):
        key, cert, cert_id = fixed_identity()
        # The fixed certificate is never revoked: state has no certificate_id.
        state: dict = {}
        print("Using the fixed distribution certificate.")
    else:
        key, cert, cert_id = short_lived_identity(out)
        state = {"certificate_id": cert_id}
    save_state(out, state)

    password = secrets.token_urlsafe(24)
    write_p12(os.path.join(out, "dist.p12"), key, cert, password)
    with open(os.path.join(out, "p12-password"), "w") as f:
        f.write(password)

    app_id = os.environ["APPLE_BUNDLE_ID"]
    if mac:
        # The Mac App Store takes a .pkg signed with an installer certificate; it is made
        # for this run only and revoked with the profiles.
        installer_key, installer_cert, installer_id = short_lived_identity(out, "MAC_INSTALLER_DISTRIBUTION")
        state["installer_certificate_id"] = installer_id
        save_state(out, state)
        write_p12(os.path.join(out, "installer.p12"), installer_key, installer_cert, password)
        bundles = [(f"{app_id}.mac", "MAC_OS")]
        profile_type, extension = "MAC_APP_STORE", "provisionprofile"
    else:
        # The app and its widget extension each need their own App Store profile.
        bundles = [(app_id, "IOS"), (f"{app_id}.widgets", "IOS")]
        profile_type, extension = "IOS_APP_STORE", "mobileprovision"

    state["profiles"] = {}
    for bundle_id, platform in bundles:
        profile = call("POST", "/profiles", {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": f"Gunce CI {os.environ.get('GITHUB_RUN_ID', int(time.time()))} {bundle_id.rsplit('.', 1)[-1]}",
                    "profileType": profile_type,
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource(bundle_id, platform)}},
                    "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                },
            },
        })["data"]
        uuid = profile["attributes"]["uuid"]
        state["profiles"][bundle_id] = {"id": profile["id"], "uuid": uuid, "name": profile["attributes"]["name"]}
        save_state(out, state)
        with open(os.path.join(out, f"{uuid}.{extension}"), "wb") as f:
            f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    print(f"Created {len(state['profiles'])} App Store profiles.")


def write_p12(path: str, key, cert, password: str) -> None:
    p12 = pkcs12.serialize_key_and_certificates(
        name=b"gunce-ci",
        key=key,
        cert=cert,
        cas=None,
        # macOS `security import` only reads the legacy PKCS#12 format (3DES, SHA-1 MAC).
        encryption_algorithm=serialization.PrivateFormat.PKCS12.encryption_builder()
        .kdf_rounds(50000)
        .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
        .hmac_hash(hashes.SHA1())
        .build(password.encode()),
    )
    with open(path, "wb") as f:
        f.write(p12)


def short_lived_identity(out: str, certificate_type: str = "DISTRIBUTION"):
    """A new certificate for this run; `revoke` deletes it again."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Gunce CI")]))
        .sign(key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    cert = call("POST", "/certificates", {
        "data": {"type": "certificates", "attributes": {"certificateType": certificate_type, "csrContent": csr_pem}},
    })["data"]
    # Write the id first so `revoke` can clean up even if a later step fails.
    key_name = "certificate_id" if certificate_type == "DISTRIBUTION" else "installer_certificate_id"
    state = load_state(out)
    state[key_name] = cert["id"]
    save_state(out, state)
    der = base64.b64decode(cert["attributes"]["certificateContent"])
    return key, x509.load_der_x509_certificate(der), cert["id"]


def fixed_identity():
    """The long-lived certificate from DIST_CERT_P12_BASE64 / DIST_CERT_P12_PASSWORD."""
    data = base64.b64decode(os.environ["DIST_CERT_P12_BASE64"])
    password = os.environ.get("DIST_CERT_P12_PASSWORD", "").encode() or None
    try:
        key, cert, _ = pkcs12.load_key_and_certificates(data, password)
    except ValueError:
        sys.exit("DIST_CERT_P12_BASE64 could not be opened; check DIST_CERT_P12_PASSWORD")
    if key is None or cert is None:
        sys.exit("DIST_CERT_P12_BASE64 must contain the certificate and its private key")
    der = cert.public_bytes(serialization.Encoding.DER)
    listed = call("GET", "/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200")["data"]
    for item in listed:
        if base64.b64decode(item["attributes"].get("certificateContent") or "") == der:
            return key, cert, item["id"]
    sys.exit("The fixed distribution certificate is not active in this team (expired or revoked?)")


def bundle_resource(identifier: str, platform: str = "IOS") -> str:
    """The App Store Connect id of a bundle ID, registering it when it is new."""
    bundles = call("GET", f"/bundleIds?filter[identifier]={identifier}&limit=200")["data"]
    match = [b for b in bundles if b["attributes"]["identifier"] == identifier]
    if match:
        bundle = match[0]["id"]
    else:
        bundle = call("POST", "/bundleIds", {
            "data": {
                "type": "bundleIds",
                "attributes": {"identifier": identifier, "name": f"Gunce {identifier.rsplit('.', 1)[-1]}", "platform": platform},
            },
        })["data"]["id"]
        print(f"Registered bundle ID {identifier}.")
    if platform == "MAC_OS":
        ensure_sign_in_with_apple(bundle)
    return bundle


def ensure_sign_in_with_apple(bundle: str) -> None:
    """The Mac app's own bundle ID gets the Sign in with Apple capability (as a primary app)."""
    existing = call("GET", f"/bundleIds/{bundle}/bundleIdCapabilities")["data"]
    if any(c["attributes"].get("capabilityType") == "APPLE_ID_AUTH" for c in existing):
        return
    call("POST", "/bundleIdCapabilities", {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {
                "capabilityType": "APPLE_ID_AUTH",
                "settings": [{"key": "APPLE_ID_AUTH_APP_CONSENT", "options": [{"key": "PRIMARY_APP_CONSENT"}]}],
            },
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}}},
        },
    })
    print("Enabled Sign in with Apple for the Mac bundle ID.")


def revoke(out: str) -> None:
    path = os.path.join(out, "state.json")
    if not os.path.exists(path):
        print("Nothing to revoke.")
        return
    with open(path) as f:
        state = json.load(f)
    for profile in state.get("profiles", {}).values():
        call("DELETE", f"/profiles/{profile['id']}")
    for key in ("certificate_id", "installer_certificate_id"):
        if key in state:
            call("DELETE", f"/certificates/{state[key]}")
    revoked = [k for k in ("certificate_id", "installer_certificate_id") if k in state]
    print("Deleted the profiles" + (f" and {len(revoked)} short-lived certificate(s)." if revoked else "."))


def load_state(out: str) -> dict:
    path = os.path.join(out, "state.json")
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def save_state(out: str, state: dict) -> None:
    with open(os.path.join(out, "state.json"), "w") as f:
        json.dump(state, f)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("create", "revoke"):
        sys.exit("usage: signing.py create|revoke <dir>")
    {"create": create, "revoke": revoke}[sys.argv[1]](sys.argv[2])
