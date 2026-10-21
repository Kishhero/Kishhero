# On-disk formats (version 1)

Byte-exact spec of what VaultCore writes. Three things must agree, and the
tests check that they do:

- this document
- `VaultCore/Sources/VaultCore/FormatConstants.swift` (the app)
- `tools/reference/vault_reference.py` (an independent implementation that
  generates the test vectors)

All integers are big-endian. "AES-GCM" means AES-256-GCM with a 12-byte nonce
and a 16-byte tag.

## Directory layout

```
Application Support/Vault/        excluded from backups, NSFileProtectionComplete
  vault.hdr                       100 bytes, below
  index.enc                       encrypted catalog (defined in step 3)
  blobs/<random UUID>.bin         one stream blob per original and per thumbnail
```

## `vault.hdr`: 100 bytes

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 4 | magic | `PVLT` |
| 4 | 1 | version | `1` |
| 5 | 1 | KDF | `1` = Argon2id v1.3, one lane (libsodium `crypto_pwhash`) |
| 6 | 1 | device binding | `1` Secure Enclave, `2` Keychain (Simulator), `0xFE` tests |
| 7 | 1 | reserved | must be `0` |
| 8 | 8 | opsLimit | Argon2 passes; must be in 1...16 |
| 16 | 8 | memLimit | bytes; in 8 KiB...256 MiB and a multiple of 1024 |
| 24 | 16 | salt | random, new on every passcode change |
| 40 | 12 | nonce | random, new on every passcode change |
| 52 | 32 | wrapped master key | AES-GCM ciphertext |
| 84 | 16 | tag | AES-GCM tag |

The bounds on opsLimit and memLimit are checked when the header is parsed,
before any key derivation, so a damaged header cannot hang or crash the lock
screen.

```
passcodeKey = Argon2id(passcode, salt, opsLimit, memLimit, 32 bytes)
KEK         = HKDF-SHA256(ikm: passcodeKey || deviceSecret, salt: salt, info: "PhotoVault v1 kek", 32)
wrapped     = AES-GCM(KEK, nonce, plaintext: masterKey, aad: header[0..<40])
```

A wrong passcode, a wrong device secret, or any change to bytes 0–99 makes
the AES-GCM open fail. Nothing else in the file can be used to test a guess.

## Device secret (Secure Enclave binding)

```
enclaveKey  = Secure Enclave P-256 key, kSecAttrAccessibleWhenUnlockedThisDeviceOnly
partner     = software P-256 key: public half kept, private half discarded at creation
deviceSecret = HKDF-SHA256(ECDH(enclaveKey, partner.public), salt: empty,
                           info: "PhotoVault v1 device-binding", 32)
```

Keychain items, all `WhenUnlockedThisDeviceOnly` and not synchronizable:

| service | account | contents |
|---|---|---|
| `PhotoVault.deviceBinding` | `secure-enclave-key` | enclave key `dataRepresentation` (only usable by this phone's Enclave) |
| `PhotoVault.deviceBinding` | `partner-public-key` | partner public key, X9.63 |
| `PhotoVault.deviceBinding` | `keychain-secret` | Simulator only: 32 random bytes |

## Subkeys

```
indexKey    = HKDF-SHA256(masterKey, salt: empty, info: "PhotoVault v1 index", 32)
itemWrapKey = HKDF-SHA256(masterKey, salt: empty, info: "PhotoVault v1 item-wrap", 32)
```

Each item (one photo or video) has its own random 256-bit item key, stored
wrapped in the catalog:

```
wrappedItemKey = nonce (12, random) || AES-GCM(itemWrapKey, nonce, itemKey,
                 aad: "PhotoVault v1 item-key" || itemID (16 raw UUID bytes))   → 60 bytes
```

## Stream blob (`blobs/*.bin`)

```
blob = header (16) || chunk_0 || ... || chunk_{n-1}
```

Header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `PVSB` |
| 4 | 1 | version `1` |
| 5 | 1 | log2(chunk size), 12...24; the app uses 18 (256 KiB) |
| 6 | 3 | reserved, must be `0` |
| 9 | 7 | nonce prefix, random per blob |

The plaintext stream is:

```
stream = contentLength (UInt64) || content || zero padding
|stream| = Padmé(8 + contentLength)        (or 8 + contentLength with padding off)
```

It is cut into chunks of `chunkSize` bytes (the last may be shorter, never
empty), and each one is sealed:

```
nonce_i = noncePrefix (7) || i (UInt32) || (i == n-1 ? 0x01 : 0x00)
chunk_i = AES-GCM(blobKey, nonce_i, stream[i*C ..< (i+1)*C], aad: header || context)
        = ciphertext || tag
```

`context` is supplied by the caller and authenticated, never stored. The
catalog (step 3) will use `"<item UUID>/original"` and `"<item UUID>/thumbnail"`.

The reader works out `n` from the file size, rejects a last chunk of 16 bytes
or fewer, authenticates the first and last chunks when the blob is opened, and
authenticates every other chunk before returning any of its bytes.

### Padmé

```
padme(L) = L                                  if L < 2
E = floor(log2 L);  S = floor(log2 E) + 1;  mask = 2^(E - S) - 1
padme(L) = (L + mask) & ~mask
```

The overhead is at most 11.6% (the worst case, for small files) and shrinks
as files grow.
