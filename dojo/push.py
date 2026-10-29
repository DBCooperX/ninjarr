"""Push notifications to phones and browsers that turned them on in Dojo (Web Push).

Dojo encrypts each message for one device (RFC 8291) and hands it to that browser's push service
(Google's for Chrome, Vivaldi and Edge on Android, Mozilla's for Firefox, Apple's for Safari), which
delivers it even when the phone is away from home and the app is closed. The push service only sees
an encrypted blob. Dojo signs every request with its own key pair (VAPID, RFC 8292), made once and
kept in /dojo-data/push.json, so no account anywhere is needed.

Topics a device can pick: broken, ready, playing, update, backup, restart.
"""
import base64
import json
import os
import struct
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

TOPICS = ["broken", "ready", "playing", "update", "backup", "restart"]
SUBJECT = "https://github.com/DBCooperX/ninjarr"   # who sends: push services want a contact, not a person

_lock = threading.Lock()


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _pub_bytes(key):
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def _hkdf(salt, info, ikm, n):
    return HKDF(algorithm=hashes.SHA256(), length=n, salt=salt, info=info).derive(ikm)


def encrypt(p256dh, auth, plaintext):
    """aes128gcm content coding for one Web Push subscription (RFC 8291 / RFC 8188), one record."""
    ua_pub = unb64u(p256dh)
    ua_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_pub)
    as_key = ec.generate_private_key(ec.SECP256R1())
    as_pub = _pub_bytes(as_key)
    ikm = _hkdf(unb64u(auth), b"WebPush: info\x00" + ua_pub + as_pub, as_key.exchange(ec.ECDH(), ua_key), 32)
    salt = os.urandom(16)
    cek = _hkdf(salt, b"Content-Encoding: aes128gcm\x00", ikm, 16)
    nonce = _hkdf(salt, b"Content-Encoding: nonce\x00", ikm, 12)
    body = AESGCM(cek).encrypt(nonce, plaintext + b"\x02", None)     # \x02: the last (and only) record
    return salt + struct.pack(">I", 4096) + bytes([len(as_pub)]) + as_pub + body


def vapid_header(key, endpoint):
    u = urlsplit(endpoint)
    head = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode())
    claims = b64u(json.dumps({"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 12 * 3600, "sub": SUBJECT},
                             separators=(",", ":")).encode())
    r, s = decode_dss_signature(key.sign(f"{head}.{claims}".encode(), ec.ECDSA(hashes.SHA256())))
    jwt = f"{head}.{claims}.{b64u(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"
    return f"vapid t={jwt}, k={b64u(_pub_bytes(key))}"


class Store:
    """push.json: Dojo's key, the devices that turned push on, and what was already announced."""

    def __init__(self, path):
        self.path = Path(path)

    def load(self):
        try:
            d = json.loads(self.path.read_text())
        except (OSError, ValueError):
            d = {}
        if not d.get("key"):
            k = ec.generate_private_key(ec.SECP256R1())
            d["key"] = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()).decode()
            d.setdefault("devices", [])
            self.save(d)
        d.setdefault("devices", [])
        d.setdefault("seen", {})
        return d

    def save(self, d):
        tmp = self.path.with_name(".push.json.new")
        tmp.write_text(json.dumps(d, indent=1))
        os.chmod(tmp, 0o600)
        tmp.replace(self.path)

    def key(self, d):
        return serialization.load_pem_private_key(d["key"].encode(), None)

    def public_key(self):
        with _lock:
            d = self.load()
            return b64u(_pub_bytes(self.key(d)))

    def devices(self):
        with _lock:
            return self.load()["devices"]

    def upsert(self, sub, name, topics):
        with _lock:
            d = self.load()
            dev = next((x for x in d["devices"] if x["endpoint"] == sub["endpoint"]), None)
            if dev is None:
                dev = {"endpoint": sub["endpoint"], "added": int(time.time())}
                d["devices"].append(dev)
            dev.update(keys={"p256dh": sub["keys"]["p256dh"], "auth": sub["keys"]["auth"]},
                       name=name or dev.get("name") or "A browser", topics=[t for t in topics if t in TOPICS])
            self.save(d)
            return dev

    def remove(self, endpoint):
        with _lock:
            d = self.load()
            d["devices"] = [x for x in d["devices"] if x["endpoint"] != endpoint]
            self.save(d)

    def mark(self, key, value):
        """Remember a fact between restarts (which version was announced, what was broken …)."""
        with _lock:
            d = self.load()
            d["seen"][key] = value
            self.save(d)

    def seen(self, key, default=None):
        with _lock:
            return self.load()["seen"].get(key, default)


def send_one(key, dev, msg, urgency="normal"):
    """→ 'ok', 'gone' (the device unsubscribed: forget it) or an error text."""
    try:
        body = encrypt(dev["keys"]["p256dh"], dev["keys"]["auth"], json.dumps(msg).encode())
        r = requests.post(dev["endpoint"], data=body, timeout=10, headers={
            "Authorization": vapid_header(key, dev["endpoint"]), "Content-Encoding": "aes128gcm",
            "Content-Type": "application/octet-stream", "TTL": "86400", "Urgency": urgency,
            # same topic replaces an undelivered older one (e.g. "something broke" twice while offline)
            **({"Topic": msg["tag"][:32]} if msg.get("tag") and msg["tag"].replace("-", "").isalnum() else {})})
    except (requests.RequestException, ValueError, KeyError) as e:
        return f"{type(e).__name__}"
    if r.status_code in (404, 410):
        return "gone"
    return "ok" if r.ok else f"HTTP {r.status_code} {r.text[:120]}"


class Notifier:
    """Sends in the background, so a webhook or a page never waits on a push service."""

    def __init__(self, store, log=print):
        self.store, self.log = store, log
        self.q = []
        self.cv = threading.Condition()
        threading.Thread(target=self._run, daemon=True, name="push").start()

    def notify(self, topic, title, body="", url="/", tag=None):
        with self.cv:
            self.q.append((topic, {"title": title, "body": body, "url": url, "tag": tag or topic}))
            self.cv.notify()

    def wanted(self, topic):
        return any(topic in d.get("topics", []) for d in self.store.devices())

    def _run(self):
        while True:
            with self.cv:
                while not self.q:
                    self.cv.wait()
                topic, msg = self.q.pop(0)
            with _lock:
                d = self.store.load()
                key = self.store.key(d)
                devs = [x for x in d["devices"] if topic in x.get("topics", [])]
            for dev in devs:
                res = send_one(key, dev, msg, "high" if topic == "broken" else "normal")
                if res == "gone":
                    self.store.remove(dev["endpoint"])
                    self.log(f"push: {dev.get('name')} turned notifications off — forgot it")
                elif res != "ok":
                    self.log(f"push to {dev.get('name')} failed: {res}")
