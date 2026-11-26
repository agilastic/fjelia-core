# People, devices, passes and end-to-end encryption

Status: design for review (phase 0). Nothing here is built yet beyond what
"Today" says. Version 1 of every format below.

## 1. Goals

- A person (athlete or coach) uses any number of devices: iPhone, iPad,
  Macs, later Android phones, Windows and Linux PCs. They all sync with
  each other and behave as one.
- FjeliaPro and coaching seats belong to the person, not to one device,
  whatever store they were bought in.
- A coach looks after many athletes; an athlete may have more than one
  coach. Every athlete's data reaches exactly their own devices and the
  devices of the coaches they chose, nobody else.
- Away from the local network, data goes through a relay at
  fjelia-service that cannot read it (end-to-end encryption).
- The server is optional, never required: everything on the local network
  works with fjelia-service down (section 11).
- No accounts: no email, no password. A recovery code instead.

Not goals: hiding *that* two devices talk, or how much (the relay sees
sizes and times); taking back data a coach already received.

## 2. Today

- Each device has one identity: a self-signed P-256 certificate and a
  device id (`fjelia_sync` `DeviceIdentity`). The phone keeps it in the
  keychain, the computer in a file in the app folder.
- Pairing by QR code: the computer shows its certificate fingerprint,
  addresses, port and a one-time token; the phone pins the fingerprint and
  receives a per-pairing secret. Sync runs over that TLS connection.
- Phone ↔ computer only; the computer serves, the phone connects.
- Coaching: an athlete's phone pairs with the coach's computer as role
  `athlete`, with its own database there. Nearby only.
- The Pro pass: ES256, signed by fjelia-service, not bound to a device.

## 3. Words

| Word | Meaning |
|---|---|
| Person | An athlete or a coach. Identified by the person key. |
| Person id | `sha256(person public key, SPKI DER)`, hex, first 32 characters. |
| Device | One installation of Fjelia on one machine. |
| Device id | `sha256(device signing public key, SPKI DER)`, hex, first 32 characters. |
| Device list | The person's devices, signed with the person key. |
| Link | A coach ↔ athlete relation, agreed by both people. |
| Seat | A coach's paid place for one linked athlete. |
| Pass | A token signed by fjelia-service: Pro or a seat, for one device. |
| Envelope | Encrypted changes on their way through the relay. |

## 4. Keys

All keys are P-256 (secp256r1): the only curve Apple's Secure Enclave and
Android's hardware keystore both hold, and the one `fjelia_sync` already
uses. Signatures are ECDSA with SHA-256, written as 64 bytes `r || s`.

| Key | Held by | Purpose | Leaves the device? |
|---|---|---|---|
| Device signing key | each device, in the secure store, hardware-backed where possible | signs envelopes and sync requests; its public key is the device's TLS identity | never |
| Device encryption key | each device, secure store | receives data keys (ECDH) | never |
| Person key | every device of the person, secure store | signs the device list and links | only to a new device of the same person while it joins, and inside the recovery blob |
| Service pass keys | fjelia-service only | sign passes | never; public halves built into the apps |

Secure stores: iOS, iPadOS and macOS Keychain (Secure Enclave for the
device keys); Android Keystore (StrongBox where present); Windows DPAPI
(user scope); Linux Secret Service. The Mac needs a signed build for its
keychain. A platform without a secure store runs no Fjelia identity: it
does not fall back to a plain file.

The person key cannot live in a Secure Enclave, because it has to be
copied to the person's other devices. It is a software key kept in the
secure store, protected by the device's lock.

## 5. The device list

```json
{
  "v": 1,
  "person": "<person id>",
  "person_key": "<SPKI DER, base64>",
  "version": 7,
  "issued": "2026-11-27T10:00:00Z",
  "devices": [
    {
      "id": "<device id>",
      "sign_key": "<SPKI DER, base64>",
      "enc_key": "<SPKI DER, base64>",
      "name": "Alex's MacBook Air",
      "platform": "macos",
      "added": "2026-11-27T10:00:00Z"
    }
  ],
  "removed": ["<device id>"]
}
```

- Signed with the person key over its canonical form (section 10):
  `{"list": <the object>, "sig": "<base64 r||s>"}`.
- `version` only grows. A device keeps the highest valid version it has
  seen and refuses lower ones, so a removed device cannot be brought back
  by replaying an old list.
- A removed device id stays in `removed` for good.
- At most 10 devices (`MAX_DEVICES`); the limit is the service's for Pro
  passes, and the apps say so before an 11th joins.

## 6. Flows

### 6.1 First device

The first start creates the device keys, the person key and the device
list version 1, and shows the recovery code once (section 9).

### 6.2 Add my device

The QR pairing of today, extended. On the new device "Join my devices",
on an existing one "Add a device":

1. The existing device shows the QR code (its certificate fingerprint,
   addresses, port, one-time token) as today.
2. The new device connects with pinned TLS and sends its two public keys,
   name and platform.
3. Both screens show the same six-digit code, derived from both device
   ids and the token (section 10). The person confirms on both. This
   stops a device on the same network that saw the QR code from slipping
   in.
4. The existing device sends the person key, and the device list with the
   new device in it, version + 1, signed.
5. The new list goes to every device of the person at its next sync.

The QR code alone never adds a device; the code on both screens does.

### 6.3 Remove a device

From any other device of the person: list version + 1 without it, its id
in `removed`. From then on nothing new is encrypted for it, and no new
pass is issued to it. What it already holds stays on it; Fjelia says so.

Removing a device does not change the person key. A person who thinks a
removed device was stolen can **renew the person key** from any trusted
device: a new person key, a new list signed by both the old and the new
key, sent to every device and linked coach.

### 6.4 Coach ↔ athlete link

1. Nearby: the coach's device shows a QR code with the coach's person id,
   person public key and a one-time token; the athlete scans it. Remote:
   the coach sends a link with the same content, and both read a
   six-digit code to each other (in person or by phone) before it counts.
2. Both sign a link record with their person keys:
   `{"v":1,"coach":"<id>","athlete":"<id>","scopes":["plan","activities",…],"since":"…"}`.
3. Each side keeps the other's latest device list. The athlete trusts the
   coach as a person: when the coach adds a device, it is on the coach's
   signed list, and the athlete's devices start encrypting for it without
   asking.
4. Ending a link: either side signs `{"ended": "<time>"}`. Nothing new goes
   to the other side from then on.

`scopes` are the sync categories of today (`fjelia_core` `SyncCategory`):
an athlete can share plan and activities and keep health back.

## 7. Moving data

### 7.1 On the local network

Device ↔ device sync over pinned TLS, as today, now between any two
devices of the same person, and between linked people. TLS is end to end
between the two devices; no envelope is needed. Both sides check that the
other's device id is on a valid device list of an allowed person before
sending anything.

Every device both serves and connects (phase 2): Bonjour finds the
others, the one with the smaller device id connects. The change log
(`sync_changes`) is unchanged: changes carry their origin, a device never
gets its own changes back, and taking a change twice changes nothing, so
any arrangement of devices converges.

### 7.2 Through the relay

A page of changes becomes an envelope:

```json
{
  "v": 1,
  "from": "<sender device id>",
  "person": "<person id the data belongs to>",
  "seq": 1234,
  "sent": "2026-11-27T10:00:00Z",
  "recipients": [
    {"device": "<device id>", "epk": "<ephemeral public key, SPKI DER, base64>",
     "nonce": "<12 bytes, base64>", "wrapped": "<48 bytes, base64>"}
  ],
  "nonce": "<12 bytes, base64>",
  "body": "<AES-256-GCM ciphertext and tag, base64>",
  "sig": "<sender device signature, base64>"
}
```

- `body`: the page of changes as JSON (today's `SyncChange.toJson`),
  gzip-compressed, encrypted with AES-256-GCM under a fresh random 32-byte
  data key and a random 12-byte nonce. Associated data: the canonical form
  of the header (every field except `recipients`, `body` and `sig`).
- Per recipient device: a fresh ephemeral P-256 key; the shared secret
  `ECDH(ephemeral, recipient enc_key)`; the wrap key
  `HKDF-SHA256(secret, salt = recipient device id (ASCII), info = "fjelia wrap v1", 32 bytes)`;
  the data key encrypted with AES-256-GCM under the wrap key and a random
  nonce, associated data = the sender device id (ASCII).
- `sig`: the sender's device signing key over the canonical form of
  everything but `sig`.
- Recipients: every device on the current list of the person the data
  belongs to, and every device of every linked person whose scopes cover
  the changes, except the sender.

A receiving device checks, in order: the signature against a device on a
valid list of a person allowed to send this; that it is a recipient;
unwraps the data key; decrypts the body. Any failure drops the envelope
and logs why; nothing partly applies.

### 7.3 The relay

Part of fjelia-service. It keeps envelopes per recipient device until
that device fetches them, at most 30 days. It reads only the header and
the recipient ids. It checks that `from` is on the latest device list it
was given for that person (devices upload their lists, signed), so a
stranger cannot fill someone's queue. Devices authenticate to it with a
signed challenge from their device key. It stores no keys and no
readable training data. A relay that is down only delays: devices also
sync directly when they meet on the local network.

## 8. Passes

```json
{"alg": "ES256", "typ": "JWT", "kid": "2026-1"}
.
{"iss": "fjelia", "aud": "fjelia-device", "kind": "pro",
 "sub": "<person id>", "dev": "<device id>",
 "iat": 1795000000, "exp": 1795604800}
```

- `kind`: `pro` (the person's own subscription) or `seat` (a coach's seat
  for this athlete; then also `"coach": "<coach person id>"`).
- `dev`: the pass counts only on that device. A copied pass is useless
  elsewhere.
- `exp`: at most 7 days after `iat`, and never after the paid period. The
  device asks for a new pass when half has run out.
- Grace: a device whose pass ran out keeps Pro for 7 more days while it
  cannot reach the service (offline, service down). A pass the service
  refused to renew (subscription ended) gets no grace.
- `kid`: which service key signed it. The apps carry two public keys (the
  current one and the next), so the service can change keys without an
  app release; a key is retired by shipping a release without it.
- The service issues passes for at most `MAX_DEVICES` devices per person
  and seat passes only while the seat is held. It learns: a person id,
  device ids, which store paid, and for seats which person ids are
  linked. No names, no training data.
- Purchases from any store (App Store on iPhone, iPad and Mac, Google
  Play, a web shop for Windows and Linux) are tied to the person id once,
  when the purchase is checked.

## 9. Recovery

- The recovery code: 20 random bytes, written as 32 characters of Crockford
  base32 in 8 groups of 4, for example `7K3M-Q9XA-…`. Shown once at the
  first start and on request from a trusted device; never stored by
  Fjelia in readable form.
- The recovery blob: the person key encrypted with AES-256-GCM under
  `HKDF-SHA256(code bytes, salt = person id (ASCII), info = "fjelia recovery v1", 32 bytes)`.
  The code holds 160 bits of chance, so no slow key derivation is
  needed.
- The blob goes with every backup, and, if the person agrees, to
  fjelia-service, which can only hand it back to whoever asks with the
  person id; without the code it is useless.
- With the code, a wiped or new device restores the person key, signs a
  new device list with itself on it, and the person continues. Without
  the code and without any device, the person starts over; their backups
  still hold their data.

## 10. Encodings

- Canonical JSON (for everything signed or used as associated data):
  UTF-8, object keys sorted by their UTF-16 code units, no white space,
  strings with only the escapes JSON requires, numbers as integers. This
  is the subset of RFC 8785 the formats need; no floating-point numbers
  appear in signed data.
- Public keys: SubjectPublicKeyInfo DER, base64 (standard alphabet, with
  padding). Signatures, nonces, ciphertexts: base64.
- Times: ISO 8601 UTC with `Z`, whole seconds.
- The six-digit code (6.2, 6.4):
  `HMAC-SHA256(key = token bytes, message = smaller device id + larger device id (ASCII))`,
  first 4 bytes as an unsigned big-endian number, modulo 1,000,000,
  zero-padded.

## 11. Without the server

| | fjelia-service down |
|---|---|
| Adding, removing devices; recovery with the code from a backup | works (all local) |
| Sync between a person's devices on the same network | works |
| Coach ↔ athlete on the same network | works |
| Pro | works until the pass ends plus 7 days of grace |
| Sync away from home, remote coaching | waits; changes queue on the devices and go out when the relay is back or two devices meet |
| Getting the recovery blob back from the service | waits; the blob in a backup still works |

## 12. What an attacker can and cannot do

| Who | Can | Cannot |
|---|---|---|
| Someone on the same Wi-Fi | see that devices talk | read anything (TLS), add a device (code on both screens), pair as a coach (link needs both people) |
| A curious or broken relay | see sizes, times, device ids, person ids | read training data, add a reader (lists are signed), change an envelope (signed, GCM) |
| A thief with an unlocked device | read what that device holds | stay: removing it stops new data; renewing the person key shuts it out completely |
| A thief with a locked device | little | read the secure store without the device's lock code |
| Someone with a copied pass | nothing | use it on another device (`dev`) or past `exp` |
| A former coach | keep what they received while linked | receive anything after the link or seat ended |
| fjelia-service itself | issue or refuse passes, see who paid and which people are linked | read training data, forge a device list or a link (person keys) |

## 13. Moving from today

- On update, each device keeps its current certificate as its device
  signing identity where the platform allows, and adds the encryption
  key. Devices whose keys cannot be moved into the secure store make new
  ones and re-pair once.
- A phone and a computer paired today as role `self` become devices of the
  same person: the phone creates the person key and the list, and hands
  both to the computer at the next sync, over the pairing already
  trusted. No new QR code.
- An athlete paired today as role `athlete` becomes a link: the athlete's
  phone creates the athlete's person key; the coach's computer creates
  the coach's; the link is signed by both at the next nearby sync.
- The Pro pass of today is replaced by passes for each device.

## 14. Versions and tests

- Every format carries `"v": 1`. A device that meets a higher version it
  does not know keeps the data and asks the person to update Fjelia.
- `packages/fjelia_core/test/vectors/identity_v1.json` holds test vectors
  made with an independent implementation (Python `cryptography`): keys,
  a signed device list, a key wrap, an envelope body, a recovery blob, a
  six-digit code. Every platform's implementation must reproduce or
  accept them byte for byte. The Dart check is
  `packages/fjelia_sync/test/identity_vectors_test.dart`; the vectors are
  made by `tools/make_identity_vectors.py`.
- Phase checks (summary):
  1. One person, four devices; remove one; restore with the recovery code;
     update without pairing again.
  2. Any device to any device; two paths at once give no duplicates; a
     device off for a month catches up.
  3. Pro bought once reaches every device; a copied pass does not count; an
     11th device is refused; changing the service key needs no release.
  4. Mobile data ↔ home through the relay; the relay database holds nothing
     readable; a removed device gets nothing new; local sync works with the
     relay down.
  5. One coach with three devices and forty athletes: each athlete's data
     reaches exactly their devices and the coach's; an assistant coach; a
     former coach gets nothing new.
  6. Android, Windows, Linux pass the vectors; mixed setups (iPhone,
     Android, Windows) work together.
