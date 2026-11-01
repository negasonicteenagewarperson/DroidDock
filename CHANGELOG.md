# Changelog

## 2.5

### Fixed
- **Phones show up much faster.** Cablehop now hears about a phone the moment it's plugged in, or the
  moment you choose File transfer on it, instead of waiting for its next check (up to 6 seconds when
  Cablehop was in the background).
- **File transfer phones no longer wait for adb.** Each check used to ask Google's adb tool first and
  only then look at USB; when adb was starting up or slow, that held everything up by seconds, including
  right after launch. USB phones now appear straight away while adb is asked alongside.

### Changed
- **The log records how long each connection took**, from the phone appearing on USB to its files being
  ready, so a slow phone is easy to diagnose from a saved log.

## 2.4

### Fixed
- **Dropping files onto a folder asks before replacing.** Dropping onto the window already asked when
  a file with the same name was on the phone, but dropping onto a folder in the list replaced same-named
  files inside it without asking. It now checks that folder first.
- **Downloads never overwrite a file on your Mac.** If something takes a download's name before it
  finishes (for example when you retry a failed download), the copy is saved as "Name 2" instead.
- **No leftover half-finished files.** Quitting during a download no longer leaves a `.cablehop-part`
  file behind in the download folder.
- **Screenshots from a Wi-Fi phone** with no model name get a normal file name instead of one with
  colons in it.

### Changed
- **Ready for future macOS updates.** Check for Updates now opens the downloaded installer with
  `diskutil`, which newer macOS uses in place of the deprecated `hdiutil attach`. Older macOS
  versions keep using `hdiutil`.

## 2.2

### Changed
- **Bigger logo and name** in the window's title area, so Cablehop is easy to recognise at a glance.
- **Clearer update log.** The log now records every choice in the update window (Install, Remind Me
  Later, Skip) and every reason an update can't start, so update problems are easy to diagnose.

## 2.1

### Changed
- **Logo and name together.** The window's title area now shows the Cablehop logo with the name beside it.
- **Cleaner Liquid Glass.** The logo no longer sits inside a round glass button: macOS 26 gives every
  toolbar item one by default, which isn't how app titles look. Glass is now used only where Apple uses it,
  on controls floating above content (toolbar, sidebar, path bar, photo-size slider). Content panels (the
  welcome cards, notices, release notes, Report a Problem steps) use the standard grouped style, and there's
  no more glass layered on glass in the sidebar.

## 2.0

### New
- **Liquid Glass design.** On macOS 26 Tahoe and later, Cablehop uses Apple's new look: glass toolbar and
  sidebar, a floating glass path bar, glass panels and buttons. (Earlier builds were marked as built with
  an older SDK, so macOS kept them in the old style.) macOS 14 and 15 get the closest matching materials.
- **The Cablehop logo** replaces the app name in the window's title area and leads the welcome screen.
- **Check for Updates.** From the Cablehop menu or Settings › Updates, plus a quiet daily check you can turn
  off. Updates install themselves and restart the app, after verifying the release's signature, checksum,
  version and code signature.
- **Logs.** Cablehop now keeps a private log on your Mac (`~/Library/Logs/Cablehop`). View it, search it,
  and save the complete log as a text file from Settings › Help or the Help menu.
- **Report a Problem.** Walks you through saving your logs, then opens GitHub Issues with a bug report form.
- **New Settings window** with General, Updates, Storage and Help tabs.

### Security
- Releases are now signed with a private release key; the updater refuses anything else.
- Logs are readable only by your account, never contain your Mac username, shorten serial numbers and
  omit Wi-Fi pairing codes. Repeated lines are collapsed so a recurring error can't flood them.

## 1.4

### Changed
- **New name: Cablehop** (formerly DroidDock). The app, its installer, and the GitHub project are all
  renamed. Your settings, saved folder syncs, transfer history and caches move over automatically the
  first time you open Cablehop, and the old copies are removed.
- If you had the previous version in Applications, drag Cablehop in and delete the old app.

## 1.3

### Changed
- **Transfers button, Safari style.** An icon with a thin progress bar beneath it; while copying,
  the icon turns green and pulses (steady with Reduce Motion). The percentage is in the tooltip.

### Fixed
- **The transfers list opens reliably.** It's now a native popover, and the button keeps a fixed
  size, so the toolbar no longer rebuilds it mid-transfer (which closed the list as it opened). A
  click on the button while the list is open closes it instead of reopening it. When the window is
  too narrow to show the button, the list opens from the window's corner.
- Progress updates are throttled, so fast copies no longer redraw the window hundreds of times a second.

### Compatibility
- Folders can't show up empty on phones that implement MTP's bulk listing wrongly (seen on several
  Android versions and makers): items are always listed one way, and details filled in the fast way.
- Samsung, Xiaomi and other phones that label MTP as a vendor-specific interface are detected.
- Phones without a USB serial number (common on budget phones) stay connected instead of
  reconnecting on every check.
- iPhones, iPads, digital cameras and the phone's own USB-debugging interface are never taken over.
- The file-transfer session opens the way the MTP spec and libmtp do, with more time for slow phones.
- Android 5 and earlier over USB debugging get a clear message to use File transfer instead.
- Names longer than the phone allows are refused instead of silently cut short.
- Faster listing of folders with thousands of items.

## 1.2

### Fixed
- **Uploads over about 1 MB no longer get stuck at 0%.** In File transfer mode, Cablehop split uploads into
  USB transfers in a way Android read as "file finished" after the first megabyte, so it stopped reading
  and the connection wedged. Every transfer except the last is now a whole number of USB packets.
- Uploads can no longer be interrupted by thumbnails, folder refreshes or a second upload landing
  between the two steps of a file-transfer upload.
- With USB debugging, progress now moves for apps opened from Finder (adb only reported progress when
  started from Terminal).
- Folder uploads show progress from the start instead of sitting at 0% until done.
- A phone left stuck by an interrupted copy is reset over USB automatically and reconnected, with no
  replugging. If it still doesn't answer (usually because it's locked), Cablehop says so.
- Waits longer for the phone to finish saving a large file before treating it as unresponsive.

### Changed
- The transfers button turns into a green pill showing overall progress, glowing on and off while
  anything is copying. Reduce Motion keeps it steady.
- The transfers list opens by itself when a copy starts, and closes itself a few seconds after
  everything finishes (it stays open if something failed).

## 1.1

### New
- **Works without USB debugging.** Phones in plain *File transfer* (MTP) mode are detected automatically:
  browse, copy both ways, new folder, rename, delete, Quick Look, and photo and video thumbnails.
  Features that need USB debugging are greyed out with a note explaining how to turn them on.
- **Transfers button.** A small toolbar button with a progress ring replaces the side panel. Click it
  for progress, speed, time left and a history that's kept between launches.
- Tooltips on every toolbar button, including their keyboard shortcuts.
- Version shown in Settings and the About window.
- Universal app (Apple silicon and Intel).

### Fixed
- Dragging files from the phone into Finder now works. Files are copied straight to where you drop
  them, and the copy shows up in Transfers.
- Dropping files from Finder onto the phone works first time, anywhere in the list, and dropping onto
  a folder sends files into that folder.
- A phone whose file-transfer connection was left stuck by an interrupted session is reset
  automatically instead of failing to open. Mid-session USB hiccups are retried once.
- Copy, Cut and Paste in the Edit menu work in the list view.

## 1.0

First release: browse and transfer files over USB debugging or Wi-Fi, photo grid, folder sync,
whole-phone search, copy/paste on the phone, screenshots, APK installs, and wireless pairing by QR code.
