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
| `Core missing` / `Reinstall Lipo Nanny` | `/SCRIPTS/LIPONY/core.lua` wasn't copied to the SD card. It holds the shared logic. Copy it to `/SCRIPTS/LIPONY/` and restart. (Without it, Flight Bag doesn't list Lipo Nanny either.) |
| `Configuration error` / `Please check Tool Flight Bag` | Something in the setup keeps the widget from working. Open **Tools → Flight Bag** and tap the Lipo Nanny icon (it carries a warning sign): the popup lists what is wrong. |
| `Widget error` | An internal fault. Restart the radio. If it persists, please [open an issue](../../issues). |

The Flight Bag popup names the problem:

| Popup shows | Fix |
|---|---|
| `No settings file yet` | Create the configuration in the popup. |
| `Settings file damaged` | `config.lua` is corrupt or has the wrong schema version. Reset it in the popup, or fix/delete it on the PC. |
| `Model not set up` | The active model has no entry. Add it under **Models** (use **[+] Add current model**). |
| `No batteries assigned to this model` | Open the model → **Batteries** and tick at least one matching profile. |
| `No assigned battery has N cells` | No assigned profile matches the model's cell count. Fix the model's **Cells** value, or assign a profile with that cell count. |
| `Missing sensors: RxBt, Capa` / `Check sensors config` | A required sensor (voltage or consumed mAh, `RxBt` / `Capa` by default) isn't present. Run **Discover new** on the model's telemetry page, or check the names under **Models → Sensors**. |

---

## Other issues

**No voice warning?**
- Check on the Flight Bag **Alerts** page that neither **Sounds** nor the warning's
  own sound is set to **Off**.
- Check that the selected sound file exists in `/SOUNDS/en/SCRIPTS/LIPONY/`
  (the defaults are `warn.wav` / `crit.wav` / `charge.wav`).
- Use the **Play** button next to each warning on the Flight Bag **Alerts** page to confirm playback.
- Make sure the radio volume is up.

**No haptic buzz?**
- Enable **Alerts → Vibration** in Flight Bag (it's **Off** by default).
- Radios without a vibration motor can't buzz; the setting is simply ignored there.

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
