-- =====================================================================
-- core.lua  --  Shared core for Lipo-Nanny.
-- =====================================================================
-- SD card path: /SCRIPTS/LIPONY/core.lua
--
-- Single source of truth used by BOTH scripts (must be installed alongside
-- whichever is used):
--   * the widget       /WIDGETS/LIPONY/main.lua       (display consumes this)
--   * the Tools-Script  /SCRIPTS/TOOLS/LIPONY.lua      (config editor)
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 2 as
-- published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License along
-- with this program; if not, write to the Free Software Foundation, Inc.,
-- 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
-- =====================================================================

local Core = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local STATE_WAITING   = 1
local STATE_CONNECTED = 2
local STATE_ENDED     = 3
Core.STATE_WAITING   = STATE_WAITING
Core.STATE_CONNECTED = STATE_CONNECTED
Core.STATE_ENDED     = STATE_ENDED

local CONFIG_PATH          = "/SCRIPTS/LIPONY/config.lua"
local SCHEMA_VERSION       = 1
Core.CONFIG_PATH    = CONFIG_PATH
Core.SCHEMA_VERSION = SCHEMA_VERSION

local CONFIG_POLL_INTERVAL  = 500  -- 5 s in hundredths of a second (getTime())
local ENDED_TIMEOUT         = 150   -- 1.5 s without online signal → ENDED
local ENDED_DISPLAY_TIMEOUT = 3000 -- 30 s in ENDED without reconnect → back to WAITING
local TIME_LEFT_INTERVAL    = 200  -- 2 s; how often the DISPLAYED time-left is refreshed
local SETTLE_DELAY          = 300  -- 3 s after CONNECTED before sampling resting voltage and
                                   -- latching mAh — lets stale telemetry from the last flight clear

-- Default telemetry sensor names (CRSF/ELRS standard). A model may override these
-- per the config's sensors block. The Tools-Script reads this to keep the stored
-- config sparse (only names that differ are written) and to label the picker.
local DEFAULT_SENSORS = { voltage = "RxBt", current = "Curr", capacity = "Capa", link = "RQly" }
Core.DEFAULT_SENSORS = DEFAULT_SENSORS
local DEFAULT_SENSOR_VOLTAGE  = DEFAULT_SENSORS.voltage
local DEFAULT_SENSOR_CURRENT  = DEFAULT_SENSORS.current
local DEFAULT_SENSOR_CAPACITY = DEFAULT_SENSORS.capacity
local DEFAULT_SENSOR_LINK     = DEFAULT_SENSORS.link

-- Default voice files; config.sounds.warn/.crit may override them. Missing files
-- stay silent (playFile no-ops).
local WARN_SOUND = "/SOUNDS/en/SCRIPTS/LIPONY/warn.wav"
local CRIT_SOUND = "/SOUNDS/en/SCRIPTS/LIPONY/crit.wav"

-- Optional haptic alongside the warning sounds, off by default. strength 1..3 maps to
-- a pulse length here (tune on the radio). Shared with the Tools-Script Test button.
local HAPTIC = { min = 1, max = 3, default = 2,
                 labels = { "Soft", "Normal", "Strong" }, dur = { 15, 30, 50 } }
Core.HAPTIC = HAPTIC
local HAPTIC_STRENGTH_MIN     = HAPTIC.min
local HAPTIC_STRENGTH_MAX     = HAPTIC.max
local HAPTIC_STRENGTH_DEFAULT = HAPTIC.default
local HAPTIC_DUR              = HAPTIC.dur

-- Battery chemistries. Per entry: chargeVoltage (100% SoC), dischargeVoltage
-- (0% SoC), a descending SoC curve of {v_per_cell, soc%} pairs (5% steps) used by
-- lookupNearestSoc(), and voltageWarn/voltageCrit — per-cell loaded-voltage
-- thresholds that colour the live V readout green/yellow/red.
local CHEMISTRIES = {
  LiPo = {
    chargeVoltage    = 4.20,
    dischargeVoltage = 3.00,
    voltageWarn      = 3.70,
    voltageCrit      = 3.50,
    socCurve = {
      {4.20, 100},
      {4.14,  95},
      {4.11,  90},
      {4.06,  85},
      {4.02,  80},
      {3.99,  75},
      {3.96,  70},
      {3.92,  65},
      {3.90,  60},
      {3.87,  55},
      {3.85,  50},
      {3.84,  45},
      {3.82,  40},
      {3.80,  35},
      {3.79,  30},
      {3.76,  25},
      {3.74,  20},
      {3.71,  15},
      {3.68,  10},
      {3.48,   5},
      {3.00,   0},
    },
  },
  LiPoHV = {
    chargeVoltage    = 4.35,
    dischargeVoltage = 3.00,
    voltageWarn      = 3.70,
    voltageCrit      = 3.50,
    socCurve = {
      {4.35, 100},
      {4.26,  95},
      {4.22,  90},
      {4.15,  85},
      {4.10,  80},
      {4.05,  75},
      {4.01,  70},
      {3.96,  65},
      {3.93,  60},
      {3.90,  55},
      {3.87,  50},
      {3.85,  45},
      {3.83,  40},
      {3.80,  35},
      {3.79,  30},
      {3.76,  25},
      {3.74,  20},
      {3.71,  15},
      {3.68,  10},
      {3.48,   5},
      {3.00,   0},
    },
  },
  LiIon = {
    chargeVoltage    = 4.20,
    dischargeVoltage = 2.80,
    voltageWarn      = 3.20,
    voltageCrit      = 2.90,
    socCurve = {
      {4.20, 100},
      {4.07,  95},
      {3.99,  90},
      {3.94,  85},
      {3.89,  80},
      {3.84,  75},
      {3.79,  70},
      {3.75,  65},
      {3.71,  60},
      {3.67,  55},
      {3.63,  50},
      {3.59,  45},
      {3.55,  40},
      {3.51,  35},
      {3.45,  30},
      {3.37,  25},
      {3.29,  20},
      {3.21,  15},
      {3.13,  10},
      {3.00,   5},
      {2.80,   0},
    },
  },
}
Core.CHEMISTRIES = CHEMISTRIES

-- Selectable chemistry names, in the Tools-Script dropdown order.
local CHEM_NAMES = { "LiPo", "LiPoHV", "LiIon" }
Core.CHEM_NAMES = CHEM_NAMES

-- ---------------------------------------------------------------------------
-- State of charge
-- ---------------------------------------------------------------------------

-- Nearest-neighbor lookup over the descending {voltage, soc%} curve. Values
-- outside the range map to 100% (top) / 0% (bottom), so no clamping is needed.
local function lookupNearestSoc(curve, vPerCell)
  local bestSoc  = curve[1][2]
  local bestDist = math.abs(vPerCell - curve[1][1])
  for i = 2, #curve do
    local d = math.abs(vPerCell - curve[i][1])
    if d < bestDist then
      bestDist = d
      bestSoc  = curve[i][2]
    end
  end
  return bestSoc
end

-- Convenience: pack voltage / cells and look up in the chemistry-specific curve.
local function socFromVoltage(chemistry, voltage, cells)
  if not chemistry or not voltage or not cells or cells <= 0 then
    return nil
  end
  return lookupNearestSoc(chemistry.socCurve, voltage / cells)
end

-- ---------------------------------------------------------------------------
-- Config persistence (serialize + file IO + load/save), shared with the tool
-- ---------------------------------------------------------------------------

-- Quotes a string as a Lua literal, escaping the few characters that matter
-- (backslash before the others so it isn't double-escaped).
local function quoteString(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "\n", "\\n")
  return '"' .. s .. '"'
end

-- Serializes a Lua value back into source text. Handles the array part (ipairs)
-- and the remaining hash part with string/number keys. Functions/userdata are not
-- expected.
local function serialize(value, indent)
  local t = type(value)
  if t == "number" or t == "boolean" then
    return tostring(value)
  elseif t == "string" then
    return quoteString(value)
  elseif t == "table" then
    local nextIndent = indent .. "  "
    local parts      = {}
    local arrayLen   = #value
    for i = 1, arrayLen do
      parts[#parts + 1] = nextIndent .. serialize(value[i], nextIndent)
    end
    for k, v in pairs(value) do
      local isArrayIndex = type(k) == "number" and k >= 1 and k <= arrayLen
                           and math.floor(k) == k
      if not isArrayIndex then
        local keyStr
        if type(k) == "string" then
          keyStr = "[" .. quoteString(k) .. "]"
        else
          keyStr = "[" .. tostring(k) .. "]"
        end
        parts[#parts + 1] = nextIndent .. keyStr .. " = " .. serialize(v, nextIndent)
      end
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
  end
  return "nil"
end

-- Reads a whole file (block reads; "a" format is not on every build), or nil.
local function readFile(path)
  local ok, f = pcall(io.open, path, "r")
  if not ok or not f then return nil end
  local parts = {}
  while true do
    local rok, chunk = pcall(io.read, f, 4096)
    if not rok or not chunk or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  pcall(io.close, f)
  return table.concat(parts)
end

-- Writes content to path, true on success. I/O is pcall-wrapped so a full/read-only
-- SD never raises. io.open "w" does NOT truncate on some EdgeTX/SD builds, so a
-- shorter write would leave the old tail behind — pad with trailing newlines (valid
-- after the table) up to the old length.
local function writeFile(path, content)
  local old = readFile(path)
  if old and #old > #content then
    content = content .. string.rep("\n", #old - #content)
  end
  local ok, f = pcall(io.open, path, "w")
  if not ok or not f then return false end
  local wok = pcall(io.write, f, content)
  pcall(io.close, f)
  return wok == true
end

-- Loads and validates the config file. Returns (configTable) on success, or
-- (nil, errKind[, detail]) where errKind is "missing" | "parse" | "schema".
-- The widget ignores `detail`; the Tools-Script surfaces it on the error screen.
local function loadConfig()
  local ok, f = pcall(io.open, CONFIG_PATH, "r")
  if not ok or not f then return nil, "missing" end
  pcall(io.close, f)

  local pok, result = pcall(dofile, CONFIG_PATH)
  if not pok then return nil, "parse", tostring(result) end
  if type(result) ~= "table" then return nil, "parse", "not a table" end
  if result.schemaVersion ~= SCHEMA_VERSION then
    return nil, "schema", tostring(result.schemaVersion)
  end
  if type(result.generation) ~= "number" then
    return nil, "schema", "generation"
  end
  result.archive = result.archive or {}
  result.sounds  = result.sounds or {}
  return result
end

-- Increments the reload sentinel and writes the whole config back. The generation
-- bump makes a running widget pick up the change on its next poll. Returns true on
-- success.
local function saveConfig(config)
  config.generation = (config.generation or 0) + 1
  local content = "-- Lipo-Nanny configuration (auto-generated by the Tools-Script).\n"
                  .. "return " .. serialize(config, "") .. "\n"
  return writeFile(CONFIG_PATH, content)
end

-- Factory defaults. Returns a FRESH table on every call (no shared references and
-- no overlay of a loaded config), so "Reset to defaults" always restores the true
-- factory values rather than echoing whatever is currently saved.
local function defaultConfig()
  return {
    schemaVersion = SCHEMA_VERSION,
    generation    = 0,
    nextPackId    = 1,
    defaults      = { warn_pct = 30, crit_pct = 20 },
    batteries     = {},
    archive       = {},
    sounds        = {},
    models        = {},
  }
end

-- ---------------------------------------------------------------------------
-- Telemetry + per-model config
-- ---------------------------------------------------------------------------

-- Defensive wrappers for the firmware calls: keep one bad sensor or a malformed
-- model.getInfo from tanking the whole cycle.
local function safeGetValue(name)
  local ok, v = pcall(getValue, name)
  if ok and type(v) == "number" then return v end
  return 0
end

-- getValue returns 0 both for a missing sensor and a genuine zero, so existence
-- needs getFieldInfo (nil when the sensor is not configured in the model).
local function sensorExists(name)
  local ok, info = pcall(getFieldInfo, name)
  return ok and info ~= nil
end

local function modelFilename()
  local ok, info = pcall(model.getInfo)
  if ok and type(info) == "table" then return info.filename end
  return nil
end

-- Human-readable name of the ACTIVE model (as shown in EdgeTX's model list) for
-- display only; the config is still keyed by filename. Falls back to nil when
-- unavailable.
local function activeModelName()
  local ok, info = pcall(model.getInfo)
  if ok and type(info) == "table" and info.name and info.name ~= "" then
    return info.name
  end
  return nil
end

-- Records which telemetry sensors the model actually has, so the widget can show a
-- clear "Sensor missing" hint instead of computing on absent values. Setup changes
-- rarely, so re-checked at the config-poll cadence (first tick checks immediately:
-- lastSensorCheck starts at 0).
local function checkSensors(ctx)
  local now = getTime()
  if ctx.lastSensorCheck ~= 0 and (now - ctx.lastSensorCheck) < CONFIG_POLL_INTERVAL then
    return
  end
  ctx.lastSensorCheck = now
  ctx.hasRxBt = sensorExists(ctx.sensorVoltage)
  ctx.hasCurr = sensorExists(ctx.sensorCurrent)
  ctx.hasCapa = sensorExists(ctx.sensorCapacity)
end

-- Reads the four sensors, applies plausibility filters and keeps the last valid
-- value on ctx (invalid samples dropped). Voltage validation needs ctx.cells;
-- rawVoltage is always kept for the online fallback.
local function readTelemetry(ctx)
  local v = safeGetValue(ctx.sensorVoltage)
  local i = safeGetValue(ctx.sensorCurrent)
  local q = safeGetValue(ctx.sensorCapacity)
  local l = safeGetValue(ctx.sensorLink)

  ctx.linkQuality = l
  ctx.rawVoltage  = v

  -- FC on USB (no battery): link live but voltage, current and capacity all zero.
  -- All three never glitch to zero at once, so no debounce is needed.
  ctx.noBatterySignal = l > 0 and v == 0 and i == 0 and q == 0

  -- Voltage: [0.5 V × cells … 5 V × cells]
  local cells = ctx.cells
  if cells and v >= 0.5 * cells and v <= 5 * cells then
    ctx.voltage = v
  end

  -- Current: ≥ 0, and only when the sensor exists (else leave nil → "—.- A").
  if ctx.hasCurr and i >= 0 then
    ctx.current = i
  end

  -- Capacity (consumed mAh). After a dropout EdgeTX still reports the previous
  -- flight's high Capa until the new RX sends a fresh (zeroed) frame, so only start
  -- latching after the SETTLE_DELAY window — by then the stale value is gone. Then
  -- monotonic up only.
  if q >= 0 and ctx.state == STATE_CONNECTED
     and (getTime() - ctx.connectedSinceTime) >= SETTLE_DELAY
     and (ctx.capacity == nil or q >= ctx.capacity) then
    ctx.capacity = q
  end
end

-- Loads the active model's per-model config (cells, parallel) onto ctx. Sets
-- ctx.modelError ("missing" / "no_batteries") for the error tiles.
local function syncModelConfig(ctx)
  ctx.cells       = nil
  ctx.parallel    = false
  ctx.modelError  = nil

  -- Sensor names default to the CRSF standard; a per-model sensors block overrides
  -- individual ones below. Set unconditionally so they are valid even without config.
  ctx.sensorVoltage  = DEFAULT_SENSOR_VOLTAGE
  ctx.sensorCurrent  = DEFAULT_SENSOR_CURRENT
  ctx.sensorCapacity = DEFAULT_SENSOR_CAPACITY
  ctx.sensorLink     = DEFAULT_SENSOR_LINK

  if not ctx.config or not ctx.config.models then return end
  local filename = modelFilename()
  local modelCfg = filename and ctx.config.models[filename]
  if not modelCfg then
    ctx.modelError = "missing"
    return
  end
  ctx.cells       = modelCfg.cells
  ctx.parallel    = modelCfg.parallel == true
  local s = modelCfg.sensors
  if s then
    if s.voltage  and s.voltage  ~= "" then ctx.sensorVoltage  = s.voltage  end
    if s.current  and s.current  ~= "" then ctx.sensorCurrent  = s.current  end
    if s.capacity and s.capacity ~= "" then ctx.sensorCapacity = s.capacity end
    if s.link     and s.link     ~= "" then ctx.sensorLink     = s.link     end
  end
  if not modelCfg.batteryIds or #modelCfg.batteryIds == 0 then
    ctx.modelError = "no_batteries"
  end
end

-- Polls the config file once per CONFIG_POLL_INTERVAL. Updates ctx.config only
-- when the generation sentinel changes. Always re-syncs the per-
-- model state in case the EdgeTX-side model selection changed.
local function pollConfig(ctx)
  local now = getTime()
  if ctx.lastConfigPoll ~= 0 and (now - ctx.lastConfigPoll) < CONFIG_POLL_INTERVAL then
    return
  end
  ctx.lastConfigPoll = now

  local config, err = loadConfig()
  if err then
    ctx.config = nil
    ctx.lastGeneration = nil
    ctx.configError = err
    syncModelConfig(ctx)
    return
  end

  ctx.configError = nil
  if ctx.lastGeneration ~= config.generation then
    -- Cycle counts live in the config, so adopting the new config also refreshes
    -- them — a tool-side "Reset statistics" bumps the generation and is picked up
    -- here without any separate stats reload.
    ctx.config = config
    ctx.lastGeneration = config.generation
  end
  syncModelConfig(ctx)
end

-- Online detection: primary RQly > 0, fallback RxBt > 0 (used when
-- the RQly sensor is not configured — getValue returns 0 in that case).
local function isOnline(ctx)
  return ctx.linkQuality > 0 or ctx.rawVoltage > 0
end

-- Settle window elapsed, link live, but no battery ever reported → FC on USB.
-- Self-correcting: once a real pack reports, restVoltage is set and this is false.
local function isUsbConnected(ctx)
  return ctx.state == STATE_CONNECTED
         and ctx.restVoltage == nil
         and ctx.noBatterySignal
         and (getTime() - ctx.connectedSinceTime) >= SETTLE_DELAY
end

-- Resets per-flight state on a (re-)connect. voltage is cleared so a stale reading
-- can't seed restVoltage (phantom battery on USB); current isn't — zero is valid
-- and readTelemetry refreshes it every tick.
local function resetFlightState(ctx)
  ctx.voltage             = nil
  ctx.capacity            = nil
  ctx.warnPlayed          = false
  ctx.critPlayed          = false
  ctx.currentSumA         = 0
  ctx.currentSampleCount  = 0
  ctx.timeLeftStr         = nil   -- recompute the displayed time-left promptly
  ctx.timeLeftStamp       = nil
  ctx.restVoltage         = nil
  ctx.minVCell            = nil   -- lowest per-cell voltage seen this flight (statistics)
  ctx.startSoc            = nil
  ctx.startOffsetMah      = nil
  ctx.selectedProfile     = nil
  ctx.selectedInstances   = nil
  ctx.pendingSelection    = nil
  ctx.popupCursor         = nil
  ctx.popupSlot           = 1
  ctx.slot1Item           = nil
  ctx.stickArmed          = true
  ctx.confirmArmed        = false
  ctx.confirmSince        = nil
  ctx.cellMismatch        = false
end

-- Snapshot of the just-ended flight for the ENDED tile. Stores raw values;
-- effectiveCap sums the selected packs' wear-reduced capacities (covers parallel).
local function captureFlightSummary(ctx)
  local profile = ctx.selectedProfile
  local effectiveCap
  if profile and profile.capacityMah and ctx.selectedInstances then
    effectiveCap = 0
    for _, inst in ipairs(ctx.selectedInstances) do
      effectiveCap = effectiveCap + profile.capacityMah * (1 - (inst.wear or 0) / 100)
    end
  end
  ctx.lastFlight = {
    profileName        = profile and profile.name or nil,
    instances          = ctx.selectedInstances,
    usedMah            = ctx.capacity or 0,
    effectiveCap       = effectiveCap,
    startOffsetMah     = ctx.startOffsetMah,
    lastVoltagePerCell = (ctx.voltage and ctx.cells and ctx.cells > 0)
                         and (ctx.voltage / ctx.cells) or nil,
  }
end

-- ---------------------------------------------------------------------------
-- Cycle-counter write-back
-- ---------------------------------------------------------------------------

-- Cycle count for one physical battery, keyed by its stable pack id (0 if none).
-- Scans the loaded config, where the cycle count lives on each instance.
local function cyclesFor(ctx, packId)
  if not packId or not ctx.config then return 0 end
  for _, b in ipairs(ctx.config.batteries or {}) do
    for _, inst in ipairs(b.instances or {}) do
      if inst.id == packId then return inst.cycles or 0 end
    end
  end
  return 0
end

-- Flushes pending cycle bumps at flight end via read-modify-write: re-read fresh so
-- concurrent tool edits survive, add each bump onto its instance, write back. A bad
-- read or failed write keeps the bumps pending; a bump for a vanished pack is dropped.
local function flushCycles(ctx)
  if not next(ctx.pendingBumps) and not next(ctx.pendingStats) then return end
  local fresh = loadConfig()
  if not fresh then return end   -- missing/parse/schema: leave the file + bumps alone
  for _, b in ipairs(fresh.batteries or {}) do
    for _, inst in ipairs(b.instances or {}) do
      local n = ctx.pendingBumps[inst.id]
      if n then inst.cycles = (inst.cycles or 0) + n end
      local st = ctx.pendingStats[inst.id]
      if st then
        if st.mah then inst.totalMah = (inst.totalMah or 0) + math.floor(st.mah + 0.5) end
        if st.lastUsed then inst.lastUsed = st.lastUsed end
        if st.minVCell and (not inst.minVCell or st.minVCell < inst.minVCell) then
          inst.minVCell = st.minVCell
        end
      end
    end
  end
  if saveConfig(fresh) then
    ctx.config         = fresh            -- refresh the read cache (incl. bumped cycles)
    ctx.lastGeneration = fresh.generation -- our own write; don't re-adopt it next poll
    ctx.pendingBumps   = {}
    ctx.pendingStats   = {}
  end
end

-- Called once at the CONNECTED→ENDED transition: records a +1 cycle bump for each
-- used pack that drew more than 10% of its capacity this flight (parallel splits the
-- consumption evenly), records the per-pack statistics (consumed mAh, last-used date,
-- lowest cell voltage), then flushes everything to config.lua.
local function finalizeFlight(ctx)
  local profile   = ctx.selectedProfile
  local instances = ctx.selectedInstances
  if profile and profile.capacityMah and instances and #instances > 0 then
    -- The consumed mAh is split evenly across the used packs (50/50 in parallel).
    local perBattery = (ctx.capacity or 0) / #instances
    local dt   = getDateTime()
    local date = string.format("%04d-%02d-%02d", dt.year, dt.mon, dt.day)
    for _, inst in ipairs(instances) do
      if inst.id then
        local effCap = profile.capacityMah * (1 - (inst.wear or 0) / 100)
        -- Cycle: only when the pack drew more than 10% of ITS effective capacity.
        if effCap > 0 and perBattery > 0.10 * effCap then
          ctx.pendingBumps[inst.id] = (ctx.pendingBumps[inst.id] or 0) + 1
        end
        -- Statistics: recorded for every used pack, independent of the cycle threshold.
        local st = ctx.pendingStats[inst.id] or {}
        st.mah      = (st.mah or 0) + perBattery
        st.lastUsed = date
        if ctx.minVCell and (not st.minVCell or ctx.minVCell < st.minVCell) then
          st.minVCell = ctx.minVCell
        end
        ctx.pendingStats[inst.id] = st
      end
    end
  end
  flushCycles(ctx)
end

-- ---------------------------------------------------------------------------
-- Flight state machine
-- ---------------------------------------------------------------------------

-- Drives the WAITING/CONNECTED/ENDED state machine. Must run after
-- readTelemetry so that link-status / rawVoltage reflect the latest sample.
local function updateStateMachine(ctx)
  local now = getTime()
  local online = isOnline(ctx)

  if ctx.state == STATE_WAITING then
    if online then
      ctx.state              = STATE_CONNECTED
      ctx.connectedSinceTime = now
      ctx.lastTelemetryTime  = now
      resetFlightState(ctx)
    end

  elseif ctx.state == STATE_CONNECTED then
    if online then
      ctx.lastTelemetryTime = now
      -- Resting voltage: captured once, SETTLE_DELAY after connect, so the reading
      -- is taken at idle rather than under load. Basis for battery detection.
      if ctx.restVoltage == nil and ctx.voltage
         and (now - ctx.connectedSinceTime) >= SETTLE_DELAY then
        ctx.restVoltage = ctx.voltage
      end
      -- Average-current accumulator for time-left: one validated-current
      -- sample per tick (10 Hz).
      if ctx.current and ctx.current > 0 then
        ctx.currentSumA        = ctx.currentSumA + ctx.current
        ctx.currentSampleCount = ctx.currentSampleCount + 1
      end
      -- Lowest per-cell voltage this flight (statistics): tracked under load.
      if ctx.voltage and ctx.cells and ctx.cells > 0 then
        local vCell = ctx.voltage / ctx.cells
        if not ctx.minVCell or vCell < ctx.minVCell then ctx.minVCell = vCell end
      end
    elseif (now - ctx.lastTelemetryTime) >= ENDED_TIMEOUT then
      if ctx.selectedProfile then
        captureFlightSummary(ctx)
        finalizeFlight(ctx)   -- cycle-counter evaluation + statistics write
        ctx.state     = STATE_ENDED
        ctx.endedTime = now
      else
        -- Telemetry lost before a battery was chosen (settle window or selection
        -- popup still open) → no flight happened, so clear the popup and go back to
        -- idle instead of showing "Flight ended".
        resetFlightState(ctx)
        ctx.state = STATE_WAITING
      end
    end

  elseif ctx.state == STATE_ENDED then
    if online then
      -- Battery change (lost link, then reconnect).
      ctx.state              = STATE_CONNECTED
      ctx.connectedSinceTime = now
      ctx.lastTelemetryTime  = now
      resetFlightState(ctx)
    elseif (now - ctx.endedTime) >= ENDED_DISPLAY_TIMEOUT then
      -- Flight-summary shown long enough with no reconnect → idle again.
      ctx.state = STATE_WAITING
    end
  end
end

-- ---------------------------------------------------------------------------
-- Derived metrics (thresholds, remaining %, remaining time)
-- ---------------------------------------------------------------------------

-- Returns (warn_pct, crit_pct). Profile overrides win over the global defaults.
-- Sane fallbacks when no config is loaded so the widget still renders something
-- during bootstrap.
local function getThresholds(ctx)
  local profile  = ctx.selectedProfile or {}
  local defaults = (ctx.config and ctx.config.defaults) or {}
  local warn = profile.warn_pct or defaults.warn_pct or 30
  local crit = profile.crit_pct or defaults.crit_pct or 20
  return warn, crit
end

-- Effective total capacity in mAh: sum over the selected packs of
-- profile.capacityMah × (1 − wear/100). Wear shrinks the usable capacity so the
-- percentage and warnings track the aged battery; parallel naturally sums two
-- packs (each with its own wear).
local function effectiveCapacityMah(ctx)
  local profile = ctx.selectedProfile
  local insts   = ctx.selectedInstances
  if not profile or not profile.capacityMah or not insts or #insts == 0 then return nil end
  local total = 0
  for _, inst in ipairs(insts) do
    total = total + profile.capacityMah * (1 - (inst.wear or 0) / 100)
  end
  return total
end

-- Remaining capacity in percent (0..100), or nil if uncalculable.
-- rest_mAh = effective_capacity - (Capa + start_offset).
local function calculateRestPct(ctx)
  local effective = effectiveCapacityMah(ctx)
  if not effective or effective <= 0 then return nil end
  if ctx.capacity == nil or ctx.startOffsetMah == nil then return nil end
  local used = ctx.capacity + ctx.startOffsetMah
  local pct = (effective - used) / effective * 100
  if pct < 0   then pct = 0   end
  if pct > 100 then pct = 100 end
  return pct
end

-- Remaining flight time in seconds, or nil if not yet computable. Counts down to
-- the CRIT threshold (not 0%): you should land by then so the pack is never deep-
-- discharged, so the usable reserve is the charge ABOVE crit%. Returns 0 once at
-- or below crit ("land now"). Pure data; warmup gating happens in formatTimeLeft.
local function calculateTimeLeftSeconds(ctx)
  if ctx.currentSampleCount == 0 then return nil end
  local avgCurrent = ctx.currentSumA / ctx.currentSampleCount
  if avgCurrent <= 0 then return nil end
  local restPct = calculateRestPct(ctx)
  if not restPct then return nil end
  local effective = effectiveCapacityMah(ctx)
  if not effective then return nil end
  local _, crit  = getThresholds(ctx)
  local usablePct = restPct - crit
  if usablePct <= 0 then return 0 end           -- at/below crit → land now
  local restMah = effective * usablePct / 100
  return restMah / 1000 / avgCurrent * 3600  -- mAh → Ah → h → s
end

-- "calc.." during the first 60 s after CONNECTED, "--:--" when the value is
-- permanently uncalculable (e.g. Curr sensor missing), otherwise "mm:ss".
local function formatTimeLeft(ctx)
  if not ctx.hasCurr then return "--:--" end   -- no current sensor → not computable
  local elapsedS = (getTime() - ctx.connectedSinceTime) / 100
  if elapsedS < 60 then return "calc.." end
  local secs = calculateTimeLeftSeconds(ctx)
  if not secs then return "--:--" end
  local m = math.floor(secs / 60)
  local s = math.floor(secs % 60)
  if m > 99 then m = 99 end
  return string.format("%02d:%02d", m, s)
end

-- Refreshes the DISPLAYED time-left string at most every TIME_LEFT_INTERVAL (2 s).
-- The current average keeps accumulating every tick; this only throttles how often
-- it's snapshotted, so the mm:ss doesn't twitch on a momentary blip.
local function refreshTimeLeft(ctx)
  local now = getTime()
  if not ctx.timeLeftStr or (now - (ctx.timeLeftStamp or 0)) >= TIME_LEFT_INTERVAL then
    ctx.timeLeftStr   = formatTimeLeft(ctx)
    ctx.timeLeftStamp = now
  end
end

-- ---------------------------------------------------------------------------
-- Battery detection + selection
-- ---------------------------------------------------------------------------

-- Finds the model's profile by id within the global battery library.
local function findProfileById(ctx, id)
  for _, b in ipairs(ctx.config and ctx.config.batteries or {}) do
    if b.id == id then return b end
  end
  return nil
end

-- Plausible physical-battery candidates for the current resting voltage.
-- Returns a list of { profile = <profile>, pos = <n>, packId = <stable id> },
-- empty until the resting voltage has been captured. A profile is plausible when
-- its cell count matches the model and the resting voltage falls within the
-- chemistry range (+0.05 V/cell headroom on top). Each plausible profile expands
-- into one candidate per instance (pos = display index, packId = statistics key).
local function findCandidates(ctx)
  local out = {}
  if not ctx.restVoltage or not ctx.cells or not ctx.config then
    return out
  end
  local filename = modelFilename()
  local modelCfg = filename and ctx.config.models and ctx.config.models[filename]
  if not modelCfg or not modelCfg.batteryIds then
    return out
  end

  for _, id in ipairs(modelCfg.batteryIds) do
    local profile = findProfileById(ctx, id)
    local chem    = profile and CHEMISTRIES[profile.chemistry]
    if profile and chem and profile.cells == ctx.cells then
      local vMin = chem.dischargeVoltage * ctx.cells
      local vMax = (chem.chargeVoltage + 0.05) * ctx.cells
      if ctx.restVoltage >= vMin and ctx.restVoltage <= vMax then
        for _, inst in ipairs(profile.instances or {}) do
          out[#out + 1] = { profile = profile, pos = inst.label,
                            packId = inst.id, wear = inst.wear or 0,
                            cycles = inst.cycles or 0 }
        end
      end
    end
  end
  return out
end

-- Commits a battery selection: records the profile + instance numbers and
-- derives the start SoC from the resting voltage and the start mAh offset.
-- Shared by auto-select and the selection popup.
local function applySelection(ctx, profile, instances)
  ctx.selectedProfile   = profile
  ctx.selectedInstances = instances

  local soc  = 100
  local chem = CHEMISTRIES[profile.chemistry]
  if chem and ctx.restVoltage then
    local fromV = socFromVoltage(chem, ctx.restVoltage, ctx.cells)
    if fromV then soc = fromV end
  end
  -- startSoc is a write-only intermediate: production code consumes only the derived
  -- startOffsetMah below. It is kept solely as an observable the SoC-lookup tests assert on.
  ctx.startSoc       = soc
  -- Offset spans the whole (effective) pack capacity, so it covers both packs in
  -- parallel and shrinks with wear — consistent with effectiveCapacityMah.
  local effective    = effectiveCapacityMah(ctx) or 0
  ctx.startOffsetMah = (100 - soc) / 100 * effective

  -- Suppress the early warning if the pack is already below the warn threshold
  -- at connect (the pilot knowingly plugged in a part-used pack). The critical
  -- warning stays armed.
  local warn = getThresholds(ctx)
  ctx.warnPlayed = soc <= warn
  ctx.critPlayed = false
end

-- True if the model has at least one assigned profile of its cell count.
-- When false there is nothing to select → the cell-count-mismatch tile.
local function hasMatchingCellProfile(ctx)
  local filename = modelFilename()
  local modelCfg = ctx.config and ctx.config.models and filename and ctx.config.models[filename]
  if not modelCfg or not modelCfg.batteryIds then return false end
  for _, id in ipairs(modelCfg.batteryIds) do
    local p = findProfileById(ctx, id)
    if p and p.cells == ctx.cells then return true end
  end
  return false
end

-- Battery detection at connect. Runs once the resting voltage is available and
-- nothing is selected/pending yet:
--   single:   1 candidate → auto-select; 0 or >1 → popup
--   parallel: always a 2-slot popup (every assignable profile has two or more
--             packs, so the slot-1 profile always has a second pack for slot 2);
--             per-slot auto-select happens while the popup is open.
-- No assigned profile of the model's cell count → cell-count-mismatch tile.
local function detectBattery(ctx)
  if ctx.selectedProfile then return end   -- already chosen
  if ctx.pendingSelection then return end  -- waiting for popup
  if not ctx.restVoltage then return end   -- wait for the idle reading

  if not hasMatchingCellProfile(ctx) then
    ctx.cellMismatch = true
    return
  end
  ctx.cellMismatch = false

  local candidates = findCandidates(ctx)
  if ctx.parallel then
    ctx.pendingSelection = candidates      -- empty → popup falls back to all instances
    ctx.popupSlot = 1
    ctx.slot1Item = nil
  elseif #candidates == 1 then
    applySelection(ctx, candidates[1].profile,
                   { { pos = candidates[1].pos, id = candidates[1].packId,
                       wear = candidates[1].wear } })
  else
    ctx.pendingSelection = candidates
  end
end

-- ---------------------------------------------------------------------------
-- Warnings
-- ---------------------------------------------------------------------------

-- Vibrate with a warning: pulses=1 normal, 2 = stronger critical cue. No-op when haptic
-- is off or playHaptic is absent (sim / motorless radio), so it never affects the logic.
local function warnHaptic(ctx, pulses)
  local cfg = ctx.config
  if not cfg or cfg.haptic ~= true or not playHaptic then return end
  local s = cfg.hapticStrength
  if type(s) ~= "number" then s = HAPTIC_STRENGTH_DEFAULT end
  if s < HAPTIC_STRENGTH_MIN then s = HAPTIC_STRENGTH_MIN
  elseif s > HAPTIC_STRENGTH_MAX then s = HAPTIC_STRENGTH_MAX end
  local dur = HAPTIC_DUR[s] or HAPTIC_DUR[HAPTIC_STRENGTH_DEFAULT]
  for i = 1, pulses do
    playHaptic(dur, (i < pulses) and dur or 0)   -- gap between pulses, none after the last
  end
end

-- Plays the warn / crit voice file once each as the remaining percentage drops
-- past the thresholds. No debounce: the mAh counter only rises, so each
-- threshold is crossed exactly once per flight.
local function evaluateWarnings(ctx)
  if not ctx.selectedProfile then return end
  local restPct = calculateRestPct(ctx)
  if not restPct then return end

  local sounds = (ctx.config and ctx.config.sounds) or {}
  local warn, crit = getThresholds(ctx)
  if not ctx.warnPlayed and restPct <= warn then
    ctx.warnPlayed = true
    playFile(sounds.warn or WARN_SOUND)
    warnHaptic(ctx, 1)
  end
  if not ctx.critPlayed and restPct <= crit then
    ctx.critPlayed = true
    playFile(sounds.crit or CRIT_SOUND)
    warnHaptic(ctx, 2)
  end
end

-- Every instance of each model-assigned profile of the model's cell count,
-- regardless of voltage plausibility. Used for the popup when
-- nothing matched the resting voltage, so the pilot can still pick from all
-- profiles.
local function allModelInstances(ctx)
  local out = {}
  if not ctx.config then return out end
  local filename = modelFilename()
  local modelCfg = filename and ctx.config.models and ctx.config.models[filename]
  if not modelCfg or not modelCfg.batteryIds then return out end
  for _, id in ipairs(modelCfg.batteryIds) do
    local profile = findProfileById(ctx, id)
    if profile and profile.cells == ctx.cells then
      for _, inst in ipairs(profile.instances or {}) do
        out[#out + 1] = { profile = profile, pos = inst.label,
                          packId = inst.id, wear = inst.wear or 0,
                          cycles = inst.cycles or 0 }
      end
    end
  end
  return out
end

-- The list shown in the selection popup: the plausible candidates when there are
-- several, otherwise (0 candidates) every assigned instance.
local function selectionList(ctx)
  if ctx.pendingSelection and #ctx.pendingSelection > 0 then
    return ctx.pendingSelection
  end
  return allModelInstances(ctx)
end

-- The candidate list for the slot currently being chosen. Single mode and
-- parallel slot 1 show every candidate; parallel slot 2 shows the remaining
-- instances of the profile picked for slot 1 (identical profile, distinct #N).
local function activeSelectionList(ctx)
  local base = selectionList(ctx)
  if not ctx.parallel or ctx.popupSlot ~= 2 or not ctx.slot1Item then
    return base
  end
  local s1  = ctx.slot1Item
  local out = {}
  for _, item in ipairs(base) do
    if item.profile.id == s1.profile.id and item.packId ~= s1.packId then
      out[#out + 1] = item
    end
  end
  return out
end

-- Commits the highlighted entry for the active slot. In parallel, slot 1 only
-- records the pick and advances to slot 2; slot 2 (or single mode) finalises the
-- selection and closes the popup.
local function commitSlot(ctx, pick)
  if ctx.parallel and ctx.popupSlot == 1 then
    ctx.slot1Item    = pick
    ctx.popupSlot    = 2
    ctx.popupCursor  = 1
    ctx.confirmArmed = false        -- must release before confirming slot 2
    return
  end
  local instances
  if ctx.parallel and ctx.slot1Item then
    instances = { { pos = ctx.slot1Item.pos, id = ctx.slot1Item.packId, wear = ctx.slot1Item.wear },
                  { pos = pick.pos, id = pick.packId, wear = pick.wear } }
  else
    instances = { { pos = pick.pos, id = pick.packId, wear = pick.wear } }
  end
  applySelection(ctx, pick.profile, instances)
  ctx.pendingSelection = nil
  ctx.popupCursor      = nil
  ctx.popupSlot        = 1
  ctx.slot1Item        = nil
end

-- Per-slot auto-select: if the active slot has exactly one candidate, take it
-- without a gesture — e.g. the single remaining instance for slot 2 when the
-- profile has two instances. Returns true when it committed.
local function autoSelectSlot(ctx)
  local list = activeSelectionList(ctx)
  if #list == 1 then
    commitSlot(ctx, list[1])
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Context factory
-- ---------------------------------------------------------------------------

-- Fresh logic context (everything the state machine / telemetry / selection
-- touch). The widget adds its own display/lifecycle fields (zone, cfg, lastTick,
-- errorStreak, fatalError) on top and calls pollConfig() once after create.
local function newContext()
  return {
    -- State machine
    state = STATE_WAITING,
    lastTelemetryTime = 0,
    connectedSinceTime = 0,
    endedTime = 0,

    -- Config + reload polling
    config = nil,
    configError = nil,
    lastGeneration = nil,
    lastConfigPoll = 0,

    -- Cycle counts live on the config instances. pendingBumps holds cycles earned
    -- this session but not yet written (survives failed writes for a later retry);
    -- pendingStats holds per-pack statistic deltas earned alongside the cycle.
    pendingBumps = {},
    pendingStats = {},

    -- Telemetry — last valid values. rawVoltage = latest unvalidated RxBt,
    -- used as online fallback when RQly is missing.
    voltage     = nil,
    rawVoltage  = 0,
    current     = nil,
    capacity    = nil,
    linkQuality = 0,
    noBatterySignal = false,

    -- Sensor existence (assume present until checkSensors proves otherwise, so
    -- the first frame doesn't flash "Sensor missing").
    hasRxBt = true,
    hasCurr = true,
    hasCapa = true,
    lastSensorCheck = 0,

    cellMismatch = false,

    -- Selected battery / battery profile
    selectedProfile = nil,
    selectedInstances = nil,
    pendingSelection = nil,
    popupCursor = nil,
    popupSlot = 1,
    slot1Item = nil,
    stickArmed = true,
    confirmArmed = false,
    confirmSince = nil,
    cells = nil,
    restVoltage = nil,
    startSoc = nil,
    startOffsetMah = nil,
    parallel = false,

    -- Warning trigger flags
    warnPlayed = false,
    critPlayed = false,

    -- Time-left averaging
    currentSumA = 0,
    currentSampleCount = 0,

    -- Last flight summary for ENDED display
    lastFlight = nil,
  }
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
-- Only the members another script (widget / Tools-Script) or a test actually
-- calls are exported. The remaining helpers (safeGetValue, findCandidates,
-- serialize's quoteString, …) stay local: they are reached through the functions
-- below, so exposing them would just be unused surface.

-- Config persistence (Tools-Script + widget cycle write-back)
Core.serialize            = serialize
Core.loadConfig           = loadConfig
Core.saveConfig           = saveConfig
Core.defaultConfig        = defaultConfig

-- Derived values used by the widget's display
Core.socFromVoltage       = socFromVoltage
Core.getThresholds        = getThresholds
Core.effectiveCapacityMah = effectiveCapacityMah
Core.calculateRestPct     = calculateRestPct
Core.formatTimeLeft       = formatTimeLeft
Core.refreshTimeLeft      = refreshTimeLeft
Core.cyclesFor            = cyclesFor
Core.modelFilename        = modelFilename
Core.activeModelName      = activeModelName

-- Per-tick pipeline the widget drives
Core.pollConfig           = pollConfig
Core.checkSensors         = checkSensors
Core.readTelemetry        = readTelemetry
Core.updateStateMachine   = updateStateMachine
Core.detectBattery        = detectBattery
Core.evaluateWarnings     = evaluateWarnings
Core.finalizeFlight       = finalizeFlight

-- Link status + selection helpers the widget's tiles / stick input consult
Core.isOnline             = isOnline
Core.isUsbConnected       = isUsbConnected
Core.activeSelectionList  = activeSelectionList
Core.commitSlot           = commitSlot
Core.autoSelectSlot       = autoSelectSlot

Core.newContext           = newContext

return Core
