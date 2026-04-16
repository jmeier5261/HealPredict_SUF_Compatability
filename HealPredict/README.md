# HealPredict - Shadowed Unit Frames Compatibility

## Overview

This module provides full HealPredict integration with Shadowed Unit Frames (SUF). It renders heal prediction bars, overheal indicators, absorb overlays, and all indicator features directly on SUF health bars for all frame types.

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
- Party (1-5), Party Pets (1-5)
- Raid (1-40), Raid Pets (1-40)
- Arena (1-5), Arena Pets (1-5)
- Boss (1-4)

## Features

### Heal Prediction Bars
- Four stacked prediction bars (my direct, my HoT, other direct, other HoT)
- Bars extend past the health bar edge based on the configured overflow percentage
- Overflow caps are per-frame-type: unit frames, party, and raid each have separate settings
- Bar-to-amount mapping matches the core renderer exactly (sorted and non-sorted modes)

### Color Support
- **Standard palette**: Uses the correct color keys per frame type (raid palette for party/raid, unit palette for player/target/etc.)
- **Overheal palette**: Bars switch to shifted-hue colors when overhealing exceeds the configured threshold
- **Class-colored bars**: When smart ordering + class colors are enabled, each bar shows the casting healer's class color via `Engine:GetHealAmountByCaster()`
- **Dim non-imminent**: Non-self heals are dimmed when the setting is active; dimming is suppressed during overhealing to maintain visual consistency

### Incoming Heals from Other Players
- Supplements HealPredict's HealEngine data with the native WoW API (`UnitGetIncomingHeals`) to display heals from players who aren't running HealPredict
- Only the **other-heal** portion is supplemented — self heals use the Engine exclusively to avoid amount discrepancies between the API and Engine calculations

### Overheal Bar
- Shows heal amount exceeding max health as a separate colored bar at the bar edge
- Width derived from the actual pixel endpoint of the prediction bars for exact alignment
- Gradient coloring (green to orange to red) based on overheal severity, normalized to the overflow range
- Renders behind prediction bars to prevent color bleed-through on dimmed bars
- Controlled by `Show Overheal Bar` in HealPredict settings

### Absorb Bar
- Shows shield/absorb amount overlaying the health fill
- Positioned at the health endpoint, growing inward
- Controlled by `Show Absorb Bar` in HealPredict settings

### Shield Glow & Shield Text
- Shield glow texture at the health fill endpoint when a shield is active
- Shield spell abbreviation text (e.g., "PW:S", "IceBr") from `HP.SHIELD_NAMES`

### Texture Support
- When the raid texture option is **enabled**: bars use the `Raid-Bar-Hp-Fill` statusbar texture
- When **disabled**: bars use solid color (`SetColorTexture`) for exact color accuracy via `SetVertexColor`
- Toggling at runtime correctly switches between the two modes via a `RefreshBarTextures` hook

### Orientation & Fill Direction
- Reads orientation and reverse-fill directly from the health bar (`GetOrientation()` / `GetReverseFill()`)
- Supports horizontal (normal/reversed) and vertical (normal/reversed) bars

### Bar Alignment
- Prediction bars anchor vertically to the health bar's fill texture rather than the StatusBar frame, so they match the visible fill height exactly without extending into border/padding areas

### Indicator Effects
All indicator border effects from the core renderer are supported, using `HP.CreateIndicatorEffect` with Static, Glow, Spinning, and Slash styles:

- **HoT expiry warning** — border glow when your HoT is about to expire on a target
- **Dispel highlight** — colored border when a dispellable debuff is detected
- **Cluster detection** — border highlight for AoE healing targets
- **Heal reduction glow** — border effect + percentage text when healing is reduced (e.g., Mortal Strike)
- **Defensive cooldown** — border effect for active defensive cooldowns (invulns, strong/weak mitigation)
- **Charmed/Mind-controlled** — border indicator with direct `UnitIsCharmed()` fallback so it works on all frames regardless of other settings
- **AoE advisor border** — 4-edge colored border highlighting the recommended AoE heal target

### Snipe Detection
- Red border flash animation when your heal is sniped (overheal exceeds threshold)
- Hooks `HP.OnSnipe` to flash SUF frames matching the sniped target's GUID

### Text Indicators
- **Health deficit text** — shows remaining health deficit after incoming heals
- **Healer count** — number of active healers on each target, with configurable position
- **Heal text** — incoming heal amount with hold-max display to prevent flicker
- **CD tracker text** — external cooldown abbreviations on targets
- **Res tracker** — "RES" text when a resurrection is being cast on the target
- **Death prediction** — warning text when a target is predicted to die
- **Heal reduction text** — percentage text (e.g., "-50%") with configurable position (TL/TR/C/BL/BR)

### HoT Tracker Dots
- 5 individual HoT type indicators (Renew, Rejuv, Regrowth, Lifebloom, Earth Shield)
- Supports both **dot mode** (colored squares) and **icon mode** (spell icons with cooldown sweeps)
- Separate rows for own HoTs and other healers' HoTs (desaturated in icon mode)
- Configurable position, size, and spacing via `HP.ApplyDotAnchors`

### Low Mana Warning
- Percentage text on healer-class frames when mana drops below threshold
- Polls mana directly on each SUF frame (core renderer only checks Blizzard compact frames)
- Healer class detection cached per frame

### Mana Cost Bar
- Blue shaded overlay on the SUF player power bar showing how much mana the current cast will consume
- Hooks `HP.UpdateManaCostBar` and `HP.HideManaCostBar` to mirror onto SUF's `powerBar`

### Mana Sustainability Forecast
- "OOM: Xs" text on the SUF player power bar
- Color-coded: red (<15s), orange (<30s), yellow (>30s)
- Hooks `HP.UpdateManaForecast` and `HP.UpdateManaForecastAnchor`
- Configurable position (Above/Center/Below/Right)

### Out-of-Combat Regen Timer
- "Full: Xs" or "Full: Xm" text on the SUF player power bar when out of combat with non-full mana
- Uses `GetManaRegen()` for accurate spirit/mp5/buff-aware regen rate
- Stacks below the forecast text when both are visible at the same anchor position
- Hooks `HP.UpdateOOCRegen`, `HP.UpdateOOCRegenAnchor`, and `HP.ResetOOCRegen`

### Defensive Cooldown Display
- Icon + text display for active defensive cooldowns on targets
- Category-aware coloring (invuln = gold, strong = blue, weak = green)
- Border effect style configurable (Static/Glow/Spinning/Slashes)
- Configurable position via `HP.DEFENSE_ANCHORS`

## Technical Details

### Frame Detection
SUF header-driven frames (party, raid, arena, boss) are not registered as globals. The module accesses them via `ShadowUF.Units.unitFrames["party1"]`, etc. Single-unit frames (player, target) are also accessed this way, with a fallback to globals (`SUFUnitplayer`). Pet frames (`partypet`, `raidpet`, `arenapet`) are also detected.

### Media
The statusbar texture is read from `ShadowUF.Layout.mediaPath.statusbar`, which is SUF's resolved and cached texture path via LibSharedMedia.

### Update Cycle
- A 0.05-second ticker (~20fps) drives updates for all tracked SUF frames
- Additionally, each health bar's `OnValueChanged` is hooked for immediate response
- New party/raid/arena frames are picked up via `RefreshSUFFrames()`
- Mana-related features hook the core's update/reset functions directly

### Hooks (non-invasive)
The module hooks the following core functions without modifying their source files:
- `HP.RefreshBarTextures` — re-applies correct texture mode after toggle
- `HP.UpdateManaCostBar` / `HP.HideManaCostBar` — mirrors mana cost to SUF power bar
- `HP.UpdateManaForecast` / `HP.UpdateManaForecastAnchor` — mirrors forecast text
- `HP.UpdateOOCRegen` / `HP.UpdateOOCRegenAnchor` / `HP.ResetOOCRegen` — mirrors regen timer
- `HP.OnSnipe` — flashes SUF frames on snipe detection

### Debug Command
```
/hpcompat suf
```
Prints tracked SUF frames, settings state, and live heal amounts (my + other) for all frames.

### Files Modified
- `HealPredict/Main/Modules/SUFCompat.lua` — the compatibility module (full rewrite)
- `HealPredict/Main/Config/Init.lua` — calls `InitSUFCompat()` 3 seconds after `PLAYER_ENTERING_WORLD`
- `HealPredict/Main/Modules/Modules.xml` — loads `SUFCompat.lua`
