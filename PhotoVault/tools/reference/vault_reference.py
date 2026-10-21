#!/usr/bin/env python3
"""Independent reference implementation of the PhotoVault on-disk formats.

This is NOT used by the app. It exists so the Swift code in VaultCore can be
checked against a second implementation written separately from it, on top of
different crypto libraries (pyca/cryptography for AES-GCM and HKDF, PyNaCl's
libsodium and argon2-cffi's reference Argon2 for the KDF).

    python3 vault_reference.py --self-test     # format + tamper checks
    python3 vault_reference.py --emit-swift    # regenerate ReferenceVectors.swift

The byte layouts are specified in docs/FORMAT.md. Keep the three in sync.

Requires: pip install cryptography pynacl argon2-cffi
"""

import argparse
import hashlib
import struct
import sys

import argon2.low_level
import nacl.pwhash.argon2id
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# --- Constants (must match VaultCore/Sources/VaultCore/FormatConstants.swift) ---

HEADER_MAGIC = b"PVLT"
HEADER_VERSION = 1
KDF_ARGON2ID = 1
HEADER_SIZE = 100
HEADER_AAD_SIZE = 40
# Bounds checked BEFORE running the KDF, so a corrupted header cannot make
# unlock spin for years or allocate unbounded memory.
KDF_OPS_RANGE = range(1, 16 + 1)
KDF_MEM_MIN = 8 * 1024
KDF_MEM_MAX = 256 * 1024 * 1024

STREAM_MAGIC = b"PVSB"
STREAM_VERSION = 1
STREAM_HEADER_SIZE = 16
TAG_SIZE = 16
LENGTH_PREFIX_SIZE = 8

CATALOG_MAGIC = b"PVCT"
CATALOG_VERSION = 1
CATALOG_HEADER_SIZE = 40

INFO_KEK = b"PhotoVault v1 kek"
INFO_INDEX = b"PhotoVault v1 index"
INFO_ITEM_WRAP = b"PhotoVault v1 item-wrap"
AAD_ITEM_KEY = b"PhotoVault v1 item-key"
INFO_CATALOG = b"PhotoVault v1 catalog"
INFO_BLOB_ORIGINAL = b"PhotoVault v1 blob original"
INFO_BLOB_THUMBNAIL = b"PhotoVault v1 blob thumbnail"
STANDARD_LOG2_CHUNK = 18


class AuthError(Exception):
    pass


# --- Padme (Nikitin et al., "Reducing Metadata Leakage from Encrypted Files
#     and Communication with PURBs", PETS 2019, Algorithm 1) ---

def padme(length: int) -> int:
    if length < 2:
        return length
    e = length.bit_length() - 1          # floor(log2(L))
    s = e.bit_length()                   # floor(log2(E)) + 1
    last_bits = e - s
    mask = (1 << last_bits) - 1
    return (length + mask) & ~mask


# --- KDF / key hierarchy ---

def argon2id(password: bytes, salt: bytes, ops: int, mem_bytes: int) -> bytes:
    """Argon2id v1.3, p=1, 32-byte output: libsodium's crypto_pwhash."""
    via_sodium = nacl.pwhash.argon2id.kdf(32, password, salt, opslimit=ops, memlimit=mem_bytes)
    via_reference = argon2.low_level.hash_secret_raw(
        password, salt, time_cost=ops, memory_cost=mem_bytes // 1024,
        parallelism=1, hash_len=32, type=argon2.low_level.Type.ID, version=19)
    assert via_sodium == via_reference, "libsodium and reference Argon2 disagree"
    return via_sodium


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def derive_kek(pin: bytes, salt: bytes, ops: int, mem: int, device_secret: bytes) -> bytes:
    return hkdf(argon2id(pin, salt, ops, mem) + device_secret, salt, INFO_KEK)


def header_prefix(binding: int, ops: int, mem: int, salt: bytes) -> bytes:
    assert len(salt) == 16
    prefix = HEADER_MAGIC + struct.pack(">BBBBQQ", HEADER_VERSION, KDF_ARGON2ID, binding, 0, ops, mem) + salt
    assert len(prefix) == HEADER_AAD_SIZE
    return prefix


def create_header(pin, device_secret, binding, ops, mem, salt, master_key, nonce) -> bytes:
    prefix = header_prefix(binding, ops, mem, salt)
    kek = derive_kek(pin, salt, ops, mem, device_secret)
    sealed = AESGCM(kek).encrypt(nonce, master_key, prefix)  # ciphertext || tag
    header = prefix + nonce + sealed
    assert len(header) == HEADER_SIZE
    return header


def unlock(pin, device_secret, header: bytes) -> bytes:
    if len(header) != HEADER_SIZE or header[:4] != HEADER_MAGIC:
        raise ValueError("malformed header")
    version, kdf, binding, reserved, ops, mem = struct.unpack(">BBBBQQ", header[4:24])
    if version != HEADER_VERSION or kdf != KDF_ARGON2ID or reserved != 0:
        raise ValueError("unsupported header")
    if ops not in KDF_OPS_RANGE or not KDF_MEM_MIN <= mem <= KDF_MEM_MAX or mem % 1024:
        raise ValueError("KDF parameters out of bounds")
    salt = header[24:40]
    nonce = header[40:52]
    kek = derive_kek(pin, salt, ops, mem, device_secret)
    try:
        return AESGCM(kek).decrypt(nonce, header[52:], header[:HEADER_AAD_SIZE])
    except InvalidTag:
        raise AuthError("wrong passcode")


def subkey(master_key: bytes, info: bytes) -> bytes:
    return hkdf(master_key, b"", info)


def wrap_item_key(master_key: bytes, item_key: bytes, item_id: bytes, nonce: bytes) -> bytes:
    wrap_key = subkey(master_key, INFO_ITEM_WRAP)
    return nonce + AESGCM(wrap_key).encrypt(nonce, item_key, AAD_ITEM_KEY + item_id)


# --- Chunked streaming AEAD (STREAM construction, Tink-style nonces) ---

def chunk_nonce(prefix: bytes, index: int, last: bool) -> bytes:
    return prefix + struct.pack(">IB", index, 1 if last else 0)


def stream_encrypt(content: bytes, key: bytes, context: bytes, log2_chunk: int,
                   prefix: bytes, pad: bool = True) -> bytes:
    assert len(prefix) == 7
    chunk = 1 << log2_chunk
    plain = struct.pack(">Q", len(content)) + content
    total = padme(len(plain)) if pad else len(plain)
    plain += bytes(total - len(plain))
    count = max(1, -(-total // chunk))
    header = STREAM_MAGIC + bytes([STREAM_VERSION, log2_chunk, 0, 0, 0]) + prefix
    assert len(header) == STREAM_HEADER_SIZE
    aad = header + context
    gcm = AESGCM(key)
    out = [header]
    for i in range(count):
        piece = plain[i * chunk:(i + 1) * chunk]
        out.append(gcm.encrypt(chunk_nonce(prefix, i, i == count - 1), piece, aad))
    return b"".join(out)


def stream_decrypt(blob: bytes, key: bytes, context: bytes) -> bytes:
    if len(blob) < STREAM_HEADER_SIZE:
        raise ValueError("malformed")
    header = blob[:STREAM_HEADER_SIZE]
    if header[:4] != STREAM_MAGIC or header[4] != STREAM_VERSION or header[6:9] != b"\0\0\0":
        raise ValueError("malformed")
    log2_chunk = header[5]
    if not 12 <= log2_chunk <= 24:
        raise ValueError("malformed")
    prefix = header[9:16]
    sealed_chunk = (1 << log2_chunk) + TAG_SIZE
    body = len(blob) - STREAM_HEADER_SIZE
    if body == 0:
        raise ValueError("malformed")
    count = -(-body // sealed_chunk)
    last_len = body - (count - 1) * sealed_chunk
    if last_len <= TAG_SIZE or count > 1 << 32:
        raise ValueError("malformed")
    aad = header + context
    gcm = AESGCM(key)
    plain = []
    for i in range(count):
        start = STREAM_HEADER_SIZE + i * sealed_chunk
        sealed = blob[start:start + sealed_chunk]
        try:
            plain.append(gcm.decrypt(chunk_nonce(prefix, i, i == count - 1), sealed, aad))
        except InvalidTag:
            raise AuthError(f"chunk {i} failed authentication")
    plain = b"".join(plain)
    if len(plain) < LENGTH_PREFIX_SIZE:
        raise ValueError("malformed")
    (length,) = struct.unpack(">Q", plain[:8])
    if length > len(plain) - 8:
        raise ValueError("malformed")
    return plain[8:8 + length]


# --- Catalog envelope (index.enc) and per-blob keys ---

def blob_key(item_key: bytes, role: bytes) -> bytes:
    return hkdf(item_key, b"", role)


def catalog_seal(plaintext: bytes, index_key: bytes, salt: bytes, prefix: bytes) -> bytes:
    assert len(salt) == 32
    header = CATALOG_MAGIC + bytes([CATALOG_VERSION, 0, 0, 0]) + salt
    assert len(header) == CATALOG_HEADER_SIZE
    key = hkdf(index_key, salt, INFO_CATALOG)
    return header + stream_encrypt(plaintext, key, header, STANDARD_LOG2_CHUNK, prefix)


def catalog_open(data: bytes, index_key: bytes) -> bytes:
    header = data[:CATALOG_HEADER_SIZE]
    if len(data) <= CATALOG_HEADER_SIZE or header[:4] != CATALOG_MAGIC or header[4] != CATALOG_VERSION or header[5:8] != b"\0\0\0":
        raise ValueError("malformed catalog")
    key = hkdf(index_key, header[8:40], INFO_CATALOG)
    return stream_decrypt(data[CATALOG_HEADER_SIZE:], key, header)


# --- Deterministic test inputs (mirrored in ReferenceVectors.swift) ---

def pattern(length: int) -> bytes:
    return bytes((i * 31 + 7) & 0xFF for i in range(length))


VECTOR_PIN = b"20251021"
VECTOR_DEVICE_SECRET = bytes(range(0x20, 0x40))
VECTOR_SALT = bytes(range(0x00, 0x10))
VECTOR_MASTER_KEY = bytes(range(0x40, 0x60))
VECTOR_WRAP_NONCE = bytes(range(0x60, 0x6C))
VECTOR_OPS = 2
VECTOR_MEM = 8 * 1024 * 1024
VECTOR_BINDING = 0xFE  # DeviceBinding.testing
VECTOR_ITEM_KEY = bytes(range(0x80, 0xA0))
VECTOR_ITEM_ID = bytes(range(0xA0, 0xB0))
VECTOR_ITEM_NONCE = bytes(range(0xB0, 0xBC))
VECTOR_STREAM_KEY = bytes(range(0xC0, 0xE0))
VECTOR_STREAM_PREFIX = bytes(range(0xE0, 0xE7))
VECTOR_STREAM_CONTEXT = b"item-0001/original"
VECTOR_LOG2_CHUNK = 12
VECTOR_STREAM_LENGTHS = [0, 1, 100, 4087, 4088, 4089, 10000, 70000]
VECTOR_CATALOG_SALT = bytes(range(0xD0, 0xF0))
VECTOR_CATALOG_LENGTH = 1000


def self_test() -> None:
    # Padme: never shrinks, bounded overhead, matches the paper's examples.
    assert [padme(x) for x in (0, 1, 2, 3, 8, 9, 100, 1000)] == [0, 1, 2, 3, 8, 10, 104, 1024]
    worst = max((padme(x) - x) / x for x in range(1, 1 << 20))
    assert worst <= 0.12, worst
    for x in range(0, 1 << 16):
        assert padme(x) >= x
        assert padme(padme(x)) == padme(x)

    header = create_header(VECTOR_PIN, VECTOR_DEVICE_SECRET, VECTOR_BINDING, VECTOR_OPS, VECTOR_MEM,
                           VECTOR_SALT, VECTOR_MASTER_KEY, VECTOR_WRAP_NONCE)
    assert unlock(VECTOR_PIN, VECTOR_DEVICE_SECRET, header) == VECTOR_MASTER_KEY
    for bad_pin, bad_device in ((b"20251022", VECTOR_DEVICE_SECRET), (VECTOR_PIN, bytes(32))):
        try:
            unlock(bad_pin, bad_device, header)
            raise AssertionError("wrong passcode or device secret accepted")
        except AuthError:
            pass
    # Every byte of the header is authenticated.
    for i in range(HEADER_SIZE):
        tampered = bytearray(header)
        tampered[i] ^= 0x01
        try:
            unlock(VECTOR_PIN, VECTOR_DEVICE_SECRET, bytes(tampered))
            raise AssertionError(f"tampered header byte {i} accepted")
        except (AuthError, ValueError):
            pass

    for length in VECTOR_STREAM_LENGTHS + [4096 * 3 - 8]:
        content = pattern(length)
        blob = stream_encrypt(content, VECTOR_STREAM_KEY, VECTOR_STREAM_CONTEXT, VECTOR_LOG2_CHUNK,
                              VECTOR_STREAM_PREFIX)
        assert stream_decrypt(blob, VECTOR_STREAM_KEY, VECTOR_STREAM_CONTEXT) == content
        sealed = (1 << VECTOR_LOG2_CHUNK) + TAG_SIZE
        rejects = [
            blob[:-1],                                   # truncated mid-chunk
            blob + b"\0",                                # extended
            bytes(blob[:5]) + b"\x0d" + blob[6:],        # chunk size changed in header
        ]
        if len(blob) > STREAM_HEADER_SIZE + sealed:
            rejects.append(blob[:STREAM_HEADER_SIZE + sealed])                          # cut at chunk boundary
            rejects.append(blob[:STREAM_HEADER_SIZE] + blob[STREAM_HEADER_SIZE + sealed:])  # first chunk dropped
        for i in range(0, len(blob), 97):
            flipped = bytearray(blob)
            flipped[i] ^= 0x80
            rejects.append(bytes(flipped))
        for bad in rejects:
            try:
                stream_decrypt(bad, VECTOR_STREAM_KEY, VECTOR_STREAM_CONTEXT)
                raise AssertionError(f"tampered stream accepted (length {length})")
            except (AuthError, ValueError):
                pass
        try:
            stream_decrypt(blob, VECTOR_STREAM_KEY, b"item-0001/thumbnail")
            raise AssertionError("blob accepted under the wrong context")
        except AuthError:
            pass
    index_key = subkey(VECTOR_MASTER_KEY, INFO_INDEX)
    sealed = catalog_seal(pattern(VECTOR_CATALOG_LENGTH), index_key, VECTOR_CATALOG_SALT, VECTOR_STREAM_PREFIX)
    assert catalog_open(sealed, index_key) == pattern(VECTOR_CATALOG_LENGTH)
    for i in range(0, len(sealed), 53):
        flipped = bytearray(sealed)
        flipped[i] ^= 0x04
        try:
            catalog_open(bytes(flipped), index_key)
            raise AssertionError(f"tampered catalog byte {i} accepted")
        except (AuthError, ValueError):
            pass
    assert blob_key(VECTOR_ITEM_KEY, INFO_BLOB_ORIGINAL) != blob_key(VECTOR_ITEM_KEY, INFO_BLOB_THUMBNAIL)
    print("reference self-test passed")


def emit_swift() -> None:
    def hx(b: bytes) -> str:
        return b.hex()

    header = create_header(VECTOR_PIN, VECTOR_DEVICE_SECRET, VECTOR_BINDING, VECTOR_OPS, VECTOR_MEM,
                           VECTOR_SALT, VECTOR_MASTER_KEY, VECTOR_WRAP_NONCE)
    argon = argon2id(VECTOR_PIN, VECTOR_SALT, VECTOR_OPS, VECTOR_MEM)
    index_key = subkey(VECTOR_MASTER_KEY, INFO_INDEX)
    wrapped_item = wrap_item_key(VECTOR_MASTER_KEY, VECTOR_ITEM_KEY, VECTOR_ITEM_ID, VECTOR_ITEM_NONCE)

    lines = [
        "// Generated by tools/reference/vault_reference.py --emit-swift. Do not edit by hand.",
        "// Values come from an independent Python implementation (pyca/cryptography,",
        "// libsodium via PyNaCl, and the reference Argon2 via argon2-cffi).",
        "",
        "enum ReferenceVectors {",
        f'    static let pin = "{VECTOR_PIN.decode()}"',
        f'    static let deviceSecret = "{hx(VECTOR_DEVICE_SECRET)}"',
        f'    static let salt = "{hx(VECTOR_SALT)}"',
        f'    static let masterKey = "{hx(VECTOR_MASTER_KEY)}"',
        f'    static let wrapNonce = "{hx(VECTOR_WRAP_NONCE)}"',
        f"    static let opsLimit: UInt64 = {VECTOR_OPS}",
        f"    static let memLimitBytes: UInt64 = {VECTOR_MEM}",
        "",
        "    /// Argon2id(pin, salt, opsLimit, memLimitBytes), 32 bytes.",
        f'    static let argon2idOutput = "{hx(argon)}"',
        "    /// Full 100-byte vault header for the inputs above (binding = .testing).",
        f'    static let header = "{hx(header)}"',
        "    /// HKDF-SHA256(masterKey, salt: empty, info: \"PhotoVault v1 index\").",
        f'    static let indexKey = "{hx(index_key)}"',
        "",
        f'    static let itemKey = "{hx(VECTOR_ITEM_KEY)}"',
        f'    static let itemID = "{hx(VECTOR_ITEM_ID)}"',
        f'    static let itemWrapNonce = "{hx(VECTOR_ITEM_NONCE)}"',
        "    /// nonce || AES-GCM(itemWrapKey, itemKey, aad: \"PhotoVault v1 item-key\" || itemID).",
        f'    static let wrappedItemKey = "{hx(wrapped_item)}"',
        "",
        f'    static let streamKey = "{hx(VECTOR_STREAM_KEY)}"',
        f'    static let streamNoncePrefix = "{hx(VECTOR_STREAM_PREFIX)}"',
        f'    static let streamContext = "{VECTOR_STREAM_CONTEXT.decode()}"',
        f"    static let streamLog2ChunkSize: UInt8 = {VECTOR_LOG2_CHUNK}",
        "",
        "    struct Stream {",
        "        let contentLength: Int",
        "        let padded: Bool",
        "        let blobSize: Int",
        "        let blobSHA256: String",
        "    }",
        "",
        "    /// Content for each vector is `pattern(contentLength)`: byte i = (i * 31 + 7) & 0xFF.",
        "    static let streams: [Stream] = [",
    ]
    for padded in (True, False):
        for length in VECTOR_STREAM_LENGTHS:
            blob = stream_encrypt(pattern(length), VECTOR_STREAM_KEY, VECTOR_STREAM_CONTEXT,
                                  VECTOR_LOG2_CHUNK, VECTOR_STREAM_PREFIX, pad=padded)
            lines.append(
                f'        Stream(contentLength: {length}, padded: {str(padded).lower()}, '
                f'blobSize: {len(blob)}, blobSHA256: "{hashlib.sha256(blob).hexdigest()}"),')
    small = stream_encrypt(pattern(1), VECTOR_STREAM_KEY, VECTOR_STREAM_CONTEXT, VECTOR_LOG2_CHUNK,
                           VECTOR_STREAM_PREFIX)
    lines += [
        "    ]",
        "",
        "    /// HKDF-SHA256(itemKey, salt: empty, info: \"PhotoVault v1 blob original\" / \"... thumbnail\").",
        f'    static let originalBlobKey = "{hx(blob_key(VECTOR_ITEM_KEY, INFO_BLOB_ORIGINAL))}"',
        f'    static let thumbnailBlobKey = "{hx(blob_key(VECTOR_ITEM_KEY, INFO_BLOB_THUMBNAIL))}"',
        "",
        "    /// index.enc for `pattern(catalogLength)` under `indexKey`, with fixed salt and nonce prefix.",
        f'    static let catalogSalt = "{hx(VECTOR_CATALOG_SALT)}"',
        f"    static let catalogLength = {VECTOR_CATALOG_LENGTH}",
        f'    static let catalogSHA256 = "{hashlib.sha256(catalog_seal(pattern(VECTOR_CATALOG_LENGTH), index_key, VECTOR_CATALOG_SALT, VECTOR_STREAM_PREFIX)).hexdigest()}"',
        f"    static let catalogSize = {len(catalog_seal(pattern(VECTOR_CATALOG_LENGTH), index_key, VECTOR_CATALOG_SALT, VECTOR_STREAM_PREFIX))}",
        "",
        "    /// Complete blob for a 1-byte padded content, for byte-level inspection.",
        f'    static let oneByteBlob = "{hx(small)}"',
        "",
        "    static let padme: [(UInt64, UInt64)] = [",
    ]
    for x in (0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 100, 1000, 4096, 4097, 10008, 65536, 1_000_000,
              123_456_789, 4_000_000_000, 1 << 40, (1 << 40) + 1):
        lines.append(f"        ({x}, {padme(x)}),")
    lines += ["    ]", "}", ""]
    sys.stdout.write("\n".join(lines))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--emit-swift", action="store_true")
    args = parser.parse_args()
    if args.emit_swift:
        emit_swift()
    else:
        self_test()
