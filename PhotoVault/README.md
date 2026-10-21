# PhotoVault

An offline, encrypted photo and video vault for iPhone. It has no network
access, no cloud sync and no tracking, and asks for a passcode at every
launch. The Photos app is used only to import items and, when you choose,
to save them back.

- [docs/SECURITY.md](docs/SECURITY.md): threat model, key hierarchy, decisions, OWASP MASVS mapping
- [docs/FORMAT.md](docs/FORMAT.md): byte-exact on-disk formats

## Status

| Step | Content | State |
|---|---|---|
All seven steps are written. **None of it has been compiled yet**: it was
written in an environment without a Swift toolchain. The first build in Xcode
is the first compile, so expect a few small fixes. The file formats were
checked against an independent Python implementation, and the Xcode project
against a pbxproj parser.

| Step | Content |
|---|---|
| 1 | VaultCore encryption: key hierarchy, Secure Enclave binding, streaming AES-GCM, Padmé |
| 2 | Xcode project, first-run setup, lock screen, attempt limits, lock on background, settings |
| 3 | Import from Photos, encrypted blobs and catalog, thumbnails, delete originals from Photos |
| 4 | UIKit grid, zoomable photo viewer, streaming encrypted video player |
| 5 | Albums: create, rename, delete, add and remove items, import into an album |
| 6 | Multi-select (tap or two-finger swipe), delete, add to album, Save to Photos with optional location removal |
| 7 | Catalog backup and recovery, screenshot warning, memory-pressure handling, signposts, performance and launch tests, app icon |

## Layout

```
PhotoVault.xcodeproj       the iOS app (folders below are picked up automatically)
App/                       the iOS app: lock screen, setup, library grid, viewer, import
AppTests/                  on-device tests: Secure Enclave, Keychain, real Argon2 timing
UITests/                   launch time, and "nothing visible before the passcode"
VaultCore/                 Swift package: all crypto, formats and lock logic, no UI
  Sources/VaultCore/
  Tests/VaultCoreTests/    Swift Testing suites + generated ReferenceVectors.swift
tools/reference/           independent Python implementation of the formats
docs/
```

## Running the app on your iPhone

1. Open `PhotoVault/PhotoVault.xcodeproj` in Xcode 16 or newer.
2. Select the **PhotoVault** target, open **Signing & Capabilities**, and pick
   your Team. A free Apple ID works. If the bundle ID `com.kishhero.PhotoVault`
   is taken, change it to anything unique.
3. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**.
4. Choose your iPhone as the run destination and press Run (⌘R).

With a free Apple ID the install expires after 7 days. Press Run again to
renew it; the vault survives as long as you don't delete the app.

Run the on-device tests with **Product → Test (⌘U)** with the iPhone selected.
The Secure Enclave tests are skipped on the Simulator, which has no Secure
Enclave. The tests use their own Keychain names and temporary folders, so they
never touch the real vault.

## Running the tests

On a Mac with Xcode 16 or newer:

```sh
cd PhotoVault/VaultCore
swift test
```

The first run downloads swift-sodium (libsodium). Swift Package Manager also
fetches swift-crypto, which is used only on Linux, so the iOS app never links
it. Commit the `Package.resolved` this creates, to pin both.

Every test uses generated data. No real photo or video is read.

The Secure Enclave and Keychain code compiles only for iOS and is exercised
from the app's test target on a real device (step 2), because neither works
inside `swift test`.

## Measuring performance

| What | Target | How |
|---|---|---|
| Cold launch | Under 2 s on a mid-range iPhone (launch does no crypto) | Run `LaunchPerformanceTests` in `UITests` on a device. Or use Instruments → **App Launch**. |
| Unlock | About 0.5 s (Argon2id, tuned on the phone at setup) | Instruments → **Points of Interest**: the "Unlock" interval. The `kdfTiming` test in `AppTests` prints the exact time. |
| Import | Flat memory; time per item shown in Instruments | Instruments → **Allocations** + **Points of Interest** ("Import item") while importing 20+ items |
| Scrolling | No hitches at 60/120 Hz | Instruments → **Animation Hitches** while flinging the grid; "Thumbnail" intervals show decrypt cost |
| Photo viewer | ~40 MB per photo at screen size | Instruments → **Allocations** while swiping through photos; "Decode photo" intervals |
| Video | Instant seeking, no plaintext file | Scrub a long video; check the app container afterwards (Devices and Simulators → Download Container) |
| Battery | No background work at all | Xcode → Debug navigator → **Energy Impact** should read Low/None when idle; there are no background modes, no location, no network |
| Encryption throughput | Faster than flash storage | `PerformanceTests` in VaultCore: run with the Release configuration and set a baseline |
| App size | Small: one dependency (libsodium) | Product → Archive → Distribute → *App Thinning: All compatible device variants* report |
| Network | Zero connections | Settings → Privacy & Security → **App Privacy Report** after using the app |

### Reference vectors

`ReferenceVectors.swift` is generated by an independent Python implementation
built on different crypto libraries (pyca/cryptography, PyNaCl's libsodium,
and the reference Argon2 from argon2-cffi):

```sh
python3 -m venv .venv && .venv/bin/pip install cryptography pynacl argon2-cffi
.venv/bin/python tools/reference/vault_reference.py --self-test
.venv/bin/python tools/reference/vault_reference.py --emit-swift > VaultCore/Tests/VaultCoreTests/ReferenceVectors.swift
```

The Swift tests require byte-identical output, so a format mistake in either
implementation shows up as a failing test.
