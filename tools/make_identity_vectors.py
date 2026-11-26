"""Makes packages/fjelia_core/test/vectors/identity_v1.json with Python's
`cryptography`, an implementation independent of Fjelia's Dart code, for
docs/identity-and-sync-security.md. Every key here is a test key.

Run: python3 tools/make_identity_vectors.py  (needs `cryptography`)
"""
import base64, hashlib, hmac, json, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

b64 = lambda b: base64.b64encode(b).decode()

def key(n):
    """A test key from a fixed scalar."""
    return ec.derive_private_key(int(hashlib.sha256(f"fjelia test key {n}".encode()).hexdigest(), 16) % (2**255), ec.SECP256R1())

def spki(k):
    return k.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)

def kid(k):
    return hashlib.sha256(spki(k)).hexdigest()[:32]

def canonical(o):
    # Keys sorted by UTF-16 code units, no white space, integers only.
    if isinstance(o, dict):
        items = sorted(o.items(), key=lambda kv: kv[0].encode("utf-16-be"))
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + canonical(v) for k, v in items) + "}"
    if isinstance(o, list):
        return "[" + ",".join(canonical(v) for v in o) + "]"
    if isinstance(o, bool) or o is None:
        return json.dumps(o)
    if isinstance(o, int):
        return str(o)
    if isinstance(o, str):
        return json.dumps(o, ensure_ascii=False)
    raise TypeError(o)

def sign(k, data):
    r, s = decode_dss_signature(k.sign(data, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")

def hkdf(secret, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(secret)

person, dev_sign, dev_enc, rcpt_enc, eph = key("person"), key("device sign"), key("device enc"), key("recipient enc"), key("ephemeral")
def scalar(k):
    return format(k.private_numbers().private_value, "064x")

out = {"v": 1, "note": "Test keys only. Made by tools/make_identity_vectors.py."}

out["keys"] = {n: {"private": scalar(k), "spki": b64(spki(k)), "id": kid(k)}
               for n, k in [("person", person), ("device_sign", dev_sign), ("device_enc", dev_enc),
                            ("recipient_enc", rcpt_enc), ("ephemeral", eph)]}

sample = {"b": [1, {"y": "ü", "x": True}], "a": None, "é": "line\nbreak", "B": 7, "😀": "astral", "Ａ": "bmp"}
out["canonical_json"] = {"input": sample, "output": canonical(sample)}

device_list = {
    "v": 1, "person": kid(person), "person_key": b64(spki(person)), "version": 1,
    "issued": "2026-11-27T10:00:00Z",
    "devices": [{"id": kid(dev_sign), "sign_key": b64(spki(dev_sign)), "enc_key": b64(spki(dev_enc)),
                 "name": "Test MacBook", "platform": "macos", "added": "2026-11-27T10:00:00Z"}],
    "removed": [],
}
signed = canonical(device_list).encode()
out["device_list"] = {"list": device_list, "canonical": signed.decode(), "sig": b64(sign(person, signed))}

shared = eph.exchange(ec.ECDH(), rcpt_enc.public_key())
recipient_id = "0123456789abcdef0123456789abcdef"
sender_id = kid(dev_sign)
wrap_key = hkdf(shared, recipient_id.encode(), b"fjelia wrap v1")
data_key = bytes(range(32))
wrap_nonce = bytes(range(100, 112))
out["key_wrap"] = {
    "ephemeral": "ephemeral", "recipient": "recipient_enc",
    "recipient_device": recipient_id, "sender_device": sender_id,
    "shared_secret": shared.hex(), "wrap_key": wrap_key.hex(),
    "data_key": data_key.hex(), "nonce": wrap_nonce.hex(),
    "wrapped": AESGCM(wrap_key).encrypt(wrap_nonce, data_key, sender_id.encode()).hex(),
}

header = {"v": 1, "from": sender_id, "person": kid(person), "seq": 1234, "sent": "2026-11-27T10:00:00Z", "nonce": b64(bytes(range(200, 212)))}
aad = canonical(header).encode()
plain = '[{"table":"race_goals","op":"upsert"}]'.encode()
out["body"] = {"data_key": data_key.hex(), "header": header, "aad": aad.decode(),
               "nonce": bytes(range(200, 212)).hex(), "plaintext": plain.decode(),
               "ciphertext": AESGCM(data_key).encrypt(bytes(range(200, 212)), plain, aad).hex()}

alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
code_bytes = hashlib.sha256(b"fjelia test recovery").digest()[:20]
bits = "".join(f"{b:08b}" for b in code_bytes)
code = "".join(alphabet[int(bits[i:i+5], 2)] for i in range(0, 160, 5))
code = "-".join(code[i:i+4] for i in range(0, 32, 4))
rkey = hkdf(code_bytes, kid(person).encode(), b"fjelia recovery v1")
rnonce = bytes(range(50, 62))
person_der = person.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
out["recovery"] = {"code": code, "code_bytes": code_bytes.hex(), "person": kid(person),
                   "key": rkey.hex(), "nonce": rnonce.hex(), "person_key_pkcs8": person_der.hex(),
                   "blob": AESGCM(rkey).encrypt(rnonce, person_der, None).hex()}

token = bytes(range(16))
a, b = sorted([kid(dev_sign), recipient_id])
mac = hmac.new(token, (a + b).encode(), hashlib.sha256).digest()
out["six_digit_code"] = {"token": token.hex(), "device_a": kid(dev_sign), "device_b": recipient_id,
                         "code": f"{int.from_bytes(mac[:4], 'big') % 1_000_000:06d}"}

json.dump(out, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(sys.argv[1], "a").write("\n")
print("ok")
