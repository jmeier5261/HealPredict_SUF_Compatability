# HealPredict — Fork with SUF Compatibility, Foreign-Caster Tracking, and TBC Bomb Heals

## Overview

This fork began as a Shadowed Unit Frames (SUF) compatibility module and has since expanded to add new engine-level features and fix long-standing visual bugs in how heals from other players are tracked and rendered.

**New in this fork:**
- **Foreign HoT tracking** — display HoT prediction bars for HoTs cast by other players who are **not** running HealPredict (the upstream engine only tracked your own HoTs and HoTs from other HealPredict users).
- **Dedicated "Other HoT" color slot** — a 5th prediction bar so foreign HoTs render with their own `OtherHoT` palette color instead of bleeding into the "my HoT" color.
- **Prayer of Mending tracking (TBC)** — the engine now recognizes PoM as a BOMB heal, tracks the buff holder through jumps, and renders a prediction bar for the incoming proc heal.
- **SUF compatibility module** — full integration of heal prediction, indicators, overlays, and text features with Shadowed Unit Frames.

## Installation

**Important:** This fork is a drop-in replacement for the original HealPredict addon. If you have the original HealPredict installed, you **must uninstall it first** — running both will cause conflicts (duplicate frame registration, stale engine state, and double event handling).

1. Close World of Warcraft completely.
2. **Uninstall the original HealPredict** if it's installed:
   - Delete `World of Warcraft/_anniversary_/Interface/AddOns/HealPredict/` (or whatever folder the upstream addon lives in).
   - Optional: preserve your saved variables by backing up `WTF/Account/<account>/SavedVariables/HealPredict.lua` first.
3. Copy the entire **`HealPredict`** folder from this repo into your AddOns directory so it lands at:
   `World of Warcraft/_anniversary_/Interface/AddOns/HealPredict/`
4. Launch World of Warcraft and log in — the fork will auto-detect SUF and initialize.

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

## Engine-Level Features (new in this fork)

These changes apply to **all** frame renderers — SUF, ElvUI, Blizzard, and nameplates — not just SUF.

### Foreign HoT Tracking

Upstream HealPredict only saw HoTs it could compute itself: your own casts (via the combat log) and HoTs from other players running HealPredict (via addon comm). HoTs from any other source were invisible — meaning on the vast majority of PuG and non-healer-stacked groups, you'd see no HoT prediction bars at all for heals landing on you.

This fork adds a third code path that detects foreign HoT applications from the combat log and estimates the incoming amount using **your own `GetSpellBonusHealing()` as a proxy for the caster's spell power**. Tracked spells:

- **Druid:** Rejuvenation, Regrowth, Lifebloom (HoT + bloom BOMB)
- **Priest:** Renew, Greater Heal's HoT component

The estimate is approximate at cast time (~within 20% for typical raid-geared healers). Once the first tick lands, the existing empirical-correction path in `CastTracking.lua` replaces the estimate with the actual combat-log tick amount, so the bar converges to the correct value within ~3 seconds.

**Conflict protection:** if a wire message from another HealPredict user arrives first, the foreign estimate defers to it — the addon-comm data is authoritative when available. Records created by the foreign fallback are tagged with `foreignEstimate = true` so wire data isn't clobbered.

### Five-Bar Prediction System + Dedicated "Other HoT" Color

Upstream's 4-bar sorted layout collapsed **all** HoTs — mine and others' — into a single `hotAmount` bucket, which the palette colored as `MyHoT`. This meant another priest's Renew on you would paint with **your** HoT color, which was visually misleading.

This fork:

1. **Splits `GetHealAmountSorted`** into `(otherBefore, selfAmount, otherAfter, myHot, otherHot)` — 5 return values. Self HoTs go to slot 4, foreign HoTs go to slot 5.
2. **Adds a 5th prediction bar** across all renderers (core Render.lua, SUFCompat.lua, ElvUICompat.lua) with its own palette slot.
3. **Uses the existing `raidOtherHoT` / `unitOtherHoT` color keys** (and their `OH` overheal variants) from `Core.lua` — no new config options needed. The overheal-state color for foreign HoTs is a dedicated entry in the color picker, separate from `MyHoTOH`.
4. **Extends class-color mode** (smart ordering + class colors) to support up to 5 distinct caster class colors (was 4).

Non-sorted mode is unaffected — it already routed foreign heals correctly through `GetHealAmountEx`'s self-vs-other split, so slot 5 is always 0 there.

### Generic `UnitGetIncomingHeals` Supplement

Previously, the SUF compatibility module supplemented engine data with Blizzard's `UnitGetIncomingHeals` API so direct heals from players **not** running HealPredict still rendered — but this logic lived only in SUFCompat. Blizzard default frames, nameplates, and ElvUI frames had no fallback, so on those renderers an external priest's Greater Heal on you would produce no bar at all.

This fork lifts the supplement into `HP.GetHeals` / `HP.GetHealsSorted` in [Render.lua](HealPredict/Main/Core/Render.lua) via a shared `ApplyAPISupplement` helper. Because every renderer goes through these two entry points, the fallback is now uniform across SUF, ElvUI, Blizzard, and nameplates.

**How it works:**
- `UnitGetIncomingHeals(unit)` returns the total direct-heal prediction for the target (TBC API doesn't include HoTs).
- `UnitGetIncomingHeals(unit, "player")` returns your own contribution.
- The delta `apiOther = apiTotal - apiSelf` is the direct-heal prediction from all other casters.
- If `apiOther` exceeds what the engine already knows (`engineOther` summed across all other-player slots), the excess is added to the "other direct" bucket (slot 3 sorted / slot 3 non-sorted) so it renders with the `OtherDirect` palette color.
- Sort-aware: in smart-ordering mode, slot 1 (`otherBefore`) is also an "other" slot, so it's included in the `engineOther` sum to prevent double-counting engine-tracked heals.

The class-colored rendering path was similarly made generic: `ApplyRealModeClassColors` in Render.lua now scans group members and assigns any API-only healer's contribution to the next free bar with their class color — behavior that previously existed only inside SUFCompat.

### Prayer of Mending Tracking (TBC)

Prayer of Mending was never modeled by the engine — it wasn't in `SpellData.lua` at all, so priests' PoM never produced an incoming-heal bar. This fork adds it as a `BOMB`-type heal.

- **Data** (`Engine.pomData` in SpellData.lua): TBC rank 1, spellID 33076, base 672, coefficient 0.4286, duration 30s.
- **Estimator** (`Engine.EstimatePoM(casterGUID, spellID)`): returns `base + sp * coeff` using the local player's `GetSpellBonusHealing()` as SP proxy. Works for both self-cast and foreign priests.
- **Tracking**: `SPELL_AURA_APPLIED` / `SPELL_AURA_REFRESH` creates or updates a BOMB record in `inbound[casterGUID]["Prayer of Mending_bomb"]` with the aura holder as the target; `SPELL_AURA_REMOVED` drops the target. When PoM jumps (REMOVED on old holder → APPLIED on new holder), the prediction bar follows.
- **No `AFFILIATION_MINE` gate** — foreign priests' PoM is tracked the same way as your own.

Because PoM BOMB records flow through `inbound` alongside Lifebloom blooms, they render through the existing bar pipeline with no renderer changes needed.

### Bug Fixes

- **Foreign HoTs no longer steal `MyHoT` color** — root cause was `GetHealAmountSorted` aggregating all HoTs into a single bucket regardless of caster. Fixed by the 5-bar split above.
- **Debug output updated** — `/hpcompat suf` now prints the foreign-HoT amount per tracked frame (`otherHoT=N`).

## SUF Features

### Heal Prediction Bars
- Five stacked prediction bars (my direct, my HoT, other direct, other HoT, foreign HoT)
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
Prints tracked SUF frames, settings state, and live heal amounts for all frames. Output now includes the foreign-HoT amount (`otherHoT=N`) as a distinct column so you can verify that other players' HoTs are being tracked.

### Files Modified in This Fork

**Engine (cross-renderer features):**
- `HealPredict/libs/HealEngine/HealEngine.lua` — `GetHealAmountSorted` splits HoTs by caster and returns a 5th value (`otherHotAmount`)
- `HealPredict/libs/HealEngine/SpellData.lua` — adds `Engine.foreignHoTs` / `EstimateForeignHoT` (cross-class foreign HoT registry), `Engine.pomData` / `EstimatePoM` (Prayer of Mending)
- `HealPredict/libs/HealEngine/CastTracking.lua` — foreign HoT apply/refresh branch, foreign HoT removal branch, Prayer of Mending aura tracking branch

**Renderers (5-bar system):**
- `HealPredict/Main/Core/Render.lua` — palettes extended to 5 slots, `GetHeals` / `GetHealsSorted` return 5 values, `RenderPrediction` handles a 5th bar, class-color helpers support 5 casters, SPECS arrays gained an `OtherHealBar3` entry
- `HealPredict/Main/Modules/SUFCompat.lua` — SUF compatibility module with 5-bar parity (full rewrite)
- `HealPredict/Main/Modules/ElvUICompat.lua` — ElvUI 5-bar parity
- `HealPredict/Main/Modules/Features.lua` — test frame bar creation extended to 5

**Initialization:**
- `HealPredict/Main/Config/Init.lua` — calls `InitSUFCompat()` 3 seconds after `PLAYER_ENTERING_WORLD`
- `HealPredict/Main/Modules/Modules.xml` — loads `SUFCompat.lua`
