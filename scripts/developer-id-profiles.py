#!/usr/bin/env python3
"""Makes sure each bundle ID has an active Developer ID provisioning profile for the Developer ID Application
certificate in the keychain, and installs it where Xcode looks. Prints `bundle-id<TAB>profile name` per line, for CI
archive signing and the export's provisioningProfiles.

    scripts/developer-id-profiles.py io.github.sinhong2011.triwarden io.github.sinhong2011.triwarden.autofill

Needs an App Store Connect API key with Admin access: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID. Called before archive
when ASC_KEY_PATH is set so release.sh can Manual-sign with Developer ID (Automatic + Apple Development on a clean
CI runner would mint Mac Development certificates and hit Apple's quota). Xcode's automatic Developer ID export goes
through Apple's cloud signing, which only the Account Holder may use; manual signing with these profiles and the
imported certificate doesn't. Standard library plus the system `openssl`, so CI needs nothing installed.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """openssl writes an ECDSA signature as DER (SEQUENCE of two INTEGERs); a JWT wants r‖s, 32 bytes each."""
    def integer(at: int) -> tuple[bytes, int]:
        assert der[at] == 0x02
        length = der[at + 1]
        value = der[at + 2:at + 2 + length]
        return value.lstrip(b"\x00").rjust(32, b"\x00"), at + 2 + length
    start = 2 if der[1] < 0x80 else 3  # skip the SEQUENCE header
    r, at = integer(start)
    s, _ = integer(at)
    return r + s


def token() -> str:
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64url(der_to_raw(der))}"


JWT = None


def call(method: str, path: str, body: dict | None = None) -> dict:
    global JWT
    JWT = JWT or token()
    url = path if path.startswith("http") else API + path
    request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                     headers={"Authorization": f"Bearer {JWT}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path}: HTTP {error.code}\n{error.read().decode()[:2000]}")


def every(path: str) -> list[dict]:
    """All pages of a list endpoint."""
    items, url = [], path
    while url:
        page = call("GET", url)
        items += page.get("data", [])
        url = page.get("links", {}).get("next")
    return items


def keychain_serial() -> str:
    pem = subprocess.run(["security", "find-certificate", "-c", "Developer ID Application", "-p"],
                         capture_output=True, text=True, check=True).stdout
    serial = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem,
                            capture_output=True, text=True, check=True).stdout
    return normalized(serial.split("=", 1)[1])


def normalized(serial: str) -> str:
    return serial.strip().replace(":", "").upper().lstrip("0")


def main() -> None:
    bundles = sys.argv[1:]
    if not bundles:
        sys.exit(__doc__)

    serial = keychain_serial()
    certificates = [c for c in every("/certificates?limit=200")
                    if c["attributes"]["certificateType"].startswith("DEVELOPER_ID_APPLICATION")
                    and normalized(c["attributes"]["serialNumber"]) == serial]
    if not certificates:
        sys.exit(f"No Developer ID Application certificate with serial {serial} in the account")
    certificate = certificates[0]["id"]

    profiles = every("/profiles?filter[profileType]=MAC_APP_DIRECT&filter[profileState]=ACTIVE"
                     "&include=bundleId,certificates&limit=200")
    folder = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")
    os.makedirs(folder, exist_ok=True)

    for identifier in bundles:
        matches = [b for b in every(f"/bundleIds?filter[identifier]={urllib.parse.quote(identifier)}&limit=200")
                   if b["attributes"]["identifier"] == identifier]
        if not matches:
            sys.exit(f"Bundle ID {identifier} isn't registered in the account")
        bundle = matches[0]["id"]

        profile = next((p for p in profiles
                        if p["relationships"]["bundleId"]["data"]["id"] == bundle
                        and any(c["id"] == certificate for c in p["relationships"]["certificates"]["data"])), None)
        if profile is None:
            name = f"Triwarden Developer ID {identifier} {time.strftime('%Y%m%d%H%M')}"
            profile = call("POST", "/profiles", {"data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "MAC_APP_DIRECT"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate}]},
                },
            }})["data"]
            print(f"created {name}", file=sys.stderr)

        attributes = profile["attributes"]
        with open(os.path.join(folder, f"{attributes['uuid']}.provisionprofile"), "wb") as file:
            file.write(base64.b64decode(attributes["profileContent"]))
        print(f"{identifier}\t{attributes['name']}")


if __name__ == "__main__":
    main()
