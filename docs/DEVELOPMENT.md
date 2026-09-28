# Development

## Project layout

- `Sources/AtelierClockView.m`: shared renderer, materials, daily selection, preferences, and options sheet.
- `Sources/AtelierClockView.h`: public view interface.
- `Sources/main.m`: desktop window, menu, and animation timer.
- `Resources/`: bundle metadata, the shared app/bundle icon, and Screen Saver picker thumbnails.
- `Tests/`: native daily-selection, preference, and options-lifecycle checks.
- `Examples/BrowserPreview/`: an older standalone browser prototype and reference images.
- `docs/previews/`: current native dial images used by the README.
- `Tools/`: documentation preview renderer and its launcher.
- `build.sh`: universal build, metadata injection, local signing, and signature verification.
- `build/`: ignored generated products and helper/test executables.

## Rendering and preferences

Artwork uses a centered 640 × 640 coordinate space. The static dial is cached in an `NSImage`; only hands redraw each frame. Material images are generated once per finish per view and cached. They are entirely procedural and need no asset files.

Every five minutes, the full clock cross-fades over ten seconds to the next of
five positions within 1.2% of the drawable's shorter dimension.
Monotonic elapsed time drives the transition independently of the clock time and
daily style. During a dissolve, two complete opaque scenes are blended, including
their backgrounds, to keep overlapping artwork at consistent brightness. Device
scale is accounted for on both axes. Reduce Motion skips the dissolve; small host
previews and generated artwork remain centered. The browser prototype uses the
same timing and offsets.

Design IDs 0–4 map to Atelier, Bill, Los Angeles, Ikko, and Georg. The Design popup uses item tags; Auto has tag 5, independent of the menu separator's position. Keep the palette tables and dispatch methods consistent with these IDs.

`ScreenSaverDefaults` uses the `local.atelier.clock` module. Stored keys are `design`, `palette`, `automatic`, `appearance`, `movement`, `size`, and `numerals`. Auto mode preserves the stored manual design and palette while resolving the displayed combination from the local date. Optional numerals default to off.

The desktop timer and screensaver host drive the same renderer. The `AC_HARNESS` compiler flag enables date injection and direct design configuration for tests; normal builds leave it off.

## Build and validation

Run `bash build.sh` on macOS with Apple's Command Line Tools. The compiler targets macOS 13, arm64, and x86_64, with ARC enabled. Both bundles are ad-hoc signed; they are not notarized. Rebuilding removes obsolete generated wood-image directories from older bundles.

Run `bash Tests/run.sh` for daily-selection and preference checks. Add `--options` for native window tests: 100 repeated sheets, repeated configuration-property queries, and 20 parentless modal sessions. These tests require WindowServer access and use a test-only preference store.

Native builds, signature checks, and offscreen rendering have been exercised. Before a release, check full screen, multiple displays, sleep/wake, and sustained use of the System Settings picker on the target macOS versions.

Regenerate the README images with `bash Tools/render-previews.sh`. It renders all
five native dials at 10:10:30 with their first light palette and optional numerals
off, writing the PNGs directly into `docs/previews/`. The same command generates
`Resources/thumbnail.png` (90 × 58) and `Resources/thumbnail@2x.png` (180 × 116)
from the light Ikko dial for legibility at small sizes, with extra vertical margin
to allow for cropping. These follow the filenames and dimensions used by Apple's
bundled Random screensaver. `build.sh` copies them into the screensaver's
`Contents/Resources/` before signing; they supply the picker tile independently
of the live preview.

The command also renders the same clock at standard and Retina icon sizes
(16–1024 pixels) and uses Apple's `iconutil` to create `Resources/AtelierClock.icns`.
Both bundles declare it with `CFBundleIconFile`. Temporary iconset images are
removed after conversion. Run this tool in a normal Mac terminal: `iconutil`
needs access to macOS image services and can report “Invalid Iconset” in a sandbox.

## Screensaver host details

`build.sh` writes SDK/platform metadata required by modern hosts. The renderer also uses the graphics context's clip bounds to accommodate backing-pixel geometry reported by the legacy host.

The configuration-window getter must leave active presentations and unsaved controls intact. Save and Cancel finish the appropriate sheet or modal session before hiding the window. Never stop an unrelated host modal session.

If Options stops responding, inspect the local lifecycle log:

```sh
log show --last 10m --style compact --predicate 'subsystem == "local.atelier.clock" AND category == "Options"'
```

These events help distinguish requests that never reach the saver from windows that fail to dismiss. After installing a rebuilt saver, reopening Settings may be necessary to load the new code.

The picker can retain the generic galaxy thumbnail from an earlier installation
even when the installed bundle contains valid thumbnail PNGs. macOS caches these
separately under `com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails`
in the user's Darwin cache directory. Its wallpaper agent's cached legacy
screensaver view model maps each saver to its thumbnail URL. To diagnose this,
inspect the entry for Atelier Clock and its image. If it is stale, quit Settings,
back up and remove only that thumbnail, and restart `WallpaperLegacyExtension`
before reopening Settings. Do not clear unrelated wallpaper caches or preferences.
