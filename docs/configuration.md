# Configuration

All configuration happens in the **Tools → Lipo Nanny** tool on the radio. It
writes a single `config.lua` into `/SCRIPTS/LIPONY/`, which the widget reads at
runtime. You never have to edit files on the PC.

> First run: if the data folder `/SCRIPTS/LIPONY/` is missing, the tool can't
> save (EdgeTX/Lua can't create folders). Create it once on the SD card, then
> open the tool again.

---

## Menu overview

The main menu has four entries (plus **Exit**):

| Entry | What it does |
|---|---|
| **Batteries** | Your library of battery *profiles* (a model of battery) and their physical *packs*. |
| **Models** | Per-model setup: cell count, single vs. parallel, which batteries are assigned, sensor mapping. |
| **Settings** | Global warn / critical thresholds, sound test, and the destructive resets. |
| **About** | Version, schema version, and the file paths. |

Navigation: the rotary wheel moves the cursor, **Enter** opens a folder (`>`) or
edits a field, **Exit/RTN** goes back. Fields marked `>` open a sub-page.

---

## Batteries

A **profile** describes a *type* of battery; each profile owns one or more
physical **packs** that you actually fly and that accumulate cycles.

### Profile fields

| Field | Notes |
|---|---|
| **Name** | Auto-generated as `<Manufacturer> <S>s <Chemistry> <mAh>mAh` (tagged `(auto)`). Editing it switches to a manual override; the **Reset name** button (see below) reverts it to auto. |
| **Manufacturer** | Free text, max **10 chars** (used in the auto name). |
| **Chemistry** | `LiPo`, `LiPoHV`, or `LiIon`. Drives the resting-voltage → state-of-charge curve. |
| **Capacity** | Nominal pack capacity in mAh (**10–50000**). The **MDL** key cycles the step size 10 → 100 → 1000. |
| **Cells** | Cell count (S), **1–30**. Must match the model's cell count to be assignable. |
| **Packs** | Opens the Packs sub-page (see below). |
| **Low** | Per-profile **warn** override (**1–99 %**). Shows `… % (default)` until you set one; landing back on the default value clears the override. |
| **Critical** | Per-profile **critical** override. Same range and default behaviour. |

Buttons: **Save**, **Back**, **Delete** (existing profiles only), and **Reset
name** (only while the name is a manual override).

> **Text entry** (Name, Manufacturer): the wheel spins through a character ring;
> the **MDL** key switches the ring group (**ABC** → **abc** → **123#**). The
> name field holds up to 30 characters.

### Packs

Each row is one physical pack: **ID** (`#1`, `#2`, …), **Cycles**, **Wear**, and
**Remove**. Select a row and dive in to edit:

- **Cycles**: the stored cycle count (**0–9999**). Normally the widget increments
  it; editable here for corrections.
- **Wear %**: **0–50 %**; lowers the pack's *effective* capacity, so an aged pack
  hits the warnings **earlier**. You don't have to re-tune thresholds as a pack
  ages.
- **Remove**: archives the pack (its cycle history is kept under the hood). You
  **can't remove the last pack** (delete the whole profile instead), and a
  profile used by a parallel model must keep at least two packs.

Use **[+] Add pack** to add another physical pack to the profile.

---

## Models

The Models list shows every configured model; the running model is tagged
`[active]`. If the active model isn't configured yet, **[+] Add current model**
appears in the bottom bar.

### Model fields

| Field | Notes |
|---|---|
| **Cells** | The model's cell count (S). Only profiles with a matching cell count can be assigned. |
| **Parallel packs** | `Yes` if you fly two packs in parallel (shown as `#1+2`), otherwise `No`. Requires at least one assigned profile (of the model's cell count) that has **two or more packs**; the tool blocks saving otherwise. |
| **Batteries** | Opens the assignment page, where you tick the profiles that fit this model. Profiles with the wrong cell count are shown disabled. |
| **Sensors** | `default` (CRSF/ELRS names) or `custom`. Opens the sensor-mapping page. |

Buttons: **Save**, **Back**, and **Delete** (existing model configs only).

### Sensors (per model)

Only needed if you don't use ELRS/CRSF. Four telemetry sources are mapped:

| Sensor | Default name | Used for |
|---|---|---|
| **Voltage** | `RxBt` | Resting voltage → start SoC, and the live V/cell readout. |
| **Current** | `Curr` | Live current draw. |
| **Capacity** | `Capa` | Consumed mAh, the main remaining-% driver. |
| **Link** | `RQly` | Link/connection state. |

Point each one at your system's telemetry name (e.g. FrSky S.Port:
`VFAS` / `Cur` / `mAh` / `RSSI`). **Reset to CRSF defaults** (shown only when a
custom mapping is set) restores the default names. The mapping is saved together
with the model.

---

## Settings (global)

| Item | Notes |
|---|---|
| **Low threshold** | Global **warn** percentage (**1–99 %**, default **30 %**). The first voice announcement. |
| **Critical threshold** | Global **critical** percentage (default **20 %**). The second announcement. Saving is blocked unless **Low is above Critical**. |
| **Test low sound** | Plays `warn.wav` so you can check it exists and the volume is up. |
| **Test critical sound** | Plays `crit.wav`. |
| **Reset statistics** | Zeroes every pack's cycle count and empties the archive. |
| **Reset configuration** | Restores factory defaults; **all** batteries and models are erased. |

Per-profile **Low/Critical** overrides (above) take precedence over these global
values for that profile.

> Changes you save in the tool are picked up by a running widget within a few
> seconds (it re-reads `config.lua` on its own), so no radio restart is needed.
> On the very first launch with no config, the tool shows a **First start**
> screen; press **Create** to write the defaults.

---

## Widget options

These are set in EdgeTX's own **widget settings** (long-press the widget /
*Edit*), not in the tool:

| Option | Values | Effect |
|---|---|---|
| **Theme** | `Dark` (default) / `Light` | **Dark** paints its own near-black panel so the tile looks identical on any radio theme. **Light** is transparent, so your radio theme shows through, with black text. |
| **Transparency** | `0`–`5` (default `2`) | A milky overlay strength, applied **only in the Light theme** (`0` = none). Ignored in Dark. |

---

## How the numbers fit together

1. At connect, the widget reads **resting voltage**, auto-selects the pack when
   exactly one matches (otherwise it asks; see the selection popup in
   [usage.md](usage.md)), and estimates **start SoC** from the chemistry curve.
2. In flight, the FC's **consumed-mAh** counter is offset by that start SoC, so
   remaining % is realistic from the first second.
3. **Wear %** shrinks effective capacity; the warn/critical thresholds fire on
   the resulting remaining %.

See [usage.md](usage.md) for what happens in the air, and
[troubleshooting.md](troubleshooting.md) if a tile shows an error.
