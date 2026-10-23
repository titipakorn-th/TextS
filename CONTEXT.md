# Project context

## Product

TextS is a native macOS menu bar app for selecting text on screen, recognizing it, and copying it to the clipboard. The app has no Dock icon. The repository is public at [titipakorn-th/TextS](https://github.com/titipakorn-th/TextS).

## Architecture

- `src/App.swift` is the AppKit app. It owns the menu bar item, global keyboard shortcut, settings window, Launch at Login setting, screen selection flow, and on-screen feedback.
- `src/main.rs` is the Rust OCR and command-line program. It uses macOS frameworks for image recognition and clipboard access. The app launches this binary for OCR.
- `build-app.sh` builds both parts and bundles them into `build/TextS.app`.
- `Info.plist` defines the app name, macOS 13 minimum, version, and bundle identifier.
- `Resources/AppIcon.icns` is the bundled icon. `Resources/AppIcon.png` is used in the README.

The release bundle currently uses `com.prince.textsniper` as its bundle identifier, and Cargo names the helper package and binary `textsniper-rs`. Treat these as installed app and command identifiers. Changing them can affect updates, saved preferences, or scripts.

## Product behavior and preferences

- The default capture shortcut is `⌘⇧2`. Users can change it in Settings. The shortcut is stored in UserDefaults.
- Screen selection uses `/usr/sbin/screencapture`. OCR detects language automatically and enables language correction.
- Successful recognition copies text to the clipboard, plays the macOS Glass sound, and shows a bottom-center confirmation on the display with the pointer. The success message stays visible for about 1.25 seconds, then fades over 0.16 seconds.
- There is no copied-text status in the menu bar. Keep the menu bar item for app access and controls.
- The language list depends on macOS. The README records 33 supported language and locale identifiers on macOS 27.0.1. That count includes regional and script variants and is not an accuracy guarantee.
- User documentation should use the TextS brand. Do not mention the OCR framework by name in `README.md`.

## Build and install

Requirements are macOS, Rust and Cargo, and Xcode Command Line Tools for `swiftc`.

```sh
./build-app.sh
```

The script targets the current machine architecture and creates an ad-hoc signed app at `build/TextS.app`. Copy it to Applications for local use. The script does not create a DMG.

The public [0.1.0 release](https://github.com/titipakorn-th/TextS/releases/tag/v0.1.0) has an Apple silicon DMG and ZIP. The DMG opens to a drag-to-Applications layout. The release requires macOS 13 or later. It is ad-hoc signed and not notarized, so Gatekeeper may require user approval on first launch.

The command-line tool can capture a region or OCR one image:

```sh
cargo run --release
cargo run --release -- ./screenshot.png
```

## Current project state

- `main` is synced with `origin/main` at the v0.1.7 release.
- Release `v0.1.7` is published and is the latest published one. It includes `TextS-0.1.7-macos-arm64.dmg`, `TextS-0.1.7-macos-arm64.zip`, and `SHA256SUMS.txt`. `package-release.sh` builds those three files from `build/TextS.app`.
- The working tree is version 0.1.7, built and installed to `/Applications/TextS.app`.
- The version lives in `version.txt` and nowhere else. `build-app.sh` writes it into `Cargo.toml` and `Info.plist`, and `package-release.sh` names the release assets from it, so a new version only needs that one file changed.
- There is no CI workflow yet, and the only check is `test.sh`. A macOS CI workflow has been discussed but not added.
- The previous packaging task left `.audit/dmg-release.todo.md` untracked in the worktree. Inspect it before removing it.

## Working notes for future changes

- The quick recognizer lists only six Latin languages. A quick request over a Chinese selection comes back as Latin nonsense, because nothing in the request tells Vision which script the selection holds, and the automatic detection sometimes finds a model for other scripts anyway. The quick path is not trustworthy outside Latin text. The helper asks for the languages the level supports, with the CJK models first, and falls back to the accurate recognizer when the quick one finds nothing.
- Vision reads a selection line by line and picks the model that fits each line, so a line that is mostly Latin keeps its Chinese half only partly. There is no public API for the detected language, so the helper cannot ask what a selection holds.
- The capture path budgets each recognizer. The accurate one gets 90 seconds, the quick one 45. The budget is generous on purpose: the first read of a script compiles its model, and a cold read of Chinese, Turkish or Vietnamese was measured at 15 to 30 seconds, so the old 5 second budget timed out every cold accurate capture. A helper that does not answer in time is retired, and the same image is read again by a fresh helper in the same mode. `test.sh` drives the real app code against a stub helper and checks that a helper which never answers is given up on inside the budget.
- The mode a capture uses is the mode the user picked. There is no automatic switch to the quick recognizer, so the settings never claim the accurate recognizer is broken when it is not.
- The recognition models are cached by the system and shared by every process. A cold read of a script that was never read before costs 15 to 30 seconds; the same read in a new process right afterwards costs 0.2 seconds. The app loads the models in the background at launch, in a throwaway process, which is what keeps that cost off the first capture. It runs on a synthetic picture with one line per script, so the scripts it warms are the ones it names.
- Every language in a request's language list needs its own correction model, and macOS builds one for each of them on the first read. That is the whole cost of a cold read: asking for all thirty-three languages took 46 seconds to build, and the cost grows by about a second per language. The helper therefore asks for seven, the Chinese, Japanese and Korean models first and English after them, which reads every script the same as the full list did and leaves the build to the launch warmup. Do not put the full list back without measuring it again.
- The list is what wins a line that mixes two scripts. With no list, a mostly Latin line loses its Chinese half; with the CJK models first, it keeps it. Everything else is picked by the automatic detection, so the other languages do not need to be named.
- Vision's image reader breaks intermittently with `TextRecognition.CRImageReaderError`, and the failure is sticky: every later request in that process fails the same way, while a new process reads the same picture without trouble. It shows up after a model is compiled, not after every read, so it cannot be reproduced on demand. The app's answer is the fresh-helper retry, which is why a helper that fails once is replaced rather than reused. Do not spend time hunting this one again; it is not reproducible from the outside.
- The accurate recognizer used to stop answering when several processes used it at once. That did not reproduce: a capture through one helper answers in under a tenth of a second while a warmup compiles a model in another process. The Rust tests no longer read images, so `cargo test` stays free of the recognizer; the real reads live in `tests/main.swift` and run one after another.
- Prefix shell commands with `rtk` per the workspace instructions. Use `rtk proxy` when a command needs raw output or options that `rtk` does not support.
- Keep the app native and menu-bar based. Preserve the bottom-center HUD and Glass success sound unless the user asks for a change.
- Keep build, install, language support, and release claims in `README.md` aligned with the actual app and release assets.
- Releases are packaged by `package-release.sh`, which builds the app, the disk image, the zip, and the checksums. A macOS CI workflow is still missing.
- Check `git status` before editing. Do not discard existing user or untracked files.
