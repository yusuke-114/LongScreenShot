<p>
  <img src="docs/assets/app-icon.png" alt="Long Screenshot icon" width="96">
</p>

# Long Screenshot

Scrolling screenshots for macOS.

Set a global shortcut, select a scrollable area in any app, then scroll downward to create one seamless image.

## Features

- **Capture beyond the viewport** — select an area, scroll down slowly, and the frames are stitched into a single PNG.
- **Live preview** while you scroll.
- **Global keyboard shortcut** to start a capture from anywhere.
- **Clothesline** — finished long screenshots hang on a clothesline where you can copy, mark up, show in Finder, or move them to the Trash.
- Available in English, 简体中文, 日本語, and 한국어.

## Requirements

- macOS 26.0+
- Screen Recording permission (macOS asks the first time you capture)

## Install

```bash
brew install --cask yusuke-114/tap/longscreenshot   # install
brew upgrade --cask longscreenshot                  # upgrade
brew uninstall --cask longscreenshot                # uninstall (don't drag it to the Trash)
```

Or download the ZIP from [Releases](../../releases).

### Troubleshooting

<details>
<summary>Already installed from the Mac App Store</summary>

Homebrew stops with `It seems there is already an App at '/Applications/LongScreenshot.app'`. Remove the other copy first, or let Homebrew replace it:

```bash
brew install --cask --force yusuke-114/tap/longscreenshot
```

</details>

<details>
<summary>Removed by dragging to the Trash</summary>

Homebrew stops with `App source '/Applications/LongScreenshot.app' is not there`, because it still thinks the app is installed. Reinstall it:

```bash
brew uninstall --cask --force longscreenshot
brew install --cask yusuke-114/tap/longscreenshot
```

</details>

## Quick Start

1. Open Long Screenshot and choose a save folder.
2. Record a keyboard shortcut.
3. Press the shortcut, select the area to capture, and press **Start**.
4. Scroll down slowly, keeping each new frame overlapping the previous one, then press **Done**.

## Links

- [Privacy Policy](https://yusuke-114.github.io/LongScreenShot/)
- [License](LICENSE)

The clothesline is adapted from [Tendedero](https://github.com/alejandrobujan/tendedero) by Alejandro Buján, used under the MIT License.
