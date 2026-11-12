# HiDPI

A macOS menu bar app that gives a MacBook's built-in display sharp scaled resolutions above the ones macOS offers.

## The problem

On a 14-inch MacBook Pro (3024 × 1964 panel), the largest sharp resolution in System Settings is 1800 × 1169. Every larger entry in the list (1920 × 1200, 2048 × 1280 and so on) is a 1x mode: macOS draws that many pixels and stretches them over the panel, so text looks blurry.

HiDPI adds 2x versions of those sizes. macOS renders at twice the chosen size and scales the result down to the panel, which is what the built-in scaled modes do.

## Requirements

- A Mac with a built-in display.
- Xcode Command Line Tools (`xcode-select --install`), for `clang`, `iconutil` and `codesign`.

Tested on one machine only: MacBook Pro 14-inch (M4 Pro), macOS 27.2. Other models and macOS versions are untested.

## Install

```sh
git clone https://github.com/gusiqbal/hidpi.git
cd hidpi
./build.sh
```

`build.sh` stops a running copy, builds `HiDPI.app`, runs a self-check, installs the app to `~/Applications` and opens it. A display icon appears in the menu bar.

## Use

Click the display icon in the menu bar.

| Menu item | What it does |
|---|---|
| Normal | Back to the resolution set in System Settings |
| 1920 × 1200, 2048 × 1280, 2294 × 1433, 2560 × 1600 | Switch to that size, rendered at 2x |
| Custom… | Any width from 1024 to 3840. It is saved as its own menu entry |
| Full height (uses the notch strip) | Sizes use the panel's full height (for example 2048 × 1330) instead of 16:10 |
| Toggle on/off | Switch between Normal and the last size. Also on Control+Option+Command+H |
| Start at login | Open HiDPI automatically when you log in |
| Quit HiDPI | Back to Normal and close the app |

The active width is shown next to the icon. The last choice is remembered and applied again when the app starts.

## Command line

The app binary also works from a terminal:

```sh
HIDPI=~/Applications/HiDPI.app/Contents/MacOS/HiDPI

$HIDPI 2048              # hold 2048 × 1280 until Ctrl-C
$HIDPI 2048 1330         # explicit height
$HIDPI --probe 2048      # self-check: create the virtual display, do not switch
$HIDPI --login status    # or: on, off
```

Width is 1024 to 3840 and height is 640 to 2600.

## How it works

- A virtual display with a 2x backing store is created through the private `CGVirtualDisplay` API, with the panel's refresh rate and Display P3 primaries.
- The built-in display is set to mirror the virtual one, so macOS renders at 2x and scales down to the panel.
- Each resolution runs in its own helper process (the same binary with `--child`). Stopping the helper removes the virtual display and the screen reverts. The helper exits by itself if the app dies.
- After wake or any display change the app checks the screen and restores the resolution if it was lost. It gives up after three restarts in quick succession.

Everything is in one file, `hidpi.m`.

## Limits

- **Sharpness:** the panel has a fixed number of pixels. Sizes above the native 2x size are scaled down, so they are sharper than the 1x modes but softer than the default resolution. The larger the size, the softer it gets.
- **Private API:** `CGVirtualDisplay` is undocumented and may change in a macOS update. Run `--probe` to check, and rebuild after updating.
- **Full height:** the virtual display does not know about the notch, so menu bar items may sit behind it.
- **Untested:** HDR content, external monitors, and sleep by closing the lid (display sleep is tested).
- **Shortcut:** Control+Option+Command+H is fixed.

## Troubleshooting

- **Stuck at a resolution:** run `pkill -x HiDPI`. The screen reverts when the processes exit.
- **"The virtual display did not come up":** the private API probably changed. Rebuild with `./build.sh` and run `--probe`.
- **"No built-in display found":** the lid is closed or the display is off.

## Uninstall

1. Untick **Start at login** in the menu, then choose **Quit HiDPI**.
2. Delete `~/Applications/HiDPI.app`.
3. Remove the saved settings: `defaults delete local.hidpi`.
