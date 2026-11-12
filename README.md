# HiDPI

A macOS menu bar app that gives a MacBook's built-in display sharp scaled resolutions above the ones macOS offers.

## The problem

On a 14-inch MacBook Pro (3024 × 1964 panel), the largest sharp resolution in System Settings is 1800 × 1169. Every larger entry in the list (1920 × 1200, 2048 × 1280 and so on) is a 1x mode: macOS draws that many pixels and stretches them over the panel, so text looks blurry.

HiDPI adds 2x versions of larger sizes. macOS renders at twice the chosen size and scales the result down to the panel, which is what the built-in scaled modes do.

It does this in one of two ways, chosen per size:

| | Native | Mirrored |
|---|---|---|
| How | The display's own 2x mode | A virtual 2x display that the built-in screen mirrors |
| Height | Full panel, including the strip beside the notch | 16:10, below the notch |
| Needs | The override file installed once (see below) | Nothing |
| Extra process | None | One helper while the size is active |

Without the override file every size is mirrored. With it, the four menu sizes are native and only custom widths are mirrored.

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

## Full height: install the override file (optional)

macOS builds the built-in display's list of scaled sizes from a display override file, and Apple's file for the panel stops at 1800 × 1169. A file in `/Library/Displays` with more entries adds the menu sizes as real modes of the display.

This changes system display configuration. It needs an administrator password and a restart, because macOS reads these files only at startup.

1. Generate the file for this Mac's panel. It starts from Apple's own file and only adds sizes:

   ```sh
   ~/Applications/HiDPI.app/Contents/MacOS/HiDPI --override ~/hidpi-override
   ```

2. Run the two `sudo` commands it prints, then restart.
3. Check:

   ```sh
   ~/Applications/HiDPI.app/Contents/MacOS/HiDPI --sizes
   ```

   Each menu size should say `native`. If it says `mirrored`, macOS ignored the file: remove it with the undo command that step 1 printed.

To undo, run the printed `sudo rm` command and restart. If the screen were ever unusable after the restart, delete that file from Safe Mode or from Terminal in Recovery.

## Use

Click the display icon in the menu bar.

| Menu item | What it does |
|---|---|
| Normal | Back to the resolution set in System Settings |
| 1920, 2048, 2294 and 2560 wide | Switch to that size at 2x. The menu shows the height: full height when native, 16:10 when mirrored |
| Custom… | Any width from 1024 to 3840, saved as its own menu entry. Mirrored unless the display has that width as a native mode |
| Toggle on/off | Switch between Normal and the last size. Also on Control+Option+Command+H |
| Start at login | Open HiDPI automatically when you log in |
| Quit HiDPI | Back to Normal and close the app |

The active width is shown next to the icon. The last choice is remembered and applied again when the app starts.

## Command line

The app binary also works from a terminal:

```sh
HIDPI=~/Applications/HiDPI.app/Contents/MacOS/HiDPI

$HIDPI --sizes           # which menu sizes are native, which would be mirrored
$HIDPI --override DIR    # write the override file into DIR and print how to install it
$HIDPI 2048              # mirror at 2048 × 1280 until Ctrl-C
$HIDPI --probe 2048      # self-check for mirroring: create the virtual display, do not switch
$HIDPI --login status    # or: on, off
```

Width is 1024 to 3840.

## How it works

- **Native sizes:** the app switches the built-in display to its own 2x mode. The change belongs to the app, so macOS reverts it when the app quits or dies.
- **Mirrored sizes:** a virtual display with a 2x backing store is created through the private `CGVirtualDisplay` API, with the panel's refresh rate and Display P3 primaries, and the built-in display mirrors it. Each mirrored size runs in its own helper process (the same binary with `--child`), which exits by itself if the app dies.
- After wake or any display change the app checks the screen and restores the size if it was lost. It gives up after three attempts in quick succession.

Everything is in one file, `hidpi.m`.

## Limits

- **Sharpness:** the panel has a fixed number of pixels. Sizes above the native 2x size are scaled down, so they are sharper than the 1x modes but softer than the default resolution. The larger the size, the softer it gets.
- **Notch strip:** only native sizes use it. A virtual display has no notch, and macOS shows a mirrored picture in the 16:10 area below it.
- **Custom widths:** mirrored, unless you add them to the override file yourself.
- **Private API:** mirroring uses `CGVirtualDisplay`, which is undocumented and may change in a macOS update. Run `--probe` to check, and rebuild after updating. Native sizes do not use it.
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
4. If you installed the override file, remove it with the `sudo rm` command that `--override` printed, and restart.

## Credits

The override file format follows Apple's own display override files and the [display-scale](https://github.com/utsavsingh899/display-scale) project, which uses the same method.
