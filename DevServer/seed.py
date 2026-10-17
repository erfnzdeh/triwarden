#!/usr/bin/env python3
"""Seed a dev Vaultwarden server with test accounts and items.

Does the client-side crypto itself (like a real Bitwarden client), so it also
serves as an independent reference implementation for Triwarden's tests.

    python3 seed.py https://m1pro.local:18843 --ca data/root.crt

Requires: requests, cryptography, argon2-cffi.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import os
import struct
import sys
import time
import uuid

import requests
from argon2.low_level import Type, hash_secret_raw
from cryptography.hazmat.primitives import hashes, padding, serialization
from cryptography.hazmat.primitives.asymmetric import padding as asym_padding
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand

PASSWORD = os.environ.get("TRIWARDEN_DEV_PASSWORD", "chiikawa-dev-password")
DEVICE_ID = str(uuid.uuid5(uuid.NAMESPACE_DNS, "seed.chiikawarden.test"))

ACCOUNTS = [
    # email, name, kdf
    ("usagi@chiikawarden.test", "Usagi", {"kdf": 0, "kdfIterations": 600_000}),
    ("hachiware@chiikawarden.test", "Hachiware", {"kdf": 1, "kdfIterations": 3, "kdfMemory": 64, "kdfParallelism": 4}),
    ("momonga@chiikawarden.test", "Momonga", {"kdf": 0, "kdfIterations": 600_000, "totp": True}),
]

TOTP_SECRET = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"  # 20-byte demo secret; dev only (GitHub item, momonga's 2FA)
CLOUDFLARE_TOTP = "MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U"  # a second secret so the two seeded codes differ

# ---------------------------------------------------------------- crypto

def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def master_key(email: str, kdf: dict) -> bytes:
    email = email.strip().lower()
    if kdf["kdf"] == 0:
        return hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), email.encode(), kdf["kdfIterations"], 32)
    salt = hashlib.sha256(email.encode()).digest()
    return hash_secret_raw(PASSWORD.encode(), salt, time_cost=kdf["kdfIterations"],
                           memory_cost=kdf["kdfMemory"] * 1024, parallelism=kdf["kdfParallelism"],
                           hash_len=32, type=Type.ID)


def password_hash(mk: bytes) -> str:
    return b64(hashlib.pbkdf2_hmac("sha256", mk, PASSWORD.encode(), 1, 32))


def stretch(mk: bytes) -> bytes:
    return (HKDFExpand(hashes.SHA256(), 32, b"enc").derive(mk)
            + HKDFExpand(hashes.SHA256(), 32, b"mac").derive(mk))


def enc(data: bytes | str, key: bytes) -> str:
    if isinstance(data, str):
        data = data.encode()
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    ct = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).encryptor().update(padder.update(data) + padder.finalize())
    mac = hmac.new(key[32:], iv + ct, "sha256").digest()
    return f"2.{b64(iv)}|{b64(ct)}|{b64(mac)}"


def rsa_keys(user_key: bytes) -> tuple[rsa.RSAPrivateKey, dict]:
    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub_der = priv.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    priv_der = priv.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return priv, {"publicKey": b64(pub_der), "encryptedPrivateKey": enc(priv_der, user_key)}


def totp(secret: str, t: float | None = None) -> str:
    key = base64.b32decode(secret)
    counter = struct.pack(">Q", int((t or time.time()) // 30))
    digest = hmac.new(key, counter, "sha1").digest()
    o = digest[-1] & 0x0F
    return f"{(struct.unpack('>I', digest[o:o + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"

# ---------------------------------------------------------------- api

class Server:
    def __init__(self, base: str, ca: str | None):
        self.base = base.rstrip("/")
        self.s = requests.Session()
        self.s.verify = ca if ca else True

    def post(self, path: str, **tw):
        r = self.s.post(f"{self.base}/{path}", timeout=30, **tw)
        return r

    def register(self, email: str, name: str, kdf: dict) -> bool:
        mk = master_key(email, kdf)
        user_key = os.urandom(64)
        _, keys = rsa_keys(user_key)
        body = {
            "email": email, "name": name, "masterPasswordHash": password_hash(mk),
            "masterPasswordHint": os.environ.get("TRIWARDEN_DEV_HINT"), "key": enc(user_key, stretch(mk)), "keys": keys,
            **{k: v for k, v in kdf.items() if k.startswith("kdf")},
        }
        r = self.post("api/accounts/register", json=body)
        if r.status_code == 404:
            r = self.post("identity/accounts/register", json=body)
        if r.ok:
            return True
        if "already" in r.text.lower() or "registered" in r.text.lower():
            return False
        raise SystemExit(f"register {email}: {r.status_code} {r.text}")

    def login(self, email: str, kdf: dict, code: str | None = None) -> "Session":
        mk = master_key(email, kdf)
        form = {
            "grant_type": "password", "username": email, "password": password_hash(mk),
            "scope": "api offline_access", "client_id": "web", "deviceType": "9",
            "deviceIdentifier": DEVICE_ID, "deviceName": "triwarden-seed",
        }
        if code:
            form |= {"twoFactorProvider": "0", "twoFactorToken": code, "twoFactorRemember": "0"}
        r = self.post("identity/connect/token", data=form)
        if not r.ok and not code and "TwoFactor" in r.text:
            return self.login(email, kdf, totp(TOTP_SECRET))
        if not r.ok:
            raise SystemExit(f"login {email}: {r.status_code} {r.text}")
        tok = r.json()
        protected = tok.get("Key") or tok.get("key")
        user_key = decrypt(protected, stretch(mk))
        sess = Session(self, tok["access_token"], user_key, password_hash(mk))
        sess.used_2fa = code is not None
        return sess


def decrypt(es: str, key: bytes) -> bytes:
    _, rest = es.split(".", 1)
    iv, ct, mac = (base64.b64decode(p) for p in rest.split("|"))
    assert hmac.compare_digest(hmac.new(key[32:], iv + ct, "sha256").digest(), mac), "MAC mismatch"
    pt = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).decryptor().update(ct)
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(pt) + unpadder.finalize()


class Session:
    def __init__(self, server: Server, token: str, user_key: bytes, pw_hash: str):
        self.server, self.user_key, self.pw_hash = server, user_key, pw_hash
        self.h = {"Authorization": f"Bearer {token}"}

    def req(self, method: str, path: str, **tw):
        r = self.server.s.request(method, f"{self.server.base}/{path}", headers=self.h, timeout=30, **tw)
        if not r.ok:
            raise RuntimeError(f"{method} {path}: {r.status_code} {r.text[:300]}")
        return r.json() if r.content else None

    def cipher_count(self) -> int:
        data = self.req("GET", "api/sync?excludeDomains=true")
        return len(data.get("ciphers") or data.get("Ciphers") or [])

    def login_item(self, name, username, password, uri, totp_secret=None, notes=None, favorite=False, key=None, org=None):
        k = key or self.user_key
        return {
            "type": 1, "name": enc(name, k), "notes": enc(notes, k) if notes else None, "favorite": favorite,
            "organizationId": org, "folderId": None,
            "login": {"username": enc(username, k), "password": enc(password, k),
                      "totp": enc(totp_secret, k) if totp_secret else None,
                      "uris": [{"uri": enc(uri, k), "match": None}]},
        }

    def seed_personal(self):
        k = self.user_key
        items = [
            self.login_item("GitHub", "usagi", "m7Kq#vR2!tLp9wZe$Hu", "https://github.com", TOTP_SECRET,
                            "Recovery codes are in the “GitHub recovery” note.", favorite=True),
            self.login_item("Cloudflare", "ops@momonga.dev", "cf-Dev-Only-1234!", "https://dash.cloudflare.com", CLOUDFLARE_TOTP),
            self.login_item("Proton Mail", "usagi@proton.me", "pm-Dev-Only-5678!", "https://account.proton.me"),
            self.login_item("Synology NAS", "admin", "reused-password", "https://nas.home.arpa:5001"),
            self.login_item("Router", "admin", "reused-password", "http://192.168.1.1"),
            self.login_item("ちいかわ ショップ", "usagi", "日本語パスワード🍓", "https://chiikawamarket.jp"),
            self.login_item("Weak example", "test", "123456", "https://weak.example"),
            {"type": 2, "name": enc("GitHub recovery", k), "notes": enc("abcd-1234\nefgh-5678", k),
             "secureNote": {"type": 0}, "favorite": False, "folderId": None, "organizationId": None},
            {"type": 3, "name": enc("Travel Visa", k), "favorite": False, "folderId": None, "organizationId": None,
             "card": {"cardholderName": enc("Usagi", k), "brand": enc("Visa", k), "number": enc("4111111111111111", k),
                      "expMonth": enc("8", k), "expYear": enc("2029", k), "code": enc("123", k)}},
            {"type": 4, "name": enc("Usagi identity", k), "favorite": False, "folderId": None, "organizationId": None,
             "identity": {"firstName": enc("Usagi", k), "email": enc("usagi@chiikawarden.test", k)}},
        ]
        for it in items:
            self.req("POST", "api/ciphers", json=it)
        # SSH key items only exist on newer servers; skip quietly elsewhere.
        try:
            self.req("POST", "api/ciphers", json={
                "type": 5, "name": enc("homelab-ed25519", k), "favorite": False, "folderId": None, "organizationId": None,
                "sshKey": {"privateKey": enc("-----BEGIN OPENSSH PRIVATE KEY-----\n(dev placeholder)\n-----END OPENSSH PRIVATE KEY-----", k),
                           "publicKey": enc("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDevPlaceholder usagi@triwarden", k),
                           "keyFingerprint": enc("SHA256:devplaceholder", k)}})
        except RuntimeError as e:
            print(f"    (ssh key item skipped: {str(e)[:80]})")

    def seed_org(self, email: str):
        profile = self.req("GET", "api/accounts/profile")
        pub = self.req("GET", f"api/users/{profile.get('id') or profile.get('Id')}/public-key")
        pub_der = base64.b64decode(pub.get("publicKey") or pub.get("PublicKey"))
        user_pub = serialization.load_der_public_key(pub_der)
        org_key = os.urandom(64)
        wrapped = user_pub.encrypt(org_key, asym_padding.OAEP(asym_padding.MGF1(hashes.SHA1()), hashes.SHA1(), None))
        _, org_keys = rsa_keys(org_key)
        org = self.req("POST", "api/organizations", json={
            "name": "Chiikawa Family", "billingEmail": email, "planType": 0,
            "key": f"4.{b64(wrapped)}", "keys": org_keys, "collectionName": enc("Shared", org_key),
        })
        org_id = org.get("id") or org.get("Id")
        cols = self.req("GET", f"api/organizations/{org_id}/collections")
        col_id = (cols.get("data") or cols.get("Data"))[0]
        col_id = col_id.get("id") or col_id.get("Id")
        item = self.login_item("Family Netflix", "family@chiikawarden.test", "shared-Dev-Only-42!",
                               "https://netflix.com", key=org_key, org=org_id)
        self.req("POST", "api/ciphers/create", json={"cipher": item, "collectionIds": [col_id]})

    def fix_shared_totp(self) -> int:
        """Older seeds gave Cloudflare the same secret as GitHub (identical codes). Re-key it in place."""
        def lower(o):
            if isinstance(o, dict):
                return {(k[:1].lower() + k[1:]): lower(v) for k, v in o.items()}
            if isinstance(o, list):
                return [lower(v) for v in o]
            return o
        logins = {}
        for c in lower(self.req("GET", "api/sync?excludeDomains=true")).get("ciphers", []):
            if c.get("type") != 1 or c.get("organizationId") or c.get("key") or not (c.get("login") or {}).get("totp"):
                continue
            try:
                logins[decrypt(c["name"], self.user_key).decode()] = (c, decrypt(c["login"]["totp"], self.user_key).decode())
            except Exception:
                continue
        fixed = 0
        if "Cloudflare" in logins and "GitHub" in logins and logins["Cloudflare"][1] == logins["GitHub"][1]:
            c = logins["Cloudflare"][0]
            c["login"]["totp"] = enc(CLOUDFLARE_TOTP, self.user_key)
            c["lastKnownRevisionDate"] = c.get("revisionDate")
            self.req("PUT", f"api/ciphers/{c['id']}", json=c)
            fixed = 1
        return fixed

    def enable_totp(self):
        self.req("POST", "api/two-factor/get-authenticator", json={"masterPasswordHash": self.pw_hash})
        self.req("POST", "api/two-factor/authenticator",
                 json={"key": TOTP_SECRET, "token": totp(TOTP_SECRET), "masterPasswordHash": self.pw_hash})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("server", help="e.g. https://m1pro.local:18843")
    ap.add_argument("--ca", help="Caddy root.crt to trust")
    args = ap.parse_args()
    srv = Server(args.server, args.ca)

    for email, name, kdf in ACCOUNTS:
        created = srv.register(email, name, kdf)
        sess = srv.login(email, kdf)
        if created or sess.cipher_count() == 0:
            sess.seed_personal()
            if email.startswith("usagi"):
                sess.seed_org(email)
        elif sess.fix_shared_totp():
            print(f"    re-keyed Cloudflare's one-time code for {email}")
        if kdf.get("totp") and not sess.used_2fa:
            sess.enable_totp()
        print(f"  ✓ {email:32} kdf={'Argon2id' if kdf['kdf'] else 'PBKDF2'}"
              f"{'  2FA=TOTP' if kdf.get('totp') else ''}{'' if created else '  (already existed)'}")
    print(f"\nPassword for all accounts: {PASSWORD}\nTOTP secret: {TOTP_SECRET}")


if __name__ == "__main__":
    sys.exit(main())
