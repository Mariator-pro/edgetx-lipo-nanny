# Compatibility

This page shows which Lipo Nanny features work with which flight controller firmware and which RC link. Each table looks at one side of the chain and assumes the other side delivers its data.

## Flight controller firmware

| Feature | Betaflight | INAV | ArduPilot |
|---|:-:|:-:|:-:|
| Link detection | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Battery auto-select | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Start SoC | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Remaining capacity | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Warnings (voice, haptic) | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Flight time left | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |
| Pack statistics | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> |

## RC link

| Feature | ExpressLRS | TBS Crossfire | ImmersionRC Ghost | FrSky ACCESS |
|---|:-:|:-:|:-:|:-:|
| Link detection | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Battery auto-select | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Start SoC | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Remaining capacity | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Warnings (voice, haptic) | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Flight time left | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |
| Pack statistics | ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> | ⚙️&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> |

ImmersionRC Ghost was checked with Betaflight only; INAV and ArduPilot over Ghost were not checked.

## Legend

- ✅&nbsp;<img src="https://img.shields.io/badge/-tested-brightgreen" alt="tested" height="20"> Tested on the radio and in the simulator.
- ✅&nbsp;<img src="https://img.shields.io/badge/-source-blue" alt="source" height="20"> Checked in the source code (flight controller and EdgeTX), not tested on hardware yet.
- ✅&nbsp;<img src="https://img.shields.io/badge/-closed%20fw-blue" alt="closed fw" height="20"> Radio side checked in the source code; the firmware of the RC link itself is closed source, so that part could not be checked.
- ⚙️ Works only after setup, see below. A badge next to ⚙️ means the same as next to ✅.

A ✅ means the feature works without extra setup, apart from a battery monitor with voltage and current sensor on the flight controller.

## Setup

What has to be set so the features work. Sensor mapping and the capacity unit are set per model under **Tools → Lipo Nanny → Models → Sensors** (see [`configuration.md`](configuration.md)). The tool only lists sensors EdgeTX already knows: with the model powered and linked, run **Discover new sensors** on the model's telemetry page first.

### Flight controller (with ExpressLRS or TBS Crossfire)

| Firmware | Flight controller | Tool |
|---|---|---|
| **Betaflight** | Battery voltage and current sensor configured. Keep `report_cell_voltage = OFF` (otherwise the cell voltage is sent instead of the pack voltage). | Nothing to change. |
| **INAV** | `feature TELEMETRY`, `feature VBAT` and `feature CURRENT_METER` enabled, current meter type not `NONE`. Keep `report_cell_voltage = OFF`. | Nothing to change. |
| **ArduPilot** | Receiver on a serial port with `SERIALx_PROTOCOL = 23` (RCIN). `BATT_MONITOR` set to a type with current sensor (e.g. `4`, analog voltage and current). | Nothing to change. |

For FrSky the flight controller settings differ, see [FrSky ACCESS only](#frsky-access-only) below.

### RC link

| Link | Flight controller | Tool |
|---|---|---|
| **ExpressLRS**, **TBS Crossfire** | Nothing extra. | Nothing to change. |
| **ImmersionRC Ghost** | Nothing extra. Betaflight only sends battery data if a voltage or current sensor is configured. | Nothing to change. |
| **FrSky ACCESS** | See [FrSky ACCESS only](#frsky-access-only) below. | **Voltage** → `VFAS`, **Capacity** → `Fuel`. **Current** stays `Curr`. |

### FrSky ACCESS only

> Only needed if you fly FrSky ACCESS. With ExpressLRS, TBS Crossfire or ImmersionRC Ghost, skip this section.

**Step 1: set the voltage sensor to `VFAS`**

With FrSky, EdgeTX creates two voltage sensors:

- `VFAS`: the flight battery, sent by the flight controller. This is the one Lipo Nanny needs.
- `RxBt`: the receiver's own supply voltage (about 5 V). With ExpressLRS the same name stands for the flight battery, that's why it is the default.

So set **Voltage** to `VFAS` in the tool. If it is left on `RxBt`, no error is shown: Lipo Nanny takes the 5 V for the battery voltage, finds no matching battery (the selection popup lists all packs) and starts at 0 %, so the critical warning fires right after takeoff.

**Step 2: set the capacity sensor and its unit**

Set **Capacity** to `Fuel`. Depending on the flight controller, `Fuel` sends consumed mAh or the remaining percent; the table shows what to set on the FC and which **Capacity unit** to pick in the tool:

| Firmware | Flight controller | Tool |
|---|---|---|
| **Betaflight** | `set bat_capacity = 0`, then `Fuel` sends consumed mAh. Alternative: keep `bat_capacity` and `set telemetry_disabled_cap_used = OFF`; then map **Capacity** → `5250` instead of `Fuel`. | Capacity unit: `mAh used` |
| **INAV** | Nothing extra (`smartport_fuel_unit` is `MAH` by default). | Capacity unit: `mAh used` |
| **ArduPilot** | ArduPilot only sends the remaining percent. `SERIALx_PROTOCOL = 4` (FrSky S.Port, not passthrough). `BATT_CAPACITY` set to **exactly** the capacity of the battery profile in mAh (for parallel packs: the sum of both). | Capacity unit: `% remaining` |
