# Solnari DMG artwork

This directory contains the editable source inputs used by `Scripts/create-dmg.sh`:

- `background@2x.png`: 1320×800 Retina source for the 660×400 Finder window.
- `volume-icon.png`: 1024×1024 transparent source for the mounted-volume icon.

The packaging workflow derives the 1× background, multi-representation TIFF, iconset, and ICNS in a
temporary directory. Do not edit or commit those generated files.

To refresh the design, replace only the two PNG sources while preserving their dimensions and alpha
requirements, then preview the derived assets with:

```bash
./Scripts/prepare-dmg-assets.sh .build/dmg-assets-preview
```

Build `./Scripts/package-local-dmg.sh`, mount the result, and verify the Finder layout at normal and
Retina display scaling before merging artwork changes. Branding does not replace Developer ID
signing or Apple notarization.
