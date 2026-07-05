# Troubleshooting

The widget tile is the first place to look: it names the problem. Below are all
the states it can show, plus a few issues outside the tile.

---

## Status / waiting tiles

These are normal, not errors; the widget is waiting for something:

| Tile shows | Meaning |
|---|---|
| `No Battery connected…` | No link / no battery yet. Power the model and check the ELRS connection. |
| `Calculating…` | Link is up; the widget is settling on the resting voltage to estimate start SoC. Wait a moment before launch. |
| `USB connected` | The radio is on USB power, so there's no real flight battery to monitor. |

---

## Error tiles

| Tile shows | Meaning / fix |
|---|---|
| `core.lua missing` | `/SCRIPTS/LIPONY/core.lua` wasn't copied to the SD card. It holds the shared logic and must sit next to `config.lua`. Add it and restart. (The tool shows a full-screen `core.lua missing` message for the same reason.) |
| `Sensor missing` | A required sensor (voltage or consumed-mAh, `RxBt` / `Capa` by default) isn't present. Run **Discover sensors** in EdgeTX telemetry, or remap the names under **Tools → Lipo Nanny → Models → Sensors**. |
| `Setup required` | No configuration yet. Open **Tools → Lipo Nanny** and create it. |
| `Config invalid` | `config.lua` is corrupt or has the wrong schema version. Recreate it in the tool (**Settings → Reset configuration**), or fix/delete it on the PC. |
| `Model not configured` | The active model has no entry. Add it in **Tools → Lipo Nanny → Models** (use **[+] Add current model**). |
| `No batteries assigned` | The model has no battery profile assigned. Open the model → **Batteries** and tick at least one matching profile. |
| `Cell count mismatch` | No assigned profile matches the model's cell count. Fix the model's **Cells** value, or assign a profile with the right cell count. |
| `Widget error` | An internal fault. Remove and re-add the widget, or restart the radio. If it persists, please [open an issue](../../issues). |

---

## Other issues

**No voice warning?**
- Check that the warning's **Sound** isn't set to **Off** in **Settings**
- Check that the selected sound file exists in `/SOUNDS/en/SCRIPTS/LIPONY/`
  (the defaults are `warn.wav` / `crit.wav`).
- Use the **Play** button next to each warning in **Settings** to confirm playback.
- Make sure the radio volume is up.

**No haptic buzz?**
- Enable **Settings → Haptic feedback** (it's **Off** by default).
- Radios without a vibration motor can't buzz; the setting is simply ignored there.

**Tool says "Save failed" on first run?**
The data folder `/SCRIPTS/LIPONY/` is missing. EdgeTX/Lua can't create folders,
so create it once on the SD card, then retry.

**Widget can't be added / doesn't appear?**
- Confirm `/WIDGETS/LIPONY/main.lua` is on the SD card and the radio was
  restarted (or Lua reloaded) afterwards.
- The widget needs a **color-display** radio on **EdgeTX 2.11+** (the Theme
  option uses a feature added in 2.11).
- In the widget picker it's listed as **Lipo Nanny**.

**Each announcement plays twice?**
You have the widget on two telemetry screens, i.e. two instances. That's
expected; remove one instance if you only want a single announcement.

**Remaining % looks off right after connect?**
Let the `Calculating…` phase finish before launch so the resting-voltage SoC
estimate is taken cleanly. A noisy/loaded voltage at plug-in skews the start
point.

---

If your problem isn't here, please [open an issue](../../issues) with the radio
model, EdgeTX version, and what the tile shows.
