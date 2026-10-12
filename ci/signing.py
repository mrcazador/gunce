#!/usr/bin/env python3
"""Short-lived App Store signing for CI.

`create` makes a fresh Apple Distribution certificate and an App Store provisioning
profile through the App Store Connect API, and writes a .p12 and .mobileprovision.
`revoke` deletes both again, so no long-lived signing key ever exists outside Apple.

Nothing identifying is printed: Apple puts the account holder's name into the
certificate, and CI logs of this repository are public.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, APPLE_BUNDLE_ID.
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
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Gunce CI")]))
        .sign(key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

    cert = call("POST", "/certificates", {
        "data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr_pem}},
    })["data"]
    # Write the id first so `revoke` can clean up even if a later step fails.
    state = {"certificate_id": cert["id"]}
    save_state(out, state)

    der = base64.b64decode(cert["attributes"]["certificateContent"])
    password = secrets.token_urlsafe(24)
    p12 = pkcs12.serialize_key_and_certificates(
        name=b"gunce-ci",
        key=key,
        cert=x509.load_der_x509_certificate(der),
        cas=None,
        encryption_algorithm=serialization.BestAvailableEncryption(password.encode()),
    )
    with open(os.path.join(out, "dist.p12"), "wb") as f:
        f.write(p12)
    with open(os.path.join(out, "p12-password"), "w") as f:
        f.write(password)

    bundle_id = os.environ["APPLE_BUNDLE_ID"]
    bundles = call("GET", f"/bundleIds?filter[identifier]={bundle_id}&limit=200")["data"]
    match = [b for b in bundles if b["attributes"]["identifier"] == bundle_id]
    if not match:
        sys.exit(f"Bundle ID {bundle_id} is not registered")

    profile = call("POST", "/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": f"Gunce CI {os.environ.get('GITHUB_RUN_ID', int(time.time()))}", "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": match[0]["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
            },
        },
    })["data"]
    state["profile_id"] = profile["id"]
    state["profile_uuid"] = profile["attributes"]["uuid"]
    save_state(out, state)
    with open(os.path.join(out, "dist.mobileprovision"), "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    print("Created a short-lived distribution certificate and App Store profile.")


def revoke(out: str) -> None:
    path = os.path.join(out, "state.json")
    if not os.path.exists(path):
        print("Nothing to revoke.")
        return
    with open(path) as f:
        state = json.load(f)
    if "profile_id" in state:
        call("DELETE", f"/profiles/{state['profile_id']}")
    if "certificate_id" in state:
        call("DELETE", f"/certificates/{state['certificate_id']}")
    print("Revoked the short-lived certificate and profile.")


def save_state(out: str, state: dict) -> None:
    with open(os.path.join(out, "state.json"), "w") as f:
        json.dump(state, f)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("create", "revoke"):
        sys.exit("usage: signing.py create|revoke <dir>")
    {"create": create, "revoke": revoke}[sys.argv[1]](sys.argv[2])
