# Security design

## What the app promises

Photos and videos you import are stored only on this iPhone, encrypted, and
open only with your passcode on this phone. The app makes no network
connections and contains no third-party analytics, ads or crash reporting.
Nothing leaves the vault except through "Save to Photos".

**No recovery.** If you forget the passcode, lose or break the phone, or
delete the app, the vault is gone for good. Nobody can recover it, including
the developer and Apple. That follows directly from the design: vault files
are excluded from backups, and the key needs this phone's Secure Enclave.

## Decisions (agreed 2026-10-21)

| Topic | Decision |
|---|---|
| Platform | Native Swift + SwiftUI (UIKit grid), iOS 17+ |
| Passcode | At least 8 characters: digits on the keypad, or a passphrase; asked at every launch |
| Wrong attempts | Escalating delays. Erase after 10 wrong attempts: opt-in, off by default |
| Face ID | Off. If added later, only as a second factor on top of the passcode |
| Size padding | **On** (Padmé, up to 11.6% extra storage) |
| Deleting in the vault | Permanent right away, after a confirmation prompt |
| Live Photos | Still image only in version 1 |
| Delete originals from Photos after import | Offered; full Photos access is requested only the first time you use it |
| Metadata re-scrambling on every launch | Not done: all metadata is already encrypted, and re-encrypting it adds no protection but costs battery, flash wear and launch time |

## Threat model

| Attacker | Protected? | How |
|---|---|---|
| Someone who picks up the unlocked phone | Yes | Passcode at every launch; locks on leaving the app; blank app-switcher snapshot |
| Thief with the locked phone | Yes | iOS Data Protection plus the vault's own encryption |
| Someone with a copy of the files (backup, forensic file dump) | Yes | AES-256-GCM; the key needs the Secure Enclave, so guesses cannot be run off the phone |
| Other apps on the phone | Yes | iOS sandbox; no share sheet, clipboard, URL schemes or extensions |
| Network trackers | Yes | No networking code and no third-party SDKs; check it yourself in App Privacy Report |
| Code running on the phone while it is unlocked (jailbreak, exploit) | Partly | They can get the device secret and then guess the passcode offline. An 8-digit PIN lasts about a day against GPU rigs; a long passphrase lasts much longer. While the vault is open they can read memory. |
| Someone who watches you type the passcode | No | Mitigation: an optional shuffled keypad (step 2) |
| Someone who forces you to unlock | No | Out of scope (no decoy vault) |

## Key hierarchy

```
passcode ──Argon2id (64 MiB, ~0.5 s)──┐
                                      ├─ HKDF ─► KEK ─ AES-GCM unwrap ─► master key (random)
Secure Enclave ECDH (this phone only) ┘                                   ├─ HKDF ─► index key
                                                                          └─ HKDF ─► item-wrap key ─► per-item keys
```

Byte layouts are in [FORMAT.md](FORMAT.md). What each piece is for:

- **Nothing derived from the passcode is stored.** A wrong passcode is detected
  only because AES-GCM refuses to unwrap the master key. There is no password
  hash to steal.
- **Argon2id** makes every guess cost 64 MiB of memory and about half a second.
  It slows attackers down, but it cannot save a short passcode. That is why
  the minimum is 8 characters.
- **Device secret.** Copied files are useless anywhere else, because each guess
  needs a value only this phone's Secure Enclave can compute. Limit: code
  running on the unlocked phone can ask the Enclave for that value once and
  then guess offline. iOS has no documented way for an app's own passcode to
  get hardware-enforced attempt limits; only the device passcode has those.
- **Random master key.** Changing the passcode re-wraps 32 bytes instead of
  re-encrypting every photo.
- **Per-item keys.** Deleting an item destroys its key, so leftover flash
  fragments are unreadable. Each key encrypts exactly one item, so nonces
  cannot repeat.

## Photo and video encryption

Chunked AES-256-GCM (the STREAM construction, using the nonce layout of
Google Tink's streaming AEAD) with 256 KiB chunks. Video can seek without
decrypting the whole file, and memory use stays flat for 4K video.

- **This is the one piece of crypto code written for this project.** CryptoKit
  has no streaming mode, so the chunk framing is ours: about 150 lines on top
  of CryptoKit's AES-GCM. It is a published, analysed construction, not new
  cryptography. It is checked byte for byte against an independent Python
  implementation, and the tests try truncation, extension, reordering,
  duplication, splicing between blobs, header swaps and bit flips.
- **Nonces cannot repeat.** Each blob has a fresh key, and its nonces carry the
  chunk index and a last-chunk flag. Blobs are never rewritten in place.
- **Padmé padding** rounds sizes up, so similar files become exactly the same
  size.

## Lock screen

- **Every launch, and every return to the app, asks for the passcode.** Keys
  are dropped the moment the app reaches the background. If an unlock finishes
  after that, its result is thrown away and the vault stays locked.
- **The PIN keypad is drawn by the app.** Third-party keyboards are blocked
  app-wide, so no keyboard extension sees the passcode or album names. The
  passcode is kept as raw bytes, which are wiped as soon as they have been used.
  Passphrase mode uses SwiftUI's `SecureField`, which holds an unwipeable
  `String`; it is cleared right after use.
- **Attempt limits:**
  - 4 free tries, then 30 s, 1 min, 5 min, 15 min, and 1 hour per try.
  - An attempt is counted before its result is known, so killing the app
    mid-check doesn't give a free guess.
  - Errors unrelated to the passcode (a Keychain or file error) don't use up
    an attempt.
  - The counter lives in the Keychain, so it survives deleting the app's files.
  - Turning the clock back restarts the wait. Turning it forward skips it:
    this is a deterrent, not a cryptographic control.
- **Erase after 10 wrong attempts** (opt-in) destroys the device secret first,
  so the vault is unrecoverable even if deleting the files is interrupted.
- **App switcher and system sheets:** a cover is drawn whenever the app isn't
  active, so the snapshot iOS saves for the app switcher never shows a photo.
- **Screen recording and mirroring:** vault content is hidden while the screen
  is being captured. iOS gives apps no way to block screenshots.
- **No Mac or Vision Pro builds:** "Designed for iPhone" on Mac and on Vision
  Pro is turned off, because the iPhone's Data Protection and Secure Enclave
  guarantees don't carry over there.

## Importing

- **The system photo picker** runs outside the app and hands over only the
  items you select. Picking needs no Photos permission.
- **Originals are stored byte for byte** (HEIC stays HEIC, HEVC stays HEVC)
  inside the encryption. Their EXIF and GPS data is encrypted along with them.
  Thumbnails are re-encoded with no metadata at all.
- **Plaintext on disk:** each picked file sits unencrypted in `incoming/` for
  the few seconds it takes to encrypt it.
  - It is moved there from the picker's temporary file, never copied.
  - It is protected by `NSFileProtectionComplete`.
  - It is deleted as soon as the item is done, whatever the outcome.
  - `incoming/` is swept again at every launch.
- **Crash safety:**
  - Blobs are written to `.tmp` files and renamed when complete, before the
    catalog mentions them. Unreferenced blobs are deleted at the next unlock.
  - The catalog is saved every 10 items and at the end of an import, so a
    crash loses at most the last 10 items, never the vault.
  - If `index.enc` is missing while blobs exist, the vault refuses to open
    instead of deleting everything as unreferenced.
- **Free space** is checked for each item before it is encrypted.
- **Deleting the originals from Photos** is offered after each import and done
  only if you choose it. It needs full Photos access, which iOS asks for the
  first time. The app uses that access for the deletion and nothing else,
  but iOS can't enforce that. Photos keeps deleted items in Recently Deleted
  for 30 days.
- **Locking mid-import** cancels the import. The item being encrypted at that
  moment finishes first (a few seconds for a large video), so its key stays in
  memory that long.

## Things that still leak

- The number of encrypted files, and their rough sizes (a photo versus a long video).
- The order files were written in, to a forensic examiner. Timestamps are
  reset, but inode numbers and change times can't be.
- That the app is installed.
- Whether the passcode is digits or a passphrase, and whether the keypad is
  shuffled (two UserDefaults display settings).
- Short-lived plaintext on disk, both in protected storage:
  - the photo picker's temporary copy while an item is encrypted on import
  - the temporary file handed to Photos on export, which is moved, not copied

## Speed vs. security choices

| Choice | Picked | Why |
|---|---|---|
| Argon2id cost | 64 MiB, passes calibrated to ~0.5 s, at least 3 | Unlock still feels instant; GPU guessing stays expensive |
| Chunk size | 256 KiB | Sub-millisecond seeks; tag overhead 0.006% |
| Lock delay | None, lock on leaving the app | Matches "passcode every launch" |
| Thumbnails | 512 px JPEG, decrypted into memory only, dropped on lock | Smooth scrolling without plaintext on disk |
| Import | 2 items at a time; catalog saved every 10 | Flat memory use; a crash loses at most 10 items |
| Padding | On | Your choice; costs up to 11.6% storage |

## OWASP MASVS v2 mapping

| Control | Status |
|---|---|
| MASVS-STORAGE-1 (sensitive data stored securely) | Encryption above; `NSFileProtectionComplete`; Keychain `WhenUnlockedThisDeviceOnly` |
| MASVS-STORAGE-2 (no leakage) | Excluded from backups; no logs of content, names or keys; no clipboard; third-party keyboards blocked |
| MASVS-CRYPTO-1 (strong, current crypto) | AES-256-GCM, Argon2id, HKDF-SHA256, P-256 ECDH; platform CSPRNG; no custom primitives |
| MASVS-CRYPTO-2 (key management) | Secure Enclave binding, key separation by HKDF label, per-item keys, keys only in memory while unlocked |
| MASVS-AUTH-2 (local auth done right) | The passcode derives the key, so there is no yes/no check to patch out |
| MASVS-AUTH-1/3 | Not applicable: no accounts, no server |
| MASVS-NETWORK-1/2 | Not applicable: no network code at all |
| MASVS-PLATFORM-1 (secure IPC) | Only the system photo picker and Photos add-only; no URL schemes, no extensions |
| MASVS-PLATFORM-2 (WebViews) | Not applicable: none |
| MASVS-PLATFORM-3 (UI leaks) | Blank app-switcher snapshot; content hidden during screen recording and mirroring |
| MASVS-CODE-1–4 | iOS 17 minimum; one pinned dependency (libsodium); imported media parsed only by Apple's ImageIO and AVFoundation |
| MASVS-RESILIENCE | Deliberately skipped. Jailbreak and tamper checks can be bypassed and only matter after the encryption is beaten |
| MASVS-PRIVACY-1–4 | System picker instead of library access; privacy manifest declaring no tracking and no data collection; optional GPS removal; real deletion |
