# TextS

<p align="center">
  <img src="Resources/AppIcon.png" alt="TextS app icon" width="144">
</p>

TextS is a macOS menu bar app that captures a screen region, recognizes its text, and copies the result to your clipboard. It also includes a command-line tool for images.

## Features

- Start a screen capture with `⌘⇧2` or choose **Capture Text** from the menu bar.
- Change the global shortcut and enable **Launch at Login** in **Settings…**.
- See an on-screen confirmation and hear the macOS Glass sound when text is copied.
- Recognize text with Apple Vision's automatic language detection and language correction.
- Run OCR on an image from the command line.

Vision supplies OCR models through macOS. TextS does not bundle separate language models. Language availability and recognition quality depend on macOS and the source image.

## Requirements

- macOS 13 or later
- Rust and Cargo
- Xcode Command Line Tools, which provide `swiftc`

## Build and install

From the project directory, run:

```sh
./build-app.sh
```

The script builds the Rust OCR helper in release mode, compiles the macOS app, and creates `build/TextS.app` with an ad-hoc signature for local use.

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
