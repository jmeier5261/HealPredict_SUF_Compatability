# HealPredict - Shadowed Unit Frames Compatibility

## Overview

This module provides full HealPredict integration with Shadowed Unit Frames (SUF). It renders heal prediction bars, overheal indicators, and absorb overlays directly on SUF health bars for all frame types.

## Installation
**Note:** Always back up your existing files before replacing them.

1. Close World of Warcraft completely
2. Navigate to your HealPredict addon folder:
   `World of Warcraft/_anniversary_/Interface/AddOns/HealPredict/`
3. Replace the following files with the ones provided:
   - `Main/Modules/SUFCompat.lua` — the SUF compatibility module
   - `Main/Modules/Modules.xml` — module load list (includes SUFCompat.lua)
   - `Main/Config/Init.lua` — addon initialization (includes SUF detection and startup)
4. Launch World of Warcraft and log in — HealPredict will auto-detect SUF and initialize

## Important: Disable SUF's Built-in Incoming Heals

SUF has its own incoming heals module that will conflict with HealPredict. You must disable it:

1. Type `/suf` in chat to open Shadowed Unit Frames settings
2. For each unit type (Player, Target, Party, Raid, etc.):
   - Navigate to the unit's settings
   - Find **Incoming Heals** (or **incHeal**) and **disable** it
3. This prevents two overlapping heal prediction bars on the same health bar

## Supported Frame Types

- Player, Target, Target of Target, Focus, Pet
- Party (1-5)
- Raid (1-40)
- Arena (1-5)
- Boss (1-4)

## Features

### Heal Prediction Bars
- Four stacked prediction bars (my direct, my HoT, other direct, other HoT)
- Bars extend past the health bar edge based on the configured overflow percentage
- Overflow caps are per-frame-type: unit frames, party, and raid each have separate settings

### Color Support
- **Standard palette**: Uses the correct color keys per frame type (raid palette for party/raid, unit palette for player/target/etc.)
- **Overheal palette**: Bars switch to shifted-hue colors when overhealing exceeds the configured threshold
- **Class-colored bars**: When smart ordering + class colors are enabled, each bar shows the casting healer's class color
- **Dim non-imminent**: Non-self heals are dimmed when the setting is active

### Overheal Bar
- Shows heal amount exceeding max health as a separate colored bar at the bar edge
- Width capped at the configured overflow percentage for the frame type
- Gradient coloring (green to orange to red) based on overheal severity, normalized to the overflow range
- Controlled by `Show Overheal Bar` in HealPredict settings

### Absorb Bar
- Shows shield/absorb amount overlaying the health fill
- Positioned at the health endpoint, growing inward
- Controlled by `Show Absorb Bar` in HealPredict settings

### Texture Support
- When the raid texture option is **enabled**: bars use the `Raid-Bar-Hp-Fill` statusbar texture
- When **disabled**: bars use solid color (`SetColorTexture`) for exact color accuracy via `SetVertexColor`
- Toggling at runtime correctly switches between the two modes

### Orientation & Fill Direction
- Reads orientation and reverse-fill directly from the health bar (`GetOrientation()` / `GetReverseFill()`)
- Supports horizontal (normal/reversed) and vertical (normal/reversed) bars

### Bar Alignment
- Prediction bars anchor vertically to the health bar's fill texture rather than the StatusBar frame, so they match the visible fill height exactly without extending into border/padding areas

## Technical Details

### Frame Detection
SUF header-driven frames (party, raid, arena, boss) are not registered as globals. The module accesses them via `ShadowUF.Units.unitFrames["party1"]`, etc. Single-unit frames (player, target) are also accessed this way, with a fallback to globals (`SUFUnitplayer`).

### Media
The statusbar texture is read from `ShadowUF.Layout.mediaPath.statusbar`, which is SUF's resolved and cached texture path via LibSharedMedia.

### Update Cycle
- A 0.05-second ticker (~20fps) drives updates for all tracked SUF frames
- Additionally, each health bar's `OnValueChanged` is hooked for immediate response
- New party/raid/arena frames are picked up via `RefreshSUFFrames()`

### Files Modified
- `HealPredict/Main/Modules/SUFCompat.lua` — the compatibility module (full rewrite)
- `HealPredict/Main/Config/Init.lua` — calls `InitSUFCompat()` 3 seconds after `PLAYER_ENTERING_WORLD`
- `HealPredict/Main/Modules/Modules.xml` — loads `SUFCompat.lua`
