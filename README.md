# FM-1 Hub for iPhone

The [FM-1 Firmware Hub](https://thefirmwarehub.com/) as a native iPhone app: browse the open-source firmwares for the
**M-VAVE FM-1**, install one over USB straight from the phone, keep a history of what went on the device, and back up /
restore its state.

No account, no server of its own. Settings, history, packages and backups live on the phone (and are visible in the
Files app, so you can copy them to iCloud Drive or a computer).

## What it does

| Area | Details |
| --- | --- |
| **Firmwares** | Live catalogue from `thefirmwarehub.com/catalog.json` (cached for offline). Cards with the firmware's own screen, maker, version, kind tags, beta badge, installs/stars, description. Search, type/style filters (synths, grooveboxes, drums & samplers, chords, trackers, dev, ambient, vintage), sort (installs, newest, added, name, stars), list or grid. Detail page with a facts table (release date, identity, size, SHA-256, licence, your installs) and links (project, release, source, editor, play in browser, cheat sheet, feedback). |
| **Official firmware** | One tap for M-VAVE's current release (fetched from their download server, identity read from the file, so a new official version appears without an app update) and one tap for the V15 recovery image the hub keeps. Both are on the FM-1 tab and first on the Firmwares tab, where the filter for newer FM-1s keeps them: M-VAVE's own firmware runs on both flash chips. |
| **Install** | The same two-step USB-MIDI update protocol the hub and M-VAVE's updater use: handshake, step 1 (the running firmware stages the loader), step 2 (the loader writes the image), restart, identity check. Packages are checked against the catalogue (size, SHA-256, package identity) before a byte is written. Resumes an interrupted update when the FM-1 is left in update mode. Back to the official V15 (exact file only). Install a `.fwsc` from the Files app (GitHub release, or M-VAVE's own file). Warns before, or refuses, a firmware that may brick a newer FM-1 (see [Flash chips](#flash-chips-and-newer-fm-1s)). |
| **Backups** | A backup saves which firmware is on the FM-1 and keeps its package so it can be put back later, one tap. The package is found automatically: first the hub's catalogue, or the maker's GitHub releases if the firmware names a version the hub doesn't have. A firmware the hub doesn't know is looked for on the phone (every package the app ever installed is kept, about 0.6 MB each), on M-VAVE's server for official versions and in its maker's releases. On Felucca-family firmwares (Felucca and those built on it that answer its backup protocol, such as Melodee, Ghoulbox and ChoralRoot) and on SLOOP and the firmwares built on it that answer its protocol, it also reads the **music archive** over USB: current music, settings, projects, user banks, FM6 patches, sample slots. Restore the firmware, restore the archive. The archive file is the editor's own (`felucca-backup` or `sloop-backup` v1 JSON), so it opens there too. The app writes a `sloop-backup` back only to SLOOP: on a firmware built on SLOOP it saves the music but can't put it back, and that firmware's own web editor may or may not open the file. Many firmwares report the same identity: when the firmware can't name itself, you choose it in the backup. Optional automatic backup before every install, on firmwares whose music the app can back up. |
| **History** | Every install: what, when, from where (hub, backup, file, official), identity before and after, success or the error. |
| **Device** | Connect / identify, MIDI port list with "this is my FM-1" for firmwares that name their port after themselves, resume card when a loader is waiting, log. |

Only when all of that fails does a backup ask for a `.fwsc` from Files.

Not in the app: the ROM-bootloader rescue (the "UBOOT1.00" USB disk), which needs a computer. The OCT− rescue mode
(hold OCT− while switching on) works with the normal Install.

## Hardware

- **iPhone 15 or newer**: USB-C to USB-C cable into the FM-1.
- **Older iPhones**: Apple's Lightning to USB (3) Camera Adapter; the powered one is the safe choice.
- The FM-1 is a class-compliant USB MIDI device, so no driver or MFi is involved. If it does not power up from the
  phone, use a powered hub or the adapter's power input.
- Close other MIDI apps while installing.

## Building

Requirements: **Xcode 16 or newer** locally (CI uses Xcode 26 on macos-26 runners because App Store uploads must use the iOS 26 SDK) (the project uses a synchronized folder, so there is no file list to maintain),
iOS 17 deployment target, a free or paid Apple developer account for signing on a device.

1. Open `FM1Hub.xcodeproj`.
2. Select the `FM1Hub` target → Signing & Capabilities → pick your Team. Change the bundle identifier
   (`com.debreczi.fm1hub`) if Xcode asks.
3. Plug in the iPhone, choose it as the run destination, press Run. On a free account, trust the developer profile on
   the phone under Settings → General → VPN & Device Management.

The Simulator has no USB MIDI, so the catalogue, filters, history and backups screens work there but connecting to an
FM-1 needs a real phone.

## TestFlight from GitHub

`.github/workflows/ios.yml` compiles and tests the app on every pull request and on every push to `main` or a
`release/` branch (unsigned, for the simulator, so it needs no secrets). On those pushes it then archives, signs and
uploads it to TestFlight when four repository secrets are present. Signing uses Xcode's
cloud-managed certificates through an App Store Connect API key, so no certificate or provisioning profile is
exported by hand.

One-time setup (needs a paid Apple Developer Program membership):

1. **App ID and app record.** In [App Store Connect](https://appstoreconnect.apple.com) → Apps → `+` → New App:
   platform iOS, bundle ID `com.debreczi.fm1hub` (register it under Identifiers if it is not offered), any name and
   SKU. TestFlight builds can only be uploaded to an existing app record.
2. **API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → `+`.
   Role **App Manager** (Admin also works). Download the `.p8` once; note the **Key ID** and the **Issuer ID**.
3. **Team ID.** [developer.apple.com/account](https://developer.apple.com/account) → Membership details.
4. **Repository secrets** (GitHub → Settings → Secrets and variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `ASC_KEY_ID` | the key's ID, e.g. `A1B2C3D4E5` |
   | `ASC_ISSUER_ID` | the issuer UUID |
   | `ASC_KEY_P8` | the full text of the `.p8` file (or its base64) |
   | `APPLE_TEAM_ID` | the 10-character team ID |

5. Push to `main` or a `release/` branch, or run the workflow by hand on one of them (Actions → iOS → Run workflow).
   The version is `MARKETING_VERSION` in the project file of that branch; the build number is `yyyymmdd.run` (UTC
   date and the workflow run number, e.g. `20261027.9`), so it rises across branches. Settings in the app shows both.
6. First build only: in App Store Connect → TestFlight, answer the export-compliance question (the app uses only
   HTTPS, so "standard encryption, exempt"), then add yourself as an internal tester. The TestFlight app on the phone
   installs it.

If the archive step fails with a signing error on the first run, open the project once in Xcode with your team
selected and let it register the bundle ID, or register `com.debreczi.fm1hub` by hand under Identifiers; cloud
signing then works on the next run.

## Project layout

```
FM1Hub/
  App/            FM1HubApp.swift            entry point, environment objects
  Models/         Catalog.swift              catalog.json model, kinds, sort
                  Records.swift              InstallRecord, Snapshot
                  Look.swift                 per-firmware colours (the hub's)
  Protocol/       SevenBit.swift             7-bit packings, CRC-32, FM1Error
                  FWSCPackage.swift          .fwsc identity, logical image, stock V15 pin
                  FM1Protocol.swift          handshake / identity / read-request framing
                  FM1Updater.swift           find, serve, install, resume
                  FeluccaBackup.swift        Felucca editor backup protocol (LIST/GET/PUT, samples)
                  SloopBackup.swift          SLOOP editor backup protocol (INFO, BK_LIST/GET/PUT, samples)
  MIDI/           MIDIEngine.swift           CoreMIDI client, UMP SysEx7 in/out
                  MIDILink.swift             one in/out pair with a SysEx queue
                  SysexQueue.swift
  Services/       CatalogStore, PackageStore, LibraryStore, DeviceController, AppSettings, Paths
  Views/          Firmwares/, Device/, Library/, Settings/, Components/, Theme.swift, RootView.swift
```

Where things are kept on the phone (Files › On My iPhone › FM-1 Hub):

- `Packages/` downloaded `.fwsc` files, named `id-version-sha8.fwsc`
- `Snapshots/<uuid>/package.fwsc` and `felucca-backup.json` or `sloop-backup.json`
- `library.json` history and snapshot index

## Protocol notes

The FM-1 does not read its own flash back over MIDI: an update is the device *pulling* a package from the host
(cmd `0x30` read requests on the logical image, answered with 7-bit packed data). A "firmware backup" is therefore a
copy of the package, identified by SHA-256, which the app stores. Music and settings are a different protocol, offered by Felucca-family
firmwares and by SLOOP and the firmwares built on it (`F0 7D 46 4C …`, with different command numbers and file formats),
which the app speaks when the device answers its `BACKUP_LIST`. Other firmwares have their own editors and backup tools;
the app says so instead of pretending.

Many firmwares report the same identity (`FM-1_900` has more than twenty), so the identity alone cannot say which one is
running. The app asks the firmware's `INFO` and accepts only a name and version that match the hub's catalogue exactly.
A name with another version than the hub's fetches that version from the firmware's own GitHub releases, when it is
there. If not, a firmware alone on its identity gets the hub's version, marked as such, and on a shared identity the
app looks for no package and the user chooses the firmware, in the backup. The list of firmwares comes
from the hub's catalogue, so a new firmware or version needs no app update.

## Flash chips and newer FM-1s

FM-1s are made with two different flash chips. A firmware written before the newer chip can't save or start another
update on it, so the FM-1 is stuck on that firmware (bricked) until it is rescued from a computer, through the ROM
download mode. The app checks these chips, by the JEDEC ID each one answers with (`FlashChip` in
`FM1Hub/Models/FlashChip.swift`; the app's Settings › Flash chips page says the same):

| JEDEC ID | Chip | FM-1s |
| --- | --- | --- |
| `0x856014` | Puya P25Q80 | The first FM-1s. |
| `0xB36014` | UCUN UC25HQ80 | FM-1s sold since autumn 2026, usually with the M-VAVE logo under the screen. |

**How the app learns the chip.** Only from the running firmware. After the plain identity request (cmd `0x11`, no
body) the app sends the full one (cmd `0x11` with the one-byte body `01`, PERF-1's scheme in felucca-bsp and ESTAMPIE)
to every firmware except M-VAVE's own (`FM-1_0xx`) and those built on its code (`loader: mvave`), the USB rescue
mode and update loaders. A firmware that knows it
answers with its whole identity and may put the chip's ID in bytes 24–26 of the 27-byte reply, high byte first (0: not
read). The reply's text ends at its first zero. The first FM-1s' chip counts only from a reply whose length and
checksum hold; another chip counts from any reply, since it can only make the check stricter. M-VAVE's firmware never reports the chip, so most of the time it is
"not reported" and a newer FM-1 can't be told from a first one. Connect one FM-1 at a time: the app stops when
another one answers (on another USB device) and checks the update loader's model, but while an FM-1 restarts
during an update it can't tell it from another one plugged in at that moment.

**Which firmwares work on it.** The hub's catalogue has a `chip` field for each firmware, which the hub reads from the
package: `new` (every FM-1, the newer chip too), `old` (the first FM-1s only) or `any` (does not check the chip). It
describes the catalogue's package, by SHA-256. M-VAVE's own firmware works on both: the V15 the hub keeps and the files
the app fetched from M-VAVE's server, by SHA-256 (an official-looking identity alone can be a custom firmware's).
Anything else, such as an older version, a file or a backup the catalogue doesn't list, is unknown, unless the app read the catalogue while it listed that very package: the app keeps what the hub said, by SHA-256, in its own storage. If the catalogue stops rating a package, only "the
first FM-1s only" is kept. What a backup's or an interrupted update's own record says counts only when it is "the first
FM-1s only" and nothing else is known: that can only make the check stricter.

**What the app does** (`ChipGuard.verdict`, tested cell by cell in `FlashChipTests`):

| The FM-1 | `new`, `any`, M-VAVE's | `old` | unknown |
| --- | --- | --- | --- |
| reports `0x856014` | install | install | install |
| reports `0xB36014` | install | refused; with *Allow installing on unsafe FM-1s* on, asked as dangerous | red warning |
| reports another ID | `any` installs; `new` and M-VAVE's get a red warning | refused, or asked as dangerous | red warning |
| does not report it | install | red warning | red warning |

The switch is off by default and matters only when the FM-1 reports its chip. The same table applies to restores, file
installs, M-VAVE's firmware and Resume. The check runs again at the point of no return with what the device found there reports, and stops the
install with nothing written if that needs another answer. An install that stops after 0 requests, while a firmware not
known to work on newer FM-1s runs and the FM-1 has not reported the first chip, says that a newer FM-1 may be stuck on
it (holding OCT− does not help there) and links the hub's [rescue page](https://thefirmwarehub.com/tools/rescue/).

## Licence

This app is **GPL-3.0-only**. The full text is in [`LICENSE`](LICENSE).

Copyright (C) 2026 Janos Debreczi.

The protocol code under `FM1Hub/Protocol/` is a Swift port of GPL-3.0-only code by Leo Kuroshita
(@kurogedelic, Hügelton Instruments) from the hub's installer and the Felucca web editor,
Copyright (C) 2026 Leo Kuroshita, Hügelton Instruments. The rest of the app builds on it, so the whole
work carries the same licence — that is why it is GPL-3.0 and not MIT.

The complete corresponding source of every build, TestFlight ones included, is this repository:
<https://github.com/debreczi/fm1firmwarehost>.

Each firmware in the catalogue has its own licence (shown on its card); the catalogue and the firmwares
are not part of this app's source. See also [`NOTICE.md`](NOTICE.md).

Not affiliated with M-VAVE or with the hub. Flashing can leave a device needing a rescue; read the hub's
[knowledge base](https://thefirmwarehub.com/kb/) first. Privacy: [PRIVACY.md](PRIVACY.md). Support: [SUPPORT.md](SUPPORT.md).

## App Store

Each App Store version gets its own branch, `release/<major>.<minor>`, cut from `main` when it is ready to submit;
`main` then carries the next version. `appstore/metadata/` holds the listing (fastlane `deliver` layout). The
**App Store** workflow (`.github/workflows/appstore.yml`, run by hand on a release branch) builds the app for the
simulator, takes the screenshots in a demo mode (`-FM1Screenshots YES`, sample data in memory only, never on a real
launch), uploads listing and screenshots, sets the price to free, fills the age rating, attaches a build of the branch's
version, and prints the status of builds and versions. It attaches the build named when it is run, or else the newest
processed one if the version has no build yet, and only while the version is being prepared or was rejected. It
uploads only when the branch's version is new, being prepared or rejected, and every other version is live or
finished, because `deliver` edits whichever version is open (waiting for review included) and renames it to the
branch's version. It never submits for review. The **App Store Connect** workflow (`.github/workflows/asc.yml`) does
the quicker tasks for the version of the branch it runs on, such as sending a build to the public TestFlight group.
