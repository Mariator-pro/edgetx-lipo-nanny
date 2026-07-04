# edgetx-lipo-nanny

![lipo-nanny banner](docs/banner.png)

EdgeTX Lua script that tracks battery voltage and capacity, alerting the pilot before critical battery conditions occur.

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)
[![EdgeTX](https://img.shields.io/badge/EdgeTX-%E2%89%A5%202.11-brightgreen)](https://edgetx.org)
[![ExpressLRS](https://img.shields.io/badge/ExpressLRS-%E2%89%A5%203.0-orange)](https://www.expresslrs.org)
[![GitHub issues](https://img.shields.io/github/issues/Mariator-pro/edgetx-lipo-nanny)](../../issues)
[![GitHub last commit](https://img.shields.io/github/last-commit/Mariator-pro/edgetx-lipo-nanny)](../../commits/main)

---

## 📚 Table of Contents

- [📋 Compatibility](#-compatibility)
- [🎯 What is it for?](#-what-is-it-for)
- [🧰 Requirements](#-requirements)
- [📥 Installation](#-installation)
- [🛠️ Troubleshooting](#-troubleshooting)
- [🤝 Contributing](#-contributing)
- [⚠️ Disclaimer](#-disclaimer)
- [📄 License](#-license)

---

## 📋 Compatibility

| Component   | Minimum Version | Tested On | Test Hardware                              |
|-------------|-----------------|-----------|--------------------------------------------|
| EdgeTX      | v2.11           | v2.12.0   | Radiomaster TX15, Radiomaster TX16S MK3    |
| ExpressLRS  | v3.0.0          | v4.0.0    | Radiomaster RP1 V2, RP3 V2, RP4TD          |

---

## 🎯 What is it for?

Lipo Nanny lets RC pilots focus on flying. The EdgeTX script watches the flight battery over your model's telemetry (ELRS/CRSF out of the box, other systems via per-model sensor mapping) and speaks up on its own: twice per flight, when it's time to return and when it's time to land.

It solves three concrete problems:
- **Deep discharge** that permanently damages LiPo cells.
- **Guesswork about remaining flight time** during the flight.
- **Crashes from a battery noticed too late.**

**How it works**

- At connect, the script reads the resting voltage, auto-selects the matching battery from a per-model library (or lets you pick when several fit), and estimates the starting state-of-charge from a chemistry-specific voltage curve (LiPo, LiPoHV, LiIon).
- During flight, the FC-reported consumed-mAh counter (CRSF `Capa` by default) is offset by the start SoC, so remaining capacity reflects reality from the first second.
- **Telemetry-system agnostic:** the four sensors (voltage, current, consumed mAh, link) default to the CRSF/ELRS names but are remappable **per model** in the tool, so FrSky S.Port and other systems work too.
- Two one-shot voice announcements fire on percentage thresholds: **warn** (default 30 %) and **critical** (default 20 %), both globally tunable and per-profile overridable. An optional **haptic buzz** (one pulse on warn, two on critical) can accompany them.
- Per physical **pack** (#1, #2, …) the script keeps a **cycle count** plus read-only **statistics** (lifetime consumed mAh, lowest cell voltage seen, and the last-used date), all viewable per profile in the tool.
- Each pack can carry a **wear %** that lowers its effective capacity, so an aging battery triggers the warnings **earlier**; there's no need to re-tune your thresholds as a battery gets tired. An optional **purchase date** per pack helps track battery age.

---

## 🧰 Requirements

- A radio running EdgeTX 2.11 or newer (color-display models only)
  > `v2.11` is a hard minimum: the widget's **Theme** selector uses a `CHOICE` widget option that EdgeTX only supports from 2.11 onward.
- A receiver that reports battery telemetry: at minimum **voltage** and **consumed mAh**
  > ExpressLRS ≥ 3.0 works out of the box (default sensor names `RxBt`/`Curr`/`Capa`/`RQly`). Other systems (e.g. FrSky S.Port with `VFAS`/`Cur`/`mAh`/`RSSI`) are supported by remapping the sensors **per model** in the tool. `v3.0.0` is the earliest ELRS version verified on hardware.

---

## 📥 Installation

1. **Copy the files onto the radio's SD card.** Copy everything below to the same locations. `core.lua` holds the shared logic and must sit next to the widget and tool — both load it at startup and show a "core.lua missing" hint if it isn't there. (Only `config.lua` is created automatically, on first save.)

   ```
   WIDGETS/
   └── LIPONY/
       └── main.lua             ← telemetry widget (display)
   SCRIPTS/
   ├── TOOLS/
   │   └── LIPONY.lua           ← configuration tool
   └── LIPONY/
       ├── core.lua             ← shared logic + config format (REQUIRED by both)
       └── config.lua           ← written by the tool (created on first save)
   SOUNDS/
   └── en/
       └── SCRIPTS/
           └── LIPONY/
               ├── warn.wav     ← early warning    (e.g. "return to home")
               └── crit.wav     ← critical warning (e.g. "land now")
   ```

   The WAV files are yours to supply; `warn.wav` / `crit.wav` are just the defaults. Drop additional named `*.wav` files into the same folder to pick them per warning under **Tools → Lipo Nanny → Settings**. The WAVs always live under `/SOUNDS/en/SCRIPTS/LIPONY/` regardless of the radio's language setting; the script plays them by absolute path.

2. **Restart the radio** (or reload Lua scripts) so EdgeTX picks up the new files.

3. **Create your configuration**: open **Tools → Lipo Nanny** and set up:
   - at least one **battery profile** (manufacturer, chemistry, capacity, cell count, packs)
   - the **model settings** for the active model (cell count, single vs. parallel, assigned batteries)
   - *(only if you don't use ELRS/CRSF)* the **sensor mapping** under **Models → Sensors**: point the four sensors at your system's telemetry names
   - *(optional)* the global **Settings** (warn / critical thresholds, per-warning sounds, haptic feedback)

4. **Place the widget**: add the **Lipo Nanny** widget to a telemetry screen. It only runs while it is placed on a page.

5. *(Optional)* Open the widget settings to adjust:
   - **Theme**: `Dark` / `Light`.
   - **Transparency**: milky-overlay transparency level (light theme only).
   - **Accent**: color of the heading / brand text. `Default` (the classic green), `Theme` (the focus color of your active EdgeTX theme), or `Custom` (pick any color via **AccentColor**).

> 📐 **Recommended screen layouts:** EdgeTX names its widget-screen layouts `columns × rows` (e.g. `2×4` = 2 columns next to each other, 4 rows on top of each other → 8 zones). The Lipo Nanny widget is designed for a **half-width** zone, so it looks best in the layouts with **2 columns**:
>
> - **2×2**: half width, half height (the quarter-tile). This is the primary use case and shows the full layout with every value.
> - **2×3**: half width, one third height. Slightly shorter, so the widget automatically switches to a more compact layout.
> - **2×4**: half width, one quarter height. The shortest supported zone; it falls back to the most compact layout to stay readable.

> Detailed configuration and in-flight usage: see [`docs/configuration.md`](docs/configuration.md) and [`docs/usage.md`](docs/usage.md).

---

## 🛠️ Troubleshooting

If something's off, the widget tile usually tells you what:

| Tile shows | Meaning / fix |
|---|---|
| `No Battery connected…` | No link / no battery yet. Power the model and check the ELRS connection. (`Calculating…` once the link is up, `USB connected` when on USB power.) |
| `Sensor missing` | A required sensor (voltage or consumed-mAh, `RxBt`/`Capa` by default) isn't present. Run **Discover sensors** in EdgeTX telemetry, or remap the sensor names under **Tools → Lipo Nanny → Models → Sensors**. |
| `Setup required` | No configuration yet. Open **Tools → Lipo Nanny** and create it. |
| `Config invalid` | `config.lua` is corrupt or has the wrong schema version. Recreate it in the tool, or fix/delete it on the PC. |
| `Model not configured` | The active model has no entry. Add it in **Tools → Lipo Nanny → Models**. |
| `No batteries assigned` | Assign at least one matching battery profile to the model. |
| `Cell count mismatch` | No assigned profile matches the model's cell count. |
| `Widget error` | An internal fault. Remove and re-add the widget, or restart the radio. |
| `core.lua missing` | `SCRIPTS/LIPONY/core.lua` wasn't copied to the SD card. Add it next to `config.lua` and restart. |

**No voice warning?** Check that `warn.wav` / `crit.wav` exist and the radio volume is up.

**Tool says "Save failed" on first run?** The data folder `/SCRIPTS/LIPONY/` is missing. Create it on the SD card (EdgeTX/Lua can't create folders itself), then retry.

> More cases and fixes: see [`docs/troubleshooting.md`](docs/troubleshooting.md).

---

## 🤝 Contributing

Found a bug, have an idea for an improvement, or running an FC firmware whose flight-mode strings aren't covered yet? Please [open an issue](../../issues) on GitHub. Pull requests are welcome too.

---

## ⚠️ Disclaimer

This script is provided **as is** and is intended as a pilot aid only. It monitors battery voltage and capacity reported via telemetry and raises audible/visual warnings when configurable thresholds are reached. It does **not** replace the pilot's own battery management, careful flight planning, or visual monitoring of the aircraft. Telemetry can be delayed, noisy, or temporarily lost (signal dropouts, sensor issues, incorrect cell-count detection), and the script cannot warn about conditions it does not see. Always land with a safe voltage and capacity reserve, treat the warnings as a backup, not a substitute, for your own judgement, and rely on the safety mechanisms of your transmitter, receiver and flight controller. Use at your own risk.

---

## 📄 License

Released under the [GNU General Public License v2.0](LICENSE).
