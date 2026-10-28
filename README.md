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
| **Official firmware** | One tap for M-VAVE's current release (fetched from their download server, identity read from the file, so a new official version appears without an app update) and one tap for the V15 recovery image the hub keeps. |
| **Install** | The same two-step USB-MIDI update protocol the hub and M-VAVE's updater use: handshake, step 1 (the running firmware stages the loader), step 2 (the loader writes the image), restart, identity check. Packages are checked against the catalogue (size, SHA-256, package identity) before a byte is written. Resumes an interrupted update when the FM-1 is left in update mode. Back to the official V15 (exact file only). Install a `.fwsc` from the Files app (GitHub release, or M-VAVE's own file). |
| **Backups** | A backup saves which firmware is on the FM-1 and keeps its package so it can be put back later, one tap. The package is found automatically: the hub's catalogue, then the phone (every package the app ever installed is kept, about 0.6 MB each), then the maker's GitHub releases for that firmware family (a release the hub has not synced yet), then M-VAVE's server for official versions. On Felucca-family firmwares (Felucca and everything built on it: Melodee, X0X, Ghoulbox, Jangada, Hortator, Salt, ChoralRoot, …) it also reads the **music archive** over USB: current music, settings, projects A–D, user banks, FM6 patches, sample slots. Restore the firmware, restore the archive. The archive file is the Felucca editor's own `felucca-backup` v1 JSON, so it opens there too. Optional automatic backup before every install. |
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

`.github/workflows/ios.yml` compiles the app on every push (unsigned, for the simulator, so it needs no secrets) and
then archives, signs and uploads it to TestFlight when four repository secrets are present. Signing uses Xcode's
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

5. Push to `main` or run the workflow by hand (Actions → iOS → Run workflow). The build number is
   `yyyymmdd.run` (UTC date and the workflow run number, e.g. `20261027.9`); Settings in the app shows it.
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
  MIDI/           MIDIEngine.swift           CoreMIDI client, UMP SysEx7 in/out
                  MIDILink.swift             one in/out pair with a SysEx queue
                  SysexQueue.swift
  Services/       CatalogStore, PackageStore, LibraryStore, DeviceController, AppSettings, Paths
  Views/          Firmwares/, Device/, Library/, Settings/, Components/, Theme.swift, RootView.swift
```

Where things are kept on the phone (Files › On My iPhone › FM-1 Hub):

- `Packages/` downloaded `.fwsc` files, named `id-version-sha8.fwsc`
- `Snapshots/<uuid>/package.fwsc` and `felucca-backup.json`
- `library.json` history and snapshot index

## Protocol notes

The FM-1 does not read its own flash back over MIDI: an update is the device *pulling* a package from the host
(cmd `0x30` read requests on the logical image, answered with 7-bit packed data). A "firmware backup" is therefore the
exact package by SHA-256, which the app stores. Music and settings are a different protocol, offered only by Felucca-
family firmwares (`F0 7D 46 4C …`), which the app speaks when the device answers `BACKUP_LIST`. Other firmwares have
their own editors and backup tools; the app says so instead of pretending.

## Licence

GPL-3.0 (see `LICENSE` and `NOTICE.md`). The protocol code under `FM1Hub/Protocol/` is a Swift port of GPL-3.0-only
code by Leo Kuroshita (@kurogedelic, Hügelton Instruments) from the hub's installer and the Felucca web editor. Each
firmware in the catalogue has its own licence (shown on its card).

Not affiliated with M-VAVE or with the hub. Flashing can leave a device needing a rescue; read the hub's
[knowledge base](https://thefirmwarehub.com/kb/) first. Privacy: [PRIVACY.md](PRIVACY.md). Support: [SUPPORT.md](SUPPORT.md).

## App Store

`appstore/metadata/` holds the listing (fastlane `deliver` layout). The **App Store** workflow
(`.github/workflows/appstore.yml`, run by hand) builds the app for the simulator, takes the screenshots in a demo mode
(`-FM1Screenshots YES`, sample data in memory only, never on a real launch), uploads listing and screenshots, sets the
price to free, fills the age rating, attaches the newest processed build to version 1.0, and prints the status of
builds and versions. It never submits for review.
