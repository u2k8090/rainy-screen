# Changelog

## v0.1.0-beta.4 — 2026-09-10

- Weather Mode now uses weather-derived intensity without multiplying it by the manual strength or forcing manual Mist rendering.
- Manual intensity and random interval controls are unavailable in Weather Mode; Rainy Mode retains the saved settings.
- Added dedicated Wipe and Cursor settings categories, including five wipe-speed levels and five wipe-size levels.
- Added the radial Blower cursor effect with five strength levels controlling impulse, travel distance, affected area, and fog clearing speed.
- Blower motion now carries existing droplets for a finite distance, while ordinary gravity and adhesion resume afterward; persistent heavy-rain through-flow channels remain anchored.
- Updated Japanese and English usage, download, and MIT license documentation.
- Verified 30 core tests, the settings-state regression, settings UI smoke test, release build, and ad-hoc signature.

## v0.1.0-beta.3 — 2026-09-09

- Improved droplet attachment, stopping and restarting, heavy-rain blending, and deluge speed and trails.
- Added weather-code and precipitation-based intensity mapping.

This project remains an early beta for Apple Silicon Macs on macOS 14 or later. Binaries are ad-hoc signed and not notarized.
