# TextS

<p align="center">
  <img src="Resources/AppIcon.png" alt="TextS app icon" width="144">
</p>

TextS is a macOS menu bar app that captures a screen region, recognizes its text, and copies the result to your clipboard. It also includes a command-line tool for images.

## Features

- Start a screen capture with `⌘⇧2` or choose **Capture Text** from the menu bar.
- Change the global shortcut and enable **Launch at Login** in **Settings…**.
- Turn on **Faster recognition** in **Settings…** for quicker results with slightly less accurate text. The quick recognizer covers Latin text only; Chinese, Japanese and Korean need the accurate recognizer.
- See an on-screen confirmation and hear the macOS Glass sound when text is copied.
- Recognize text with automatic language detection and language correction.
- Load the recognizer in the background at launch, so the first capture does not wait for it.
- Keep working when the macOS recognizer fails or is slow, by falling back to the quicker recognizer.
- Update from the menu bar when a newer release is published.
- Run OCR on an image from the command line.

TextS uses the OCR models built into macOS and does not bundle separate language models. On macOS 27.0.1, the default accurate recognizer reports 33 supported language and locale identifiers. These include Thai (`th-TH`), English (`en-US`), simplified Chinese (`zh-Hans`), traditional Chinese (`zh-Hant`), Cantonese (`yue-Hans`), and Japanese (`ja-JP`).

The list can change with macOS updates. It includes script and regional variants, and language support does not guarantee accurate recognition for every image. A selection that mixes two scripts, such as a Chinese menu next to English words, is read line by line, and a line that is mostly Latin can lose its Chinese half.

Some Macs load the accurate recognizer slowly, or stop it from working after the first request. TextS then reads the selection with the quicker recognizer and says so, so a capture still returns text. Turn **Faster recognition** in **Settings…** off and on again to bring the accurate recognizer back.

**Faster recognition** asks the quicker recognizer, which has a model for English, French, German, Italian, Spanish and Portuguese. It reads some other scripts well and turns others into Latin nonsense, so leave the setting off if you read Thai, Chinese, Korean, Russian or Arabic. TextS falls back to the accurate recognizer when the quicker one finds nothing at all, which is why a selection in those languages can still come back correct.

## Requirements

- macOS 13 or later
- Rust and Cargo
- Xcode Command Line Tools, which provide `swiftc`

## Build and install

For the published app, download the macOS disk image from the [latest release](https://github.com/titipakorn-th/TextS/releases/latest). Open the DMG, drag `TextS.app` to Applications, then eject the mounted image.

The release supports Apple silicon and macOS 13 or later. It is ad-hoc signed and not notarized, so macOS may ask you to approve it before the first launch.

Installed versions check GitHub for a newer release and offer to install it from the menu bar. The first launch of a downloaded update may ask you to approve the app again.

To build from source, run:

```sh
./build-app.sh
```

The script builds the Rust OCR helper in release mode, compiles the macOS app, and creates `build/TextS.app` with an ad-hoc signature for local use.

The version lives in `version.txt` and nowhere else. The build writes it into the app bundle and the Cargo manifest, so a new release only needs that one file changed.

Copy the app to Applications:

```sh
ditto build/TextS.app /Applications/TextS.app
```

Open TextS from Applications. The app runs from the menu bar and does not add a Dock icon.

## Capture text

Choose **Capture Text** from the TextS menu bar menu or press `⌘⇧2`. Drag to select text on screen. TextS copies recognized text to the clipboard and shows a brief confirmation near the bottom center of the screen.

To change the shortcut, open the menu bar menu, choose **Settings…**, then click the shortcut button. Turn on **Launch at Login** in Settings to start TextS when you sign in.

## Use the command-line tool

To select a screen region and copy the recognized text:

```sh
cargo run --release
```

To recognize an image file, print the result to standard output, and copy it to the clipboard:

```sh
cargo run --release -- ./screenshot.png
```

Pass one image path. TextS reports an error if the image has no recognized text or cannot be read.

## Screen recording permission

On the first screen capture, allow access when macOS prompts. If capture fails, open **System Settings → Privacy & Security → Screen & System Audio Recording** and allow the app that started the capture. For command-line use, allow your terminal app.
