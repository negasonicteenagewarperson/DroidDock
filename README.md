<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="Cablehop icon">

# Cablehop

**Move files between your Mac and your Android phone. Just plug it in.**

A native Mac app that lets you browse your phone like a Finder window and drag files both ways,
over a USB cable or Wi-Fi. Nothing to install on the phone. A free, open-source alternative to
Google's Android File Transfer, MacDroid and OpenMTP.

[![Download](https://img.shields.io/github/v/release/negasonicteenagewarperson/Cablehop?label=Download&color=34c759)](https://github.com/negasonicteenagewarperson/Cablehop/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%20or%20later-blue)
![Apple silicon and Intel](https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-lightgrey)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**[⬇︎ Download the latest Cablehop (.dmg)](https://github.com/negasonicteenagewarperson/Cablehop/releases/latest)** · [Website](https://negasonicteenagewarperson.github.io/Cablehop/)

<br>

<img src="docs/screenshots/camera.png" width="900" alt="Cablehop showing the Camera folder of a Pixel 10 Pro XL connected in File transfer mode">

</div>

---

## Contents

- [What is Cablehop?](#what-is-cablehop)
- [Screenshots](#screenshots)
- [Requirements](#requirements)
- [Install](#install)
- [Opening it the first time (Gatekeeper)](#opening-it-the-first-time-gatekeeper)
- [Connect your phone](#connect-your-phone)
- [Features](#features)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Building from source](#building-from-source)
- [License](#license)

---

## What is Cablehop?

Macs don't come with a way to open an Android phone the way they open an iPhone or a USB drive.
Google's old *Android File Transfer* app is discontinued, and the alternatives I tried were slow,
overpriced, finicky and just not very good. So I built Cablehop, mainly to use myself. It works well
enough now that anyone can use it, free.

Connect your phone and it shows up in the sidebar. Browse its folders,
see your photos as thumbnails, and drag files between it and Finder. It looks and behaves like a
Mac app: Apple's Liquid Glass design on macOS 26 and later, Finder-style lists, Quick Look, the usual
keyboard shortcuts, Light and Dark Mode. It keeps itself up to date, and if something goes wrong,
**Help › Report a Problem** walks you through sending a useful bug report.

It works in two ways:

- **File transfer mode (no setup).** Uses the standard *File transfer* option every Android phone has.
  You get browsing, copying both ways, thumbnails, new folders, renaming and deleting.
- **USB debugging mode (optional, more features).** If you turn on Android's *USB debugging*, Cablehop
  also searches the whole phone, keeps folders in sync, copies and moves files on the phone itself,
  takes screenshots, installs apps, and connects over Wi-Fi.

You can start with file transfer and switch on the extras later. Cablehop notices and upgrades by itself.

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/welcome.webp" alt="The welcome screen with steps to connect a phone"></td>
    <td width="50%"><img src="docs/screenshots/phone-root.webp" alt="The phone's root, showing its storage areas"></td>
  </tr>
  <tr>
    <td><b>Just plug it in.</b> The welcome screen shows how to connect, and how to unlock the extra features.</td>
    <td><b>Phone Root.</b> Every storage area on the phone, including SD cards.</td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/internal-storage.png" alt="The phone's Internal Storage, with folders and files"></td>
    <td width="50%"><img src="docs/screenshots/camera.png" alt="The Camera folder on the phone, listed like a Finder window"></td>
  </tr>
  <tr>
    <td><b>The whole phone.</b> Every folder in Internal Storage, with sizes and dates.</td>
    <td><b>Your photos, Finder-style.</b> Sort by name, size or date and drag files straight into Finder.</td>
  </tr>
</table>

## Requirements

| | |
|---|---|
| **Mac** | Any Apple silicon Mac (M1 through M5, including Pro, Max and Ultra) or Intel Mac |
| **macOS** | 14 Sonoma or later (every Apple silicon Mac can run it). Liquid Glass design on macOS 26 Tahoe and later |
| **Phone** | Any Android phone: Google Pixel, Samsung, Xiaomi, OnePlus, Motorola, Sony, Nothing, Oppo, Vivo, Huawei and others |
| **Android** | File transfer: every version. USB-debugging features: Android 6.0 or later. Wi-Fi pairing: Android 11 or later |
| **Cable** | A USB cable that carries data (some cheap cables only charge) |
| **Optional** | For the USB-debugging features, Google's free platform tools: `brew install android-platform-tools`, or download them from [Google's official Platform-Tools page](https://developer.android.com/tools/releases/platform-tools) ([how to set them up](#unlocking-every-feature-usb-debugging)) |

## Install

1. **Download** `Cablehop-<version>.dmg` from the [latest release](https://github.com/negasonicteenagewarperson/Cablehop/releases/latest).
2. **Open** the downloaded file. A window appears with Cablehop and your Applications folder.
3. **Drag Cablehop onto Applications.**
4. **Eject** the Cablehop disk (click ⏏ next to it in Finder's sidebar). You can delete the .dmg.
5. Open Cablehop from Applications or Launchpad. The first time, see the next section.

You can check that the download wasn't corrupted or tampered with by comparing it with
`SHA256SUMS.txt` from the same release:

```bash
shasum -a 256 ~/Downloads/Cablehop-*.dmg
```

## Opening it the first time (Gatekeeper)

The first time you open Cablehop, macOS shows a message like *"Cablehop" Not Opened: Apple could
not verify "Cablehop" is free of malware*.

**Why:** Apple's Gatekeeper only opens downloaded apps straight away if the developer paid for an
Apple Developer ID and had Apple *notarize* the app. Cablehop is free and open source and isn't
notarized yet. The code is all here for anyone to read, and the release files come with checksums.

**To open it (once):**

1. Click **Done** on the message.
2. Open **System Settings** and go to **Privacy & Security**.
3. Scroll down to the Security section. You'll see *"Cablehop" was blocked to protect your Mac*.
   Click **Open Anyway**.
4. Confirm with **Open Anyway** again, and enter your Mac password or use Touch ID if asked.

After that Cablehop opens normally, including after updates to the same copy.

<details>
<summary>Prefer Terminal?</summary>

This clears the "downloaded from the internet" flag on the installed app, which has the same effect:

```bash
xattr -dr com.apple.quarantine /Applications/Cablehop.app
```

Only do this for apps you trust.

</details>

## Connect your phone

### With a cable (File transfer)

1. Connect the phone to your Mac with a USB cable and **unlock** it.
2. On the phone, pull down the notification shade and tap the **USB** notification
   (*"Charging this device via USB"*).
3. Choose **File transfer** (some phones say *Transfer files* or *MTP*).

The phone appears in Cablehop's sidebar as soon as it's plugged in. If it's locked, Cablehop shows
*Unlock your phone* and opens it as soon as you do.

**Before you unplug the cable, unmount the phone**, like ejecting a disk: click the eject button (⏏)
next to it in the sidebar or in the toolbar, choose **File › Unmount** or press **⌘E**. Cablehop stops
anything still copying (it asks first), closes the connection properly and shows *Safe to unplug*. A
reminder appears each time a phone is connected by cable. The phone stays unmounted until you unplug it
or click **Mount Again**.

> Only one app can use a phone's file-transfer connection at a time. If Cablehop says another app is
> using it, quit Android File Transfer, OpenMTP, MacDroid or Image Capture.

### Unlocking every feature (USB debugging)

1. Install Google's free platform tools once, either way:
   - **With [Homebrew](https://brew.sh):** `brew install android-platform-tools`
   - **Or from Google:** download *SDK Platform-Tools for Mac* from Google's
     [official Platform-Tools page](https://developer.android.com/tools/releases/platform-tools),
     unzip it, and move the `platform-tools` folder into `~/Library/Android/sdk/` in your home folder.
     Create the `Android` and `sdk` folders if they aren't there. That's where Cablehop looks for it.
2. On the phone, open **Settings › About phone** and tap **Build number** seven times. You'll see
   *"You are now a developer"*.
3. Go to **Settings › System › Developer options** and turn on **USB debugging**.
4. Reconnect the cable. On the phone, tick **Always allow from this computer** and tap **Allow**.

Cablehop switches to full features automatically. Greyed-out features in file-transfer mode show a
tooltip saying they need USB debugging.

### Over Wi-Fi

The phone and Mac must be on the same Wi-Fi network. Click **Connect Wirelessly…** in the sidebar
(or press ⌘K) and pick a method:

- **QR code** (Android 11+): on the phone, open *Developer options › Wireless debugging › Pair device
  with QR code* and scan the code Cablehop shows.
- **Pairing code** (Android 11+): choose *Pair device with pairing code* on the phone and type the
  address and six-digit code into Cablehop. Phones on your network are filled in for you.
- **USB → Wi-Fi** (any Android version): with the phone plugged in and USB debugging on, click
  *Switch to Wi-Fi*, then unplug. The phone forgets this when it restarts.
- **IP address**: reconnect to a phone you've paired before; recent addresses are remembered.

## Features

### Browsing

- **Finder-style list** with Name, Size, Date Modified and Kind columns. Click a header to sort;
  folders always stay on top. Columns can be resized and reordered, and Cablehop remembers them.
- **Photo grid** (⌘2) with real thumbnails for photos, and for videos in file-transfer mode. A slider
  sets the thumbnail size. Thumbnails are cached, so folders you've opened before load instantly.
- **Path bar** above the files: click any part of the path to jump back to it.
- **Sidebar locations**: Internal Storage, Camera, Screenshots, Downloads, Documents, Pictures,
  Movies, Music, WhatsApp Media and the phone's root. They're highlighted like Finder's when you're in one.
- **SD cards** show up alongside internal storage.
- **Back, Forward and Enclosing Folder** (⌘[ ⌘] ⌘↑), plus a **Go** menu with shortcuts to common folders.
- **Type to select**: start typing a name to jump to it.
- **Show hidden files** (⇧⌘.).
- **Storage gauge and battery level** for the selected phone.

### Opening and previewing

- **Double-click or press Return** to open a file in its usual Mac app.
- **Space** (or ⌘Y) for **Quick Look**.
- Files you open or preview are copied to a temporary folder and cleaned up automatically after a day.

### Copying files

- **Drag from Finder into Cablehop** to send files to the phone. Drop onto a folder (it highlights)
  to send them straight into it, or onto a sidebar location or the phone itself.
- **Drag from Cablehop into Finder** (or onto the Desktop, Mail, anywhere) to copy files to your
  Mac. They're copied straight to where you drop them.
- **Upload and Download buttons** (⌘U and ⌘D). *Download To…* (⌥⌘D) lets you choose the folder;
  the default is set in Settings.
- **Paste from Finder**: copy files in Finder (⌘C), then press ⌘V in Cablehop to upload them.
- **Whole folders** in both directions.
- **Never overwrites by surprise**: if something with the same name is already on the phone,
  Cablehop asks whether to **Replace** it or **Skip** it. Downloads that would clash get a new name
  (*Photo 2.jpg*).
- **Safe downloads**: files are written to a temporary `.cablehop-part` file and moved into place
  only when complete, so a failed or cancelled copy never damages an existing file.
- **Original dates kept** on photos and videos copied to the Mac.

### Transfers

- **Transfers button** in the toolbar: an arrow icon that turns green and pulses while copying, with a
  thin progress bar beneath it. Hover for the exact percentage.
- **Transfers list**: opens by itself when a copy starts and closes again a few seconds after
  everything finishes (it stays open if something failed). Click the button or press ⌥⌘T anytime.
  It shows each copy's progress, speed and time left, with **Cancel**, **Retry** and
  **Show in Finder**, plus a **history** that's kept between launches.
- **Up to two copies at once**, with the rest queued.
- **Keeps your Mac awake** until transfers finish, shows a count on the Dock icon, and sends a
  **notification** when a batch finishes while Cablehop is in the background.
- **Quitting mid-transfer** asks first.

### Managing files on the phone

- **New Folder** (⇧⌘N), **Rename**, and **Delete** (⌘⌫, with a confirmation).
- **Copy, Cut and Paste on the phone itself** (USB debugging): moves and copies happen on the phone,
  so nothing travels over the cable. Pasting into the same folder makes *Name copy*, like Finder.
- **Copy Path** for any item.
- **Protected folders**: Cablehop won't delete Internal Storage, DCIM, Android or system folders.

### Search

- **Filter this folder** as you type in the search field.
- **Search the entire phone** (USB debugging): choose *Entire Phone* under the search field to find
  files anywhere in internal storage, with a Location column and *Show in Enclosing Folder*.

### Sync folders (USB debugging)

Keep a phone folder and a Mac folder up to date, for example backing up your camera roll:

- Choose **Phone → Mac** or **Mac → Phone**, the two folders, and click **Sync Now**.
- Only new or changed files are copied. **Nothing is ever deleted** on either side.
- Save syncs to rerun with one click later. Each shows when it last ran.

### Extras (USB debugging)

- **Phone screenshot** (⇧⌘S): saved to your Downloads folder and opened in Quick Look.
- **Install apps**: choose *Install App (APK)…* from the toolbar's More menu, or drop `.apk` files
  onto the phone in the sidebar.

### Updates

- **Check for Updates…** in the Cablehop menu, or **Settings › Updates › Check Now**.
- Cablehop also checks quietly once a day (you can turn this off) and only speaks up when there's a new
  version. You see what's new, then choose **Install Update**, **Remind Me Later** or **Skip This Version**.
- **Install Update** downloads the new version, checks it (see [Privacy and security](#privacy-and-security)),
  replaces the app and restarts it. If Cablehop is running from somewhere it can't update itself, like the
  disk image, it saves the new version to Downloads and opens it so you can drag it to Applications.

### Logs and getting help

- Cablehop keeps a **log** of what it does (phones connecting, transfers, errors) to help fix problems.
  It's stored **only on your Mac**, in `~/Library/Logs/Cablehop`, readable only by your account, and
  capped at about 10 MB. Your Mac username is never written to it.
- **View Logs** (Help menu, ⌥⌘L, or Settings › Help) opens a searchable log window, with a filter for
  just warnings and errors.
- **Save Logs…** saves the complete log as a text file, with your Cablehop, macOS and Mac model at the
  top, ready to attach to a bug report.
- **Report a Problem…** (Help menu or Settings › Help) walks you through it: first save your logs, then
  open [GitHub Issues](https://github.com/negasonicteenagewarperson/Cablehop/issues/new/choose), choose
  *Bug report*, describe what happened and drag in the log file.

### Settings (⌘,)

- **General**: where downloads are saved, notifications on or off, and which `adb` Cablehop uses.
- **Updates**: automatic checks on or off, the current version, when it last checked, and **Check Now**.
- **Storage**: how much space thumbnails, previews and logs use, with a **Clear** button.
- **Help**: View Logs, Save Logs, Report a Problem, and a link to this page.

### Which features need what

| Feature | File transfer | USB debugging |
|---|:---:|:---:|
| Browse folders, list and photo grid | ✓ | ✓ |
| Copy both ways (drag and drop, buttons, paste from Finder) | ✓ | ✓ |
| New folder, rename, delete, Quick Look, open | ✓ | ✓ |
| Thumbnails | Photos and videos | Photos |
| Storage and battery | ✓ | ✓ |
| Unmount before unplugging | ✓ | ✓ |
| Search the whole phone | | ✓ |
| Sync folders | | ✓ |
| Copy/cut/paste on the phone | | ✓ |
| Screenshots, APK installs | | ✓ |
| Wi-Fi connection | | ✓ |

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Upload / Download / Download To… | ⌘U / ⌘D / ⌥⌘D |
| New folder | ⇧⌘N |
| Quick Look | Space or ⌘Y |
| Open | Return, ⌘↓ or double-click |
| Delete | ⌘⌫ |
| Copy / Cut / Paste | ⌘C / ⌘X / ⌘V |
| Back / Forward / Enclosing folder | ⌘[ / ⌘] / ⌘↑ |
| List / Grid | ⌘1 / ⌘2 |
| Show hidden files | ⇧⌘. |
| Refresh | ⌘R |
| Internal Storage / Downloads / Documents / Camera | ⇧⌘I / ⇧⌘L / ⇧⌘O / ⇧⌘C |
| Transfers | ⌥⌘T |
| Phone screenshot | ⇧⌘S |
| Connect wirelessly | ⌘K |
| Unmount the phone (before unplugging) | ⌘E |
| View logs | ⌥⌘L |
| Settings | ⌘, |

## Privacy and security

- **Nothing about you leaves your Mac.** Cablehop talks to your phone over USB or your local Wi-Fi. The
  only internet connection it makes is to ask GitHub whether a new version exists (once a day, which
  you can turn off in Settings › Updates) and to download it if you choose to. No accounts, no analytics.
- **Updates are verified before they're installed.** Each release's checksum list is signed with
  Cablehop's private release key, which never leaves the developer's Mac. Cablehop installs an update
  only if that signature is valid, the download matches its checksum, and the app inside is Cablehop at
  the advertised version with an intact code signature. So even someone who took over the GitHub
  account couldn't push a fake update. Downloads come only from this project's GitHub releases, over HTTPS.
- **Logs stay local and private.** See [Logs and getting help](#logs-and-getting-help). Serial numbers
  are shortened and Wi-Fi pairing codes are never written down.
- **Downloaded files are checked by macOS.** Everything copied from the phone is marked as downloaded,
  so Gatekeeper checks any apps or scripts among them before they can run, just as it does for Safari
  and AirDrop downloads.
- **Hostile filenames can't do damage.** Names from the phone can't break out of the folder you copy
  to, and commands sent to the phone are quoted so a filename can never run as a command. Both are
  covered by automated tests.
- **Leaves other devices alone.** Cablehop never takes over iPhones, iPads, cameras, or a phone's
  USB-debugging connection when opening its file-transfer connection.
- **Hardened app.** Built with macOS's hardened runtime, and it uses no third-party code.

## Troubleshooting

- **The phone doesn't show up.** Unlock it and make sure the USB notification says *File transfer*,
  not *Charging only*. Try another cable or USB port, ideally directly on the Mac rather than through a hub.
- **"Unlock your phone."** Android hides files while the phone is locked. Unlock it and Cablehop
  continues by itself.
- **"Another app is using it."** Quit Android File Transfer, OpenMTP, MacDroid or Image Capture, then
  click **Try Again**.
- **"The phone isn't responding."** Cablehop resets the USB connection automatically. If it still
  doesn't answer, unplug the phone, plug it back in and unlock it.
- **Features are greyed out.** They need USB debugging; see
  [Unlocking every feature](#unlocking-every-feature-usb-debugging).
- **"Allow access on your phone."** With USB debugging on, the phone shows an *Allow USB debugging?*
  prompt. Tick *Always allow* and tap **Allow**.
- **"Too old for USB debugging."** The phone runs Android 5 or earlier. Turn off USB debugging and use
  File transfer, which works on every version.
- **Wi-Fi pairing can't find the phone.** Both devices must be on the same network, and some guest or
  office networks block devices from seeing each other.
- **Something else?** Use **Help › Report a Problem…**: save your logs, then open an issue on GitHub
  with the log file attached.

## FAQ

**Is it free?** Yes, and open source under the MIT license.

**Does it work with iPhone?** No. Macs handle iPhones themselves through Finder and Photos.

**Why doesn't the phone appear in Finder's sidebar?** That needs a special kind of Mac extension, which
Cablehop doesn't have yet. For now you browse the phone in Cablehop and drag files to and from Finder.

**Do I need USB debugging?** No. File transfer covers browsing and copying. USB debugging adds the
extras listed above.

**Can I edit a file directly on the phone?** Files you open are copies on your Mac. Save them and drag
them back to replace the phone's version.

## Building from source

Requires Xcode or the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/negasonicteenagewarperson/Cablehop.git
cd Cablehop
./Scripts/test.sh        # run the unit tests
./Scripts/build-app.sh   # build build/Cablehop.app
./Scripts/make-dmg.sh    # package it as dist/Cablehop-<version>.dmg
./Scripts/release.sh     # all of the above, plus a .zip and a signed SHA256SUMS.txt
```

**Release signing.** The in-app updater only installs releases whose `SHA256SUMS.txt` is signed with the
project's Ed25519 release key. `release.sh` signs it automatically using `~/.cablehop-release-key`; create
one with `swift Scripts/sign-release.swift --generate` and put its public key in `Updater.swift`. Keep the
private key backed up and out of the repository (it's in `.gitignore`).

Run `make-dmg.sh` from Terminal so it can arrange the DMG window; macOS asks once for permission to
control Finder. If that's declined, the DMG still works with Finder's default layout.

**Signing and notarizing (optional).** With an Apple Developer ID, set these before `release.sh` and the
DMG opens on any Mac with no Gatekeeper warning:

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE=cablehop   # saved once with: xcrun notarytool store-credentials cablehop
```

The version number lives in [`VERSION`](VERSION). Minor updates go 1.1, 1.2, …; major releases go to
2.0 and up. See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

## License

[MIT](LICENSE) © 2026 AK
