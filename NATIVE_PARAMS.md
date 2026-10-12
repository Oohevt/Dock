# Native Dock parameters (macOS 27.0.1, 1920x1080pt @2x)

| Parameter | Native value | Source | DockGroups constant |
|---|---|---|---|
| tilesize | 70 | com.apple.dock | read live |
| largesize | 89 | com.apple.dock | read live |
| magnification | 1 | com.apple.dock | read live |
| autohide (original) | 1 | saved origAutohide | mirrored |
| autohide-delay (original) | 0 | saved origAutohideDelay | reveal delay |
| autohide-time-modifier | unset (default 1.0) | com.apple.dock | slideOmega 14 (/modifier) |
| launchanim / mineffect | 1 / genie | com.apple.dock | bounceDuration 1.4 |
| show-recents / orientation | 0 / bottom | com.apple.dock | n/a |
| Icon pitch / gap | 74pt / 4pt | measured | NativeDock.iconGap 4 |
| Bar height | ~89.5pt | measured | barExtraH 20 |
| Bottom margin | ~5.5pt | measured | bottomMargin 5.5 |
| Horizontal padding | ~9pt | measured | barPadX 9 |
| Corner radius | ~26pt | measured | cornerRadius 26 |
| Icon base Y | ~10pt | measured | iconBaseY 10 |
| Running dot | 4pt, y≈3pt | measured | dotSize 4, dotY 3 |
| Magnification falloff | ~3 icon widths | measured | falloff 3.0 |
| Mag enter/exit ease | spring ω≈30 | observed | magEnterOmega 30 |
| Tooltip | 8pt gap, 13pt font | measured | tooltipGap 8, tooltipFont 13 |
| Menu gap above icon | ~10pt | measured | menuGap 10 |
| Material | private DockGlassMaterialLayerController / ECMaterialLayer | Dock binary strings | "edge" custom layer (default); NSGlassEffectView .clear/.regular optional (customDockGlassStyle) |
