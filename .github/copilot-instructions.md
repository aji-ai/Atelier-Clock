# Atelier Clock development instructions

This repository builds a native macOS screensaver and desktop app from the same Objective-C/AppKit renderer. Read `docs/DEVELOPMENT.md` for architecture and host-specific behavior.

- Build both universal, locally signed products with `bash build.sh`.
- Run `bash Tests/run.sh` for date and preference logic. Use `--options` for UI lifecycle changes; it requires WindowServer access and briefly shows test windows.
- Use the `AC` prefix for C helpers and constants. Keep rendering in the existing 640 × 640 coordinate system.
- Keep static artwork in the dial cache and animated hands outside it. Invalidate the cache when its inputs change.
- Preserve stored manual preferences when Auto mode resolves a daily style. The popup uses tags, not menu positions, because it includes a separator.
- Do not dismiss or reset an active options sheet from its getter. Dismiss only the matching sheet/modal session.
- Keep wood materials procedural and independent of external photographs.
- Keep build output in ignored `build/`. Keep the browser prototype separate in `Examples/BrowserPreview/`.
- Update documentation when defaults, build requirements, or supported behavior change. Report which native checks actually ran.
