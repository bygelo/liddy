# Lease protocol

## What a lease is

A lease is an explicit declaration that an agent is busy. It is the opposite of inference: instead of watching process names and guessing that something is working, the agent itself says "I am doing work until T", and Liddy holds the Mac awake for exactly that window.

The alternative is name-matching. `liddy` watches a list of executables — `claude`, `cargo`, `python` — and holds the Mac as long as any of them are running. That works poorly for agents because an agent process sits near 0% CPU between tool calls, waiting on an API response. A CPU-based heuristic would drop the Mac mid-task. A lease sidesteps this entirely: the work says when it starts and when it ends.

A lease has a TTL. If the agent crashes or is killed, the lease expires on its own and the Mac is released — nothing has to notice the crash. This is why `claim` takes `ttlSecond` as a required parameter rather than an optional one.

## Transport

The protocol runs over a single AF_UNIX stream socket. The path is `~/.liddy/liddy.sock`. The socket is created with mode `0600` — only the owning user can read or write it, because a lease claim is a power assertion and no other user on the machine should be able to acquire one.

Framing is one JSON object per line. Each request is a single line of UTF-8 JSON terminated by `\n`. The response is one line of JSON terminated by `\n`. This is deliberate: it makes the protocol debuggable with `nc` and keeps the wire format readable for humans, which matters because the protocol is documented here rather than in a code comment.

The `LineSocketServer` in `AppModel.swift` reads one line, decodes it as `AppRequest`, runs the handler, and encodes the `AppResponse`. If decoding fails, the request is not passed to the handler at all — the fallback is `.status`, which returns a runtime snapshot rather than an error. Section Errors describes what that means for callers.

## Requests and responses

Every lease-related request and its exact JSON shape. The response shapes follow Swift's synthesized `Codable` encoding of `AppResponse`, which wraps the associated value in an `_0` key.

### claim

Declare that work is starting. The `key` field makes the claim idempotent — see Keyed vs unkeyed claims.

Request:

```json
{"claim":{"key":"session-1","label":"build","ttlSecond":300}}
```

Response on success:

```json
{"token":{"_0":"claim:key:session-1"}}
```

The token is always `claim:key:` followed by the key you supplied. You need this token to renew or release the lease.

### renew

Push a lease's expiry further out. Returns false if the token is unknown or already reaped.

Request:

```json
{"renew":{"token":"claim:key:session-1","ttlSecond":300}}
```

Response on success:

```json
{"ok":{"_0":"renewed"}}
```

Response on failure (unknown or expired token):

```json
{"failed":{"_0":"unknown or expired token, claim again"}}
```

### release

Release a lease by its token.

Request:

```json
{"release":{"token":"claim:key:session-1"}}
```

Response on success:

```json
{"ok":{"_0":"released"}}
```

Response on failure (unknown token):

```json
{"failed":{"_0":"unknown token"}}
```

### releaseKey

Release a lease by its key instead of its token. This is shorthand for the common case where you know the key but not the token.

Request:

```json
{"releaseKey":{"key":"session-1"}}
```

Response on success:

```json
{"ok":{"_0":"released"}}
```

Response on failure (no lease for that key):

```json
{"failed":{"_0":"no lease for key"}}
```

### lease

List all currently active leases. Not a claim operation, but the companion read for debugging.

Request:

```json
{"lease":{}}
```

Response:

```json
{"text":{"_0":["a","b"]}}
```

The `text` case carries a `[String]` — one line per lease, formatted by `WorkLease.display`.

## Keyed vs unkeyed claims

When `claim` is called with a `key`, the resulting token is deterministic: `LeaseRegistry.token(forKey:)` produces `claim:key:<key>`. When `claim` is called without a key, the token is random: `claim:<uuid>`.

The difference matters for idempotency. If two `claim` requests arrive with the same `key`, `LeaseRegistry.claim` finds the existing lease in its store and renews it — updating the expiry and label — rather than creating a second lease. The store key is the token, and the token is derived from the key, so there is at most one lease per key.

This is what lets a per-turn hook fire on every turn without leaking a lease per turn. A Claude Code hook that claims on `UserPromptSubmit` and releases on `Stop` will, across many turns, produce one claim and one release per turn — but the second claim with the same key renews the first, so the registry never accumulates stale leases. Without keyed claims, every turn would add a lease that outlived the work it represented, and the Mac would never go to sleep.

An unkeyed claim is a fresh lease every time. This is the right shape for one-shot work where the caller manages the token (e.g., `liddy claim "build" --ttl 300` in a shell script that stores the returned token in a trap).

## TTL and expiry semantics

Every claim sets an expiry time: `Date()` plus `ttlSecond`, clamped to a minimum of 1 second (`max(1, ttlSecond)`). A lease is expired when `Date() >= expiresAt`.

The `LeaseRegistry.active` property prunes expired leases before returning the list. Pruning is also implicit on `release` and `renew`: `renew` checks `store[token]` and returns false if the token is absent or if the lease is process-backed, and `release` removes the token from the store and returns false if it was never there.

What happens when nobody renews: the lease sits in the store until `active` is called, at which point `prune()` removes it. Until then, `active` still reports it as present. In practice, `active` is called by the menu bar on every refresh and by `liddy lease`, so an expired lease disappears from the UI and from `liddy lease` on the next poll — typically within 5 seconds.

What `renew` returns for an unknown or already-reaped token: false. The caller receives `{"failed":{"_0":"unknown or expired token, claim again"}}`. The instruction to "claim again" is deliberate — the old lease is gone and you must start fresh.

## Worked example

### Using `nc -U`

The socket is at `~/.liddy/liddy.sock`. Every line is a JSON request followed by `\n`; every response is a JSON line followed by `\n`.

```bash
# Claim a lease for a "build" with a 300-second TTL, keyed by session ID.
printf '{"claim":{"key":"session-1","label":"build","ttlSecond":300}}\n' \
  | nc -U ~/.liddy/liddy.sock
# {"token":{"_0":"claim:key:session-1"}}

# Renew it before the TTL expires.
printf '{"renew":{"token":"claim:key:session-1","ttlSecond":300}}\n' \
  | nc -U ~/.liddy/liddy.sock
# {"ok":{"_0":"renewed"}}

# Release the lease when the build finishes.
printf '{"release":{"token":"claim:key:session-1"}}\n' \
  | nc -U ~/.liddy/liddy.sock
# {"ok":{"_0":"released"}}
```

`nc -U` opens the socket, sends one line, reads one line, and exits. Each `printf` invocation opens a new connection. The token returned from `claim` must be captured and reused for `renew` and `release` — or the `key` can be reused with `releaseKey` instead.

### Using Python (standard library only)

```python
import socket
import json

SOCK = "/Users/<user>/.liddy/liddy.sock"

def req(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())
    line = b""
    while not line.endswith(b"\n"):
        line += sock.recv(4096)
    return json.loads(line.decode())

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.connect(SOCK)

    # Claim.
    r = req(s, {"claim": {"key": "session-1", "label": "build", "ttlSecond": 300}})
    assert r == {"token": {"_0": "claim:key:session-1"}}, r

    # Renew.
    r = req(s, {"renew": {"token": "claim:key:session-1", "ttlSecond": 300}})
    assert r == {"ok": {"_0": "renewed"}}, r

    # Release.
    r = req(s, {"release": {"token": "claim:key:session-1"}})
    assert r == {"ok": {"_0": "released"}}, r
```

Each `req` call sends one JSON line and reads one response line. The socket is reused across the three operations because `AF_UNIX` stream sockets support multiple request/response pairs on one connection. The `_0` key appears in every response exactly as shown — this is Swift's synthesized `Codable` shape, not a formatting choice that can be configured on the client side.

## Errors

A request that fails to decode — malformed JSON, an unknown case name, wrong types — is answered with `failed`, naming the decode error. Measured against the running app on 2026-09-11:

```
-> {"bogus": 1}
<- {"failed":{"_0":"bad request: DecodingError.typeMismatch: expected value of type AppRequest. Debug description: Invalid number of keys found, expected one."}}

-> not json at all
<- {"failed":{"_0":"bad request: DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not valid JSON."}}
```

This is worth stating because it was not always true. Until 2026-09-11 a decode failure fell back to `AppRequest.status`, so a typo'd or version-skewed request got a plausible full snapshot back and the caller had no way to learn it had sent nonsense — the exact failure mode a documented third-party protocol cannot afford.

A request that decodes successfully but whose handler returns an error uses the `failed` case. The exact shape is:

```json
{"failed":{"_0":"<reason>"}}
```

where `<reason>` is a human-readable string from the handler. Examples from the current implementation:

| Source | Response |
|---|---|
| `renew` on unknown/expired token | `{"failed":{"_0":"unknown or expired token, claim again"}}` |
| `release` on unknown token | `{"failed":{"_0":"unknown token"}}` |
| `releaseKey` with no matching lease | `{"failed":{"_0":"no lease for key"}}` |

A request that decodes successfully and whose handler returns `ok` or `token` uses the corresponding case. There is no mixed partial-success shape: the response is always one of `ok`, `failed`, `snapshot`, `token`, or `text`.

Every JSON string in this document was checked against the running app, not read off the source. The transcript that produced them:

```
{"claim":{"key":"doc-demo","label":"doc demo","ttlSecond":120}}  ->  {"token":{"_0":"claim:key:doc-demo"}}
{"lease":{}}                                                      ->  {"text":{"_0":["npm","claude","esbuild","doc demo (claimed)"]}}
{"renew":{"token":"claim:key:doc-demo","ttlSecond":300}}          ->  {"ok":{"_0":"renewed"}}
{"renew":{"token":"claim:key:nope","ttlSecond":300}}              ->  {"failed":{"_0":"unknown or expired token, claim again"}}
{"release":{"token":"claim:key:nope"}}                            ->  {"failed":{"_0":"unknown token"}}
{"releaseKey":{"key":"doc-demo"}}                                 ->  {"ok":{"_0":"released"}}
{"releaseKey":{"key":"nope"}}                                     ->  {"failed":{"_0":"no lease for key"}}
{"claim":{"key":null,"label":"unkeyed demo","ttlSecond":60}}      ->  {"token":{"_0":"claim:44E544ED-1E9B-4B2F-813F-89C7455DBAA1"}}
```

The last line is the unkeyed shape: with `"key":null` the token is `claim:<UUID>`, so two claims stack as two leases. That is the difference the keyed form exists to avoid.

## Stability

**Contract** (do not change without updating this document):
- The socket path `~/.liddy/liddy.sock` and its `0600` permission.
- The line-delimited JSON framing: one request per line, one response per line.
- The JSON key names and nesting in the request and response bodies listed above — including the `_0` wrapper on single-payload `AppResponse` cases, which is Swift's synthesized `Codable` shape and will change only if `AppResponse` is refactored off its current form.
- The key-to-token derivation `claim:key:<key>`.

**Internal** (may change without notice):
- The `AppRequest` and `AppResponse` enum cases themselves — new cases can be added and existing ones removed as the feature set evolves.
- The reason strings inside `failed` responses — these are user-facing messages, not API contract.
- The `LeaseRegistry` implementation details (the `NSLock`, the store shape, the pruning schedule).
- The `WorkLease.display` formatting for `lease` responses.
