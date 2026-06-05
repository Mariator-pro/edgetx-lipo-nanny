-- =====================================================================
-- main.lua  --  EdgeTX Telemetry Widget for Lipo-Nanny battery monitoring
-- =====================================================================
-- SD card path: /WIDGETS/LIPONY/main.lua
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

local STATE_WAITING   = 1
local STATE_CONNECTED = 2
local STATE_ENDED     = 3

local CONFIG_PATH          = "/SCRIPTS/LIPONY/config.lua"
local SCHEMA_VERSION       = 1
local CONFIG_POLL_INTERVAL = 500  -- 5 s in hundredths of a second (getTime())
local ENDED_TIMEOUT        = 500   -- 5 s without online signal → ENDED
local ENDED_DISPLAY_TIMEOUT = 3000 -- 30 s in ENDED without reconnect → back to WAITING
local TICK_INTERVAL        = 10   -- 0.1 s; data-processing cadence (10 Hz)
local TIME_LEFT_INTERVAL   = 200  -- 2 s; how often the DISPLAYED time-left is refreshed
local SETTLE_DELAY         = 300  -- 3 s after CONNECTED before sampling the resting voltage
                                  -- AND before latching consumed mAh — long enough for
                                  -- stale telemetry from the previous flight to clear
local ERROR_LIMIT          = 5    -- consecutive tick failures before the widget gives up

-- Stick-gesture thresholds for the selection popup (getValue range -1024..+1024).
local STICK_STEP        = 500  -- deflection that counts as one cursor step
local STICK_DEADZONE    = 200  -- back inside this re-arms the next step (edge detection)
local CONFIRM_THRESHOLD = 700  -- aileron deflection (full right) that means "confirm"
local CONFIRM_HOLD      = 50   -- 0.5 s hold (hundredths of a second) before commit

-- Display scaling: pixel constants are relative to a 480 px reference width
-- (Boxer / T16 / TX16S MK2), matching EdgeTX's own LVGL 480-baseline.
-- TX16S MK3 (800 px) → S ≈ 1.67; TX15 Max (480 px) → S = 1.0.
local REF_W = 480
local S     = LCD_W / REF_W
local TH    = math.floor(18 * S + 0.5)  -- standard line height for default font
local function sx(v) return math.floor(v * S + 0.5) end

-- Two palettes, picked per frame by the "Theme" widget option (see refresh()).
-- DARK paints its own near-black panel; LIGHT leaves the background transparent
-- (the radio theme shows through) and draws text black. `accent` is the green at the
-- "good" end of everything green/yellow/red — the label/brand/cursor AND the %
-- value, threshold bar, battery glyph and live voltage. It is lime in DARK but a
-- darker green in LIGHT, for legibility on a bright background; the yellow/red
-- escalation colours stay the same in both themes. `transparent` skips the panel
-- paint. (Mascot-eye colours are separate, theme-independent constants below.)
local DARK = {
  panel   = lcd.RGB( 18,  20,  18),   -- near-black background
  accent  = lcd.RGB(124, 210,  48),   -- lime green (label, brand, % / V / glyph "ok")
  fg      = lcd.RGB(235, 235, 235),   -- primary readouts
  muted   = lcd.RGB(150, 150, 150),   -- captions / secondary lines
  track   = lcd.RGB( 55,  58,  55),   -- bar/glyph empty track
  transparent = false,
}
local LIGHT = {
  panel   = nil,                      -- transparent: no panel painted
  accent  = lcd.RGB(  1, 152,   8),   -- darker green — readable on a bright background
  fg      = lcd.RGB(  0,   0,   0),   -- black readouts
  muted   = lcd.RGB( 90,  90,  90),   -- darker grey for light backgrounds
  track   = lcd.RGB(200, 200, 205),   -- light-grey empty track
  transparent = true,
}
-- Active palette; reassigned each frame in refresh() from ctx.cfg.Theme.
local COLORS = DARK

-- Mascot-eye colours, theme-independent: a light eyeball with a dark rim/pupil, so it
-- reads as an eye on both the dark panel and the transparent/light background.
local EYE_WHITE = lcd.RGB(245, 245, 245)
local EYE_RIM   = lcd.RGB( 20,  20,  20)

-- Font flags from largest to smallest. XXLSIZE/DBLSIZE/MIDSIZE/SMLSIZE are EdgeTX
-- globals; 0 is the default font. Used by pickFont() to scale to the zone.
local FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

-- Largest font flag whose rendered text fits within maxW×maxH, plus its measured
-- width/height. Falls back to the smallest font if nothing fits.
local function pickFont(text, maxW, maxH)
  for _, flag in ipairs(FONTS) do
    local tw, th = lcd.sizeText(text, flag)
    if tw <= maxW and th <= maxH then return flag, tw, th end
  end
  local tw, th = lcd.sizeText(text, SMLSIZE)
  return SMLSIZE, tw, th
end

-- Draws coloured text. A raw lcd.RGB() value must NOT be added to the drawText
-- flags — its bits collide with the size/attribute flags (a green accent can flip
-- a size bit and double the font). EdgeTX's custom colour goes through the
-- CUSTOM_COLOR slot; `flags` then carries only size/align/BOLD.
local function dtext(x, y, text, color, flags)
  lcd.setColor(CUSTOM_COLOR, color)
  lcd.drawText(x, y, text, CUSTOM_COLOR + (flags or 0))
end

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

-- Loads and validates the config file.
-- Returns (configTable, nil) on success, or (nil, errorKind) where errorKind is
-- one of "missing", "parse", "schema".
local function loadConfig()
  local f = io.open(CONFIG_PATH, "r")
  if not f then
    return nil, "missing"
  end
  io.close(f)  -- EdgeTX file handles are raw userdata; use io.close, not f:close().

  local ok, result = pcall(dofile, CONFIG_PATH)
  if not ok or type(result) ~= "table" then
    return nil, "parse"
  end
  if result.schemaVersion ~= SCHEMA_VERSION then
    return nil, "schema"
  end
  if type(result.generation) ~= "number" then
    return nil, "schema"
  end
  result.archive = result.archive or {}

  return result, nil
end

-- Telemetry sensor names (CRSF/ELRS standard, hardcoded).
local SENSOR_VOLTAGE  = "RxBt"
local SENSOR_CURRENT  = "Curr"
local SENSOR_CAPACITY = "Capa"
local SENSOR_LINK     = "RQly"

-- Pilot-provided voice files. Missing files just stay silent (playFile no-ops).
local WARN_SOUND = "/SOUNDS/en/scripts/LIPONY/warn.wav"
local CRIT_SOUND = "/SOUNDS/en/scripts/LIPONY/crit.wav"

-- Defensive wrappers for the firmware calls. The tick-level pcall is the
-- overall safety net; these keep a single bad sensor or a malformed model.getInfo
-- from tanking the whole cycle, and they are usable from refresh() too (which has
-- no surrounding pcall).
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
-- unavailable. (Named distinctly from the Tools script's modelDisplayName(filename),
-- which reads the .yml header to resolve names for non-active models too.)
local function activeModelName()
  local ok, info = pcall(model.getInfo)
  if ok and type(info) == "table" and info.name and info.name ~= "" then
    return info.name
  end
  return nil
end

-- Records which telemetry sensors the model actually has, so the widget can show
-- a clear "Sensor missing" hint instead of computing on absent values.
local function checkSensors(ctx)
  ctx.hasRxBt = sensorExists(SENSOR_VOLTAGE)
  ctx.hasCurr = sensorExists(SENSOR_CURRENT)
  ctx.hasCapa = sensorExists(SENSOR_CAPACITY)
  ctx.hasRQly = sensorExists(SENSOR_LINK)
end

-- Reads the four sensors, applies plausibility filters and keeps the last valid
-- value on ctx (invalid samples dropped). Voltage validation needs ctx.cells;
-- rawVoltage is always kept for the online fallback.
local function readTelemetry(ctx)
  local v = safeGetValue(SENSOR_VOLTAGE)
  local i = safeGetValue(SENSOR_CURRENT)
  local q = safeGetValue(SENSOR_CAPACITY)
  local l = safeGetValue(SENSOR_LINK)

  ctx.linkQuality = l
  ctx.rawVoltage  = v

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

  if not ctx.config or not ctx.config.models then return end
  local filename = modelFilename()
  local modelCfg = filename and ctx.config.models[filename]
  if not modelCfg then
    ctx.modelError = "missing"
    return
  end
  ctx.cells       = modelCfg.cells
  ctx.parallel    = modelCfg.parallel == true
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
    -- Cycle counts now travel with the config, so adopting the new config also
    -- refreshes them — a tool-side "Reset statistics" bumps the generation and is
    -- picked up here without any separate stats reload.
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

-- Resets per-flight state on a (re-)connect. Telemetry values (voltage/current)
-- are kept and will be refreshed by readTelemetry on the next tick.
local function resetFlightState(ctx)
  ctx.capacity            = nil
  ctx.warnPlayed          = false
  ctx.critPlayed          = false
  ctx.currentSumA         = 0
  ctx.currentSampleCount  = 0
  ctx.timeLeftStr         = nil   -- recompute the displayed time-left promptly
  ctx.timeLeftStamp       = nil
  ctx.restVoltage         = nil
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
-- Config persistence (cycle-counter write-back)
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
-- and the remaining hash part with string/number keys, so it is reusable for the
-- Tools-Script config writer. Functions/userdata are not expected.
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

-- Increments the reload sentinel and writes the whole config back. Same shape and
-- padding the tool uses, so a self-write is indistinguishable from a tool write.
-- Returns true on success.
local function saveConfig(config)
  config.generation = (config.generation or 0) + 1
  local content = "-- Lipo-Nanny configuration (auto-generated by the Tools-Script).\n"
                  .. "return " .. serialize(config, "") .. "\n"
  return writeFile(CONFIG_PATH, content)
end

-- Cycle count for one physical battery, keyed by its stable pack id (0 if none).
-- Cycles now live on the config instances, so this scans the loaded config.
local function cyclesFor(ctx, packId)
  if not packId or not ctx.config then return 0 end
  for _, b in ipairs(ctx.config.batteries or {}) do
    for _, inst in ipairs(b.instances or {}) do
      if inst.id == packId then return inst.cycles or 0 end
    end
  end
  return 0
end

-- Flushes pending cycle bumps at flight end (read-modify-write on config.lua, to
-- spare the SD card): re-read fresh so tool edits elsewhere survive, add each bump
-- onto its instance, write back. A missing/unreadable config or a failed write keeps
-- the bumps pending for a retry; a bump for a vanished pack is dropped.
local function flushCycles(ctx)
  if not next(ctx.pendingBumps) then return end
  local fresh = loadConfig()
  if not fresh then return end   -- missing/parse/schema: leave the file + bumps alone
  for packId, n in pairs(ctx.pendingBumps) do
    for _, b in ipairs(fresh.batteries or {}) do
      for _, inst in ipairs(b.instances or {}) do
        if inst.id == packId then inst.cycles = (inst.cycles or 0) + n end
      end
    end
  end
  if saveConfig(fresh) then
    ctx.config         = fresh            -- refresh the read cache (incl. bumped cycles)
    ctx.lastGeneration = fresh.generation -- our own write; don't re-adopt it next poll
    ctx.pendingBumps   = {}
  end
end

-- Called once at the CONNECTED→ENDED transition: records a +1 cycle bump for each
-- used battery if more than 10% of the profile capacity was drawn this flight
-- (parallel splits the consumption in half, so both share the same result), then
-- flushes the bumps to config.lua.
local function finalizeFlight(ctx)
  local profile   = ctx.selectedProfile
  local instances = ctx.selectedInstances
  if profile and profile.capacityMah and instances and #instances > 0 then
    -- The consumed mAh is split evenly across the used packs (50/50 in parallel);
    -- each pack earns a cycle when its share exceeds 10% of ITS effective capacity.
    local perBattery = (ctx.capacity or 0) / #instances
    for _, inst in ipairs(instances) do
      if inst.id then
        local effCap = profile.capacityMah * (1 - (inst.wear or 0) / 100)
        if effCap > 0 and perBattery > 0.10 * effCap then
          ctx.pendingBumps[inst.id] = (ctx.pendingBumps[inst.id] or 0) + 1
        end
      end
    end
  end
  flushCycles(ctx)
end

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
-- Rendering helpers
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

-- "calc.." during the first 60 s after CONNECTED, "—:—" when the value is
-- permanently uncalculable (e.g. Curr sensor missing), otherwise "mm:ss".
local function formatTimeLeft(ctx)
  if not ctx.hasCurr then return "—:—" end   -- no current sensor → not computable
  local elapsedS = (getTime() - ctx.connectedSinceTime) / 100
  if elapsedS < 60 then return "calc.." end
  local secs = calculateTimeLeftSeconds(ctx)
  if not secs then return "—:—" end
  local m = math.floor(secs / 60)
  local s = math.floor(secs % 60)
  if m > 99 then m = 99 end
  return string.format("%02d:%02d", m, s)
end

-- Refreshes the DISPLAYED time-left string at most every TIME_LEFT_INTERVAL (2 s).
-- The underlying current average keeps accumulating every tick (in the state
-- machine); this only throttles how often that running value is snapshotted for
-- the screen, so a momentary throttle blip doesn't make the mm:ss twitch.
local function refreshTimeLeft(ctx)
  local now = getTime()
  if not ctx.timeLeftStr or (now - (ctx.timeLeftStamp or 0)) >= TIME_LEFT_INTERVAL then
    ctx.timeLeftStr   = formatTimeLeft(ctx)
    ctx.timeLeftStamp = now
  end
end

-- Bar-fill color (only the bar changes color, text stays neutral).
local function getBarColor(restPct, warnPct, critPct)
  if restPct > warnPct then return COLORS.accent        end   -- green (theme accent)
  if restPct > critPct then return lcd.RGB(255, 180, 0)  end   -- yellow
  return lcd.RGB(220, 40, 40)                                  -- red
end

-- Label "name #N" (or "#1+2" for parallel). Instances are { pos = N, id = … }
-- pairs; the displayed number is the position, not the internal pack id.
local function formatBatteryLabel(name, instances)
  if not name then return "—" end
  if type(instances) ~= "table" or #instances == 0 then return name end
  if #instances == 1 then
    return name .. " #" .. tostring(instances[1].pos)
  end
  -- Parallel: "#1+2"
  return name .. " #" .. tostring(instances[1].pos) .. "+" .. tostring(instances[#instances].pos)
end

-- ---------------------------------------------------------------------------
-- CONNECTED tile (screenshot layout): large lime readouts, a segmented battery
-- glyph and a threshold bar. One responsive layout that scales down through
-- FULL → MEDIUM → SMALL tiers by zone size.
-- ---------------------------------------------------------------------------

-- One font step smaller than `flag` (used to render a value's unit smaller than
-- its number).
local function smallerFont(flag)
  if flag == XXLSIZE then return DBLSIZE end
  if flag == DBLSIZE then return MIDSIZE end
  if flag == MIDSIZE then return 0       end
  return SMLSIZE
end

-- Shrinks `flag` step by step until `text` fits within `maxW` (never below SMLSIZE).
local function fitWidth(text, flag, maxW)
  while flag ~= SMLSIZE and lcd.sizeText(text, flag) > maxW do
    flag = smallerFont(flag)
  end
  return flag
end

-- Draws a number with its unit appended in a smaller font, bottom-aligned to the
-- number. Returns the total drawn width.
local function drawValueUnit(x, y, value, unit, color, valueFlag, unitFlag)
  dtext(x, y, value, color, valueFlag)
  local vw, vh = lcd.sizeText(value, valueFlag)
  if unit and unit ~= "" then
    local gap     = sx(3)
    local uw, uh  = lcd.sizeText(unit, unitFlag)
    dtext(x + vw + gap, y + (vh - uh), unit, color, unitFlag)
    return vw + gap + uw
  end
  return vw
end

-- "● Name #N" header: a small accent dot followed by the battery label, drawn at
-- caption size (SMLSIZE, non-bold) so it is no larger than e.g. "REMAINING".
local function drawHeaderLabel(x, y, label)
  local _, th = lcd.sizeText(label, SMLSIZE)   -- text height, to centre the dot
  local dot   = sx(5)
  lcd.drawFilledRectangle(x, y + math.floor((th - dot) / 2), dot, dot, COLORS.accent)
  dtext(x + dot + sx(3), y, label, COLORS.accent, SMLSIZE)
end

-- Vertical battery glyph: a cap, an outlined body and `nSeg` segments filled from
-- the bottom up to `pct`, in `color`; the empty part stays on the track colour.
local function drawBatteryGlyph(x, y, w, h, pct, color)
  local capH  = math.max(sx(3), math.floor(h * 0.07))
  local capW  = math.floor(w * 0.45)
  local bodyY = y + capH
  local bodyH = h - capH
  lcd.drawFilledRectangle(x + math.floor((w - capW) / 2), y, capW, capH, COLORS.muted)
  lcd.drawRectangle(x, bodyY, w, bodyH, COLORS.muted)
  lcd.drawRectangle(x + 1, bodyY + 1, w - 2, bodyH - 2, COLORS.muted)
  local inset   = sx(3)
  local ix, iw  = x + inset, w - 2 * inset
  local iy, ih  = bodyY + inset, bodyH - 2 * inset
  local nSeg    = 10                       -- 10 segments → 10% granularity
  local gap     = sx(1)
  local filled  = math.floor((pct or 0) / 100 * nSeg + 0.5)
  -- Gaps go only BETWEEN segments (nSeg-1 of them); the segment area is split into
  -- nSeg equal rounded slots so the stack is flush at both the top and the bottom.
  local segArea = ih - (nSeg - 1) * gap
  for k = 1, nSeg do                       -- k = 1 is the TOP segment
    local top  = iy + math.floor(segArea * (k - 1) / nSeg + 0.5) + (k - 1) * gap
    local bot  = iy + math.floor(segArea * k       / nSeg + 0.5) + (k - 1) * gap
    local segH = bot - top
    if segH < 1 then segH = 1 end
    local fromBottom = nSeg - k + 1        -- 1 = bottom segment
    lcd.drawFilledRectangle(ix, top, iw, segH, (fromBottom <= filled) and color or COLORS.track)
  end
end

-- Horizontal threshold bar: track, threshold-coloured fill up to `pct`, yellow/red
-- tick marks at the warn/crit positions and, when `withLabels`, the WARN caption
-- ABOVE the bar and the CRIT caption BELOW it — so the two never collide even when
-- the thresholds sit close together. Caller must leave one text line above and
-- below the bar.
local THR_YELLOW = lcd.RGB(255, 180, 0)
local THR_RED    = lcd.RGB(220,  40, 40)
local function drawThresholdBar(x, y, w, h, pct, warn, crit, withLabels)
  lcd.drawFilledRectangle(x, y, w, h, COLORS.track)
  local p     = math.max(0, math.min(100, pct or 0))
  local fillW = math.floor(w * p / 100)
  if fillW > 0 then
    lcd.drawFilledRectangle(x, y, fillW, h, getBarColor(p, warn, crit))
  end
  local tickW = math.max(sx(2), 2)
  local function tick(thr, col)
    local tx = x + math.floor(w * thr / 100) - math.floor(tickW / 2)
    lcd.drawFilledRectangle(tx, y - sx(1), tickW, h + sx(2), col)
  end
  tick(warn, THR_YELLOW)
  tick(crit, THR_RED)
  if withLabels then
    local _, lh = lcd.sizeText("0", SMLSIZE)
    local function label(thr, txt, col, ly)
      local tw = lcd.sizeText(txt, SMLSIZE)
      local lx = x + math.floor(w * thr / 100) - math.floor(tw / 2)
      if lx < x then lx = x elseif lx + tw > x + w then lx = x + w - tw end
      dtext(lx, ly, txt, col, SMLSIZE)
    end
    label(warn, string.format("WARN %d%%", warn), THR_YELLOW, y - lh - sx(1))  -- above
    label(crit, string.format("CRIT %d%%", crit), THR_RED,    y + h + sx(2))   -- below
  end
end

-- A metric column: big number+unit (in `bigFlag`, bottom-aligned to `bigBottom`),
-- then a small caption, a value line and a small sub-line. Both columns share the
-- same `bigBottom`, so their caption/value/sub rows line up across the tile even
-- when the two big numbers use different font sizes.
local function drawMetricBlock(x, bigBottom, big, unit, bigColor, capLine, valLine, subLine, bigFlag, colW)
  local _, bigH = lcd.sizeText(big .. unit, bigFlag)
  drawValueUnit(x, bigBottom - bigH, big, unit, bigColor, bigFlag, smallerFont(bigFlag))
  local y = bigBottom + sx(1)
  dtext(x, y, capLine, COLORS.muted, SMLSIZE)
  local _, capH = lcd.sizeText(capLine, SMLSIZE)
  y = y + capH + sx(2)
  -- The value line is the only block element in a real font (caption/sub are
  -- already SMLSIZE), so shrink it to the column on narrow tiles (e.g. a quarter
  -- page) instead of letting "1500 mAh" spill into the next column.
  dtext(x, y, valLine, COLORS.fg, fitWidth(valLine, 0, colW))
  y = y + TH
  dtext(x, y, subLine, COLORS.muted, SMLSIZE)
end

-- Colour for the live voltage readout: green/yellow/red from the chemistry's
-- per-cell loaded-voltage thresholds (voltageWarn/voltageCrit). The green end is the
-- theme accent (lime in Dark, darker green in Light); yellow/red are fixed. Falls
-- back to the accent green when voltage/cells/chemistry are unavailable.
local function voltageColor(ctx)
  local profile = ctx.selectedProfile
  local chem    = profile and CHEMISTRIES[profile.chemistry]
  if not chem or not chem.voltageWarn or not ctx.voltage or not ctx.cells or ctx.cells <= 0 then
    return COLORS.accent
  end
  local vpc = ctx.voltage / ctx.cells
  if vpc >= chem.voltageWarn then return COLORS.accent end
  if vpc >= chem.voltageCrit then return THR_YELLOW   end
  return THR_RED
end

-- Builds the display strings/colours once for the active CONNECTED metrics.
local function connectedMetrics(ctx)
  local restPct    = calculateRestPct(ctx)
  local warn, crit = getThresholds(ctx)
  local effective  = effectiveCapacityMah(ctx)
  -- `used` (telemetry consumed + pre-flight start offset) drives the remaining %
  -- and the remaining-mAh figure. The CONSUMED display, however, shows only the
  -- in-flight telemetry value (ctx.capacity) — what the pilot actually drew this
  -- flight, not the offset for a not-quite-full pack.
  local used       = (ctx.capacity and ctx.startOffsetMah) and (ctx.capacity + ctx.startOffsetMah) or nil
  local remaining  = (effective and used) and math.max(0, effective - used) or nil
  local profile    = ctx.selectedProfile and ctx.selectedProfile.name or nil
  return {
    restPct  = restPct,
    warn     = warn,
    crit     = crit,
    pctColor = restPct and getBarColor(restPct, warn, crit) or COLORS.muted,
    vColor   = voltageColor(ctx),
    label    = formatBatteryLabel(profile, ctx.selectedInstances),
    pctText  = restPct and string.format("%d", math.floor(restPct + 0.5)) or "--",
    vText    = ctx.voltage and string.format("%.1f", ctx.voltage) or "--.-",
    vCell    = (ctx.voltage and ctx.cells and ctx.cells > 0)
               and string.format("%.2f V/cell", ctx.voltage / ctx.cells) or "—.- V/cell",
    remText  = remaining and string.format("%d mAh", math.floor(remaining + 0.5)) or "-- mAh",
    ofText   = effective and string.format("of %d mAh", math.floor(effective + 0.5)) or "",
    consText = ctx.capacity and string.format("%d mAh", math.floor(ctx.capacity + 0.5)) or "-- mAh",
    timeLeft = ctx.timeLeftStr or formatTimeLeft(ctx),  -- 2 s-throttled snapshot
  }
end

-- Remaining-flight-time mini-block: a centred "TIME LEFT" caption above the mm:ss
-- value. flightTimeBlockH() returns its total height (and the caption height) so
-- the caller can decide whether it fits and where to centre it.
local TIME_VAL_FLAG = MIDSIZE
local function flightTimeBlockH()
  local _, capH = lcd.sizeText("TIME LEFT", SMLSIZE)
  local _, valH = lcd.sizeText("00:00", TIME_VAL_FLAG)
  return capH + sx(1) + valH, capH
end
local function drawFlightTimeBlock(cx, top, value)
  local _, capH = flightTimeBlockH()
  dtext(cx, top, "TIME LEFT", COLORS.muted, SMLSIZE + CENTER)
  dtext(cx, top + capH + sx(1), value, COLORS.fg, TIME_VAL_FLAG + CENTER)
end

-- Widest fixed (SMLSIZE) line a metric column must hold, so a column narrower than
-- this would clip "of 0000 mAh" / "0.00 V/cell".
local function minColW()
  return math.max(lcd.sizeText("of 0000 mAh", SMLSIZE),
                  lcd.sizeText("0.00 V/cell", SMLSIZE))
end

-- FULL-tier column geometry for a zone width `w`. The two text columns get
-- priority: the battery glyph is normally 19% of w, but on tight zones it is
-- narrowed to whatever space is left once both columns clear minColW — so the
-- glyph is always kept, just slimmer, and never squeezes the readouts. Returns
-- (colW, glyphW). Shared by the renderer and the tier picker so they never differ.
local function fullColumns(w)
  local pad      = sx(4)
  local colGap   = sx(6)
  local leftover = w - 2 * pad - 2 * colGap - 2 * minColW()   -- room beyond min columns
  local gW       = math.max(0, math.min(math.floor(w * 0.19), leftover))
  local colW     = math.floor((w - 2 * pad - gW - 2 * colGap) / 2)
  return colW, gW
end

-- FULL tier: header, two metric columns and the battery glyph. The threshold bar
-- is added at the bottom only when there is enough free height below the content
-- (so it appears on roomy half/full-page tiles but not on short/cramped ones).
local function drawConnectedFull(w, h, m)
  local pad        = sx(4)
  drawHeaderLabel(pad, pad, m.label)
  local _, hdrH    = lcd.sizeText(m.label, SMLSIZE)   -- actual header height (SMLSIZE)
  local midTop     = pad + hdrH + sx(2)
  local contentBot = h - pad
  local midH       = contentBot - midTop
  local colW, gW   = fullColumns(w)
  local colGap     = sx(6)
  local gX         = w - pad - gW
  local maxBigH    = math.floor(midH * 0.5)
  -- Size the % from a fixed "100%" reference (not the live value) so a single-digit
  -- reading ("1%") doesn't get a larger font than "67%"/"100%". V is one step
  -- smaller so % stands out (shrunk further only if its wider text overflows).
  local pctFlag    = pickFont("100%", colW, maxBigH)
  local vFlag      = fitWidth(m.vText .. "V", smallerFont(pctFlag), colW)
  -- Shared bottom edge for both big numbers (= the taller, % one) so the rows
  -- beneath them align across the two columns.
  local _, pctH    = lcd.sizeText(m.pctText .. "%", pctFlag)
  local bigBottom  = midTop + pctH
  drawMetricBlock(pad, bigBottom, m.pctText, "%", m.pctColor,
                  "REMAINING", m.remText, m.ofText, pctFlag, colW)
  drawMetricBlock(pad + colW + colGap, bigBottom, m.vText, "V", m.vColor,
                  m.vCell, m.consText, "CONSUMED", vFlag, colW)
  -- Battery glyph height = the metric text block's height, so it ends at the
  -- bottom of the CONSUMED / "of … mAh" line rather than the full middle area.
  local _, smlH    = lcd.sizeText("0", SMLSIZE)
  local textBottom = bigBottom + sx(1) + smlH + sx(2) + TH + smlH
  if gW > 0 then
    drawBatteryGlyph(gX, midTop, gW, textBottom - midTop, m.restPct, m.pctColor)
  end
  -- Threshold bar pinned to the bottom, only if it fits below the content. With
  -- labels it needs one text line above (WARN) and one below (CRIT), so the bar
  -- sits one line up from the bottom to leave room for the CRIT caption.
  local barH       = sx(8)
  local roomBelow  = contentBot - textBottom
  local barTop     = contentBot   -- bottom edge of the area the time block may use
  if roomBelow >= barH + sx(4) then
    local withLabels = roomBelow >= barH + 2 * smlH + sx(4)
    local barY       = contentBot - (withLabels and smlH or 0) - barH
    drawThresholdBar(pad, barY, w - 2 * pad, barH, m.restPct, m.warn, m.crit, withLabels)
    barTop = barY - (withLabels and smlH or 0)   -- top of the bar block (incl. WARN label)
  end
  -- Remaining flight time, centred in the gap between the content and the bar
  -- (now that the half/full-page layout has the room again).
  local tlH = flightTimeBlockH()
  if (barTop - textBottom) >= tlH then
    local ty = textBottom + math.floor(((barTop - textBottom) - tlH) / 2)
    drawFlightTimeBlock(math.floor(w / 2), ty, m.timeLeft)
  end
end

-- MEDIUM tier: header, % and V side by side with one sub-line each. Compact tier
-- (narrow tiles) — no threshold bar.
local function drawConnectedMedium(w, h, m)
  local pad        = sx(3)
  drawHeaderLabel(pad, pad, m.label)
  local hdrH       = TH
  local midTop     = pad + hdrH
  local midH       = (h - pad) - midTop
  local colW       = math.floor((w - 3 * pad) / 2)
  local leftX, rightX = pad, pad + colW + pad
  local bigH       = math.floor(midH * 0.6)
  -- % sized from a fixed "100%" reference (stable across digit counts); V one step
  -- smaller, matching the FULL tier.
  local lFlag, _, lH = pickFont("100%", colW, bigH)
  local rFlag = fitWidth(m.vText .. "V", smallerFont(lFlag), colW)
  drawValueUnit(leftX,  midTop, m.pctText, "%", m.pctColor, lFlag, smallerFont(lFlag))
  drawValueUnit(rightX, midTop, m.vText,   "V", m.vColor,   rFlag, smallerFont(rFlag))
  local subY = midTop + lH + sx(1)
  dtext(leftX,  subY, m.remText,  COLORS.muted, SMLSIZE)
  dtext(rightX, subY, m.consText, COLORS.muted, SMLSIZE)
end

-- SMALL tier: one line "<pct>%  <V>V". No threshold bar.
local function drawConnectedSmall(w, h, m)
  local pad   = sx(2)
  local topH  = (h - pad) - pad
  local pctS  = m.pctText .. "%"
  local vS    = m.vText .. "V"
  local pFlag = pickFont(pctS, math.floor(w * 0.5), topH)
  dtext(pad, pad, pctS, m.pctColor, pFlag)
  local vFlag, vw = pickFont(vS, math.floor(w * 0.5), topH)
  dtext(w - pad - vw, pad, vS, m.vColor, vFlag)
end

-- Blinking red "receiving" dot in the top-right corner: shown while the link is
-- up, toggling at 0.5 Hz so the pilot can see fresh telemetry is arriving (and
-- that the script is running). It stops the instant packets stop (isOnline → false).
local HEARTBEAT_HALF = 100  -- 1 s on / 1 s off → 0.5 Hz (getTime units, 1/100 s)
local function drawHeartbeat(ctx)
  if not isOnline(ctx) then return end
  if math.floor(getTime() / HEARTBEAT_HALF) % 2 ~= 0 then return end
  local r = sx(3)
  lcd.drawFilledCircle(ctx.zone.w - sx(4) - r, sx(4) + r, r, THR_RED)
end

-- True when the FULL two-column layout fits the zone. Both checks are in absolute
-- pixels because the fonts do NOT scale with S (only positions do): each column
-- must be wide enough for its longest fixed (SMLSIZE) line, and the zone tall
-- enough for header + a MIDSIZE big number + the three sub-rows. Measuring the
-- real font metrics makes this self-tuning across radios (a quarter page is wider
-- in pixels on the 800 px MK3 than on a 480 px radio) instead of a magic constant.
local function connectedFitsFull(w, h)
  if (fullColumns(w)) < minColW() then return false end
  local pad     = sx(4)
  local _, hdrH = lcd.sizeText("0", SMLSIZE)
  local _, bigH = lcd.sizeText("0", MIDSIZE)
  local _, smlH = lcd.sizeText("0", SMLSIZE)
  local needH   = pad + hdrH + sx(2) + bigH + sx(1) + smlH + sx(2) + TH + smlH + pad
  return h >= needH
end

-- Picks the tier by what fits the zone. FULL is used whenever its content fits;
-- the bar's WARN/CRIT labels and the time-left block degrade on their own inside
-- FULL when the height is tight, so a quarter page shows the same layout as a
-- full page, just with smaller fonts. Shorter/narrower zones fall back to the
-- compact MEDIUM/SMALL tiers.
local function drawConnectedTile(ctx)
  local w, h = ctx.zone.w, ctx.zone.h
  local m    = connectedMetrics(ctx)
  if connectedFitsFull(w, h) then
    drawConnectedFull(w, h, m)
  elseif h >= 60 then
    drawConnectedMedium(w, h, m)
  else
    drawConnectedSmall(w, h, m)
  end
end

-- Renders a list of strings as vertically-centered horizontally-centered
-- lines. Used by WAITING / error / informational tiles.
local function drawCenteredLines(ctx, lines)
  local n = #lines
  if n == 0 then return end
  local w, h   = ctx.zone.w, ctx.zone.h
  local cx     = math.floor(w / 2)
  local startY = math.floor((h - n * TH) / 2)
  if startY < 0 then startY = 0 end
  for i = 1, n do
    dtext(cx, startY + (i - 1) * TH, lines[i], COLORS.fg, CENTER)
  end
end

-- Indeterminate "searching" bar: an accent segment that slides back and forth
-- (ping-pong) along a track. Pure function of getTime(), no state needed.
local SPLASH_BAR_PERIOD = 180  -- getTime units (1/100 s) for a full left→right→left cycle
local function drawSplashBar(x, y, w, h)
  lcd.drawFilledRectangle(x, y, w, h, COLORS.track)
  local segW   = math.max(sx(8), math.floor(w * 0.3))
  local travel = math.max(0, w - segW)
  local phase  = (getTime() % SPLASH_BAR_PERIOD) / SPLASH_BAR_PERIOD
  local tri    = (phase < 0.5) and (phase * 2) or (2 - phase * 2)   -- 0→1→0
  lcd.drawFilledRectangle(x + math.floor(travel * tri), y, segW, h, COLORS.accent)
end

-- "Waiting for telemetry" with 0–3 trailing dots that build up slowly. The line is
-- centred as if all three dots were present and the dots are drawn left-fixed after
-- the base text, so the base never jitters as the dots appear.
local WAIT_BASE     = "Waiting for telemetry"
local DOT_INTERVAL  = 50   -- getTime units (1/100 s) per dot → ~2 s full cycle
local function drawWaitingStatus(cx, y)
  local n      = math.floor(getTime() / DOT_INTERVAL) % 4   -- 0..3
  local baseW  = lcd.sizeText(WAIT_BASE, SMLSIZE)
  local fullW  = lcd.sizeText(WAIT_BASE .. "...", SMLSIZE)
  local startX = cx - math.floor(fullW / 2)
  dtext(startX, y, WAIT_BASE, COLORS.muted, SMLSIZE)
  if n > 0 then dtext(startX + baseW, y, string.rep(".", n), COLORS.muted, SMLSIZE) end
end

-- WAITING tile: a small branding splash — "LIPO-NANNY" in accent, an indeterminate
-- loading bar, and the status line. Shown for every idle/waiting state (true
-- WAITING, the post-connect settle window, the popup/flight-end timeouts). Degrades
-- on short zones: the bar is dropped first, then down to a single centered line.
local function drawWaitingTile(ctx)
  local w, h   = ctx.zone.w, ctx.zone.h
  local pad    = sx(4)
  local title  = "LIPO-NANNY"
  local status = "Waiting for telemetry…"
  local cx     = math.floor(w / 2)

  local titleFlag, _, titleH = pickFont(title, w - 2 * pad, math.floor(h * 0.4))
  local _, subH = lcd.sizeText(status, SMLSIZE)
  local barH    = sx(4)
  local gap     = sx(4)
  local avail   = h - 2 * pad

  if avail >= titleH + gap + barH + gap + subH then
    local blockH = titleH + gap + barH + gap + subH
    local top    = math.floor((h - blockH) / 2)
    local barW   = math.floor(w * 0.7)
    dtext(cx, top, title, COLORS.accent, titleFlag + CENTER)
    drawSplashBar(math.floor((w - barW) / 2), top + titleH + gap, barW, barH)
    drawWaitingStatus(cx, top + titleH + gap + barH + gap)
  elseif avail >= titleH + gap + subH then
    local blockH = titleH + gap + subH
    local top    = math.floor((h - blockH) / 2)
    dtext(cx, top, title, COLORS.accent, titleFlag + CENTER)
    drawWaitingStatus(cx, top + titleH + gap)
  else
    drawCenteredLines(ctx, { status })
  end
end

-- ENDED tile: summary of the just-finished flight. The heading is the battery
-- label, drawn identically to the live tile (accent dot + name via drawHeaderLabel).
local function drawEndedTile(ctx)
  local pad   = sx(4)
  local lf    = ctx.lastFlight or {}
  local label = formatBatteryLabel(lf.profileName, lf.instances)

  -- Heading: battery name, same as the CONNECTED tile's header.
  drawHeaderLabel(pad, pad, label)
  local _, hdrH = lcd.sizeText(label, SMLSIZE)
  local y = pad + hdrH + sx(2)

  dtext(pad, y, "Flight ended", COLORS.accent, BOLD)
  y = y + TH

  -- Used X mAh (Y%) — Y% includes the start offset.
  local usedText
  if lf.usedMah then
    local pctStr = ""
    if lf.effectiveCap and lf.effectiveCap > 0 then
      local effectiveUsed = lf.usedMah + (lf.startOffsetMah or 0)
      local pct = math.floor(effectiveUsed / lf.effectiveCap * 100 + 0.5)
      pctStr = string.format(" (%d%%)", pct)
    end
    usedText = string.format("Used %d mAh%s", lf.usedMah, pctStr)
  else
    usedText = "Used —"
  end
  dtext(pad, y, usedText, COLORS.fg, 0)
  y = y + TH

  -- Last: x.xx V/cell
  local lastText
  if lf.lastVoltagePerCell then
    lastText = string.format("Last: %.2f V/cell", lf.lastVoltagePerCell)
  else
    lastText = "Last: —.- V/cell"
  end
  dtext(pad, y, lastText, COLORS.muted, 0)
  y = y + TH

  -- Total cycles of the flown pack(s). finalizeFlight already added this flight's +1
  -- to the config before we get here, so just read the stored count. Parallel shows
  -- both packs, e.g. "(16, 8)".
  local cyclesStr = "—"
  if lf.instances and #lf.instances > 0 then
    local parts = {}
    for _, inst in ipairs(lf.instances) do
      parts[#parts + 1] = tostring(cyclesFor(ctx, inst.id))
    end
    cyclesStr = table.concat(parts, ", ")
  end
  dtext(pad, y, "Total pack cycles (" .. cyclesStr .. ")", COLORS.muted, 0)
end

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
                            packId = inst.id, wear = inst.wear or 0 }
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
--   parallel: always a 2-slot popup (the tools-script guarantees one assigned
--             profile with two or more packs, so two are always available);
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

-- Plays the warn / crit voice file once each as the remaining percentage drops
-- past the thresholds. No debounce: the mAh counter only rises, so each
-- threshold is crossed exactly once per flight.
local function evaluateWarnings(ctx)
  if not ctx.selectedProfile then return end
  local restPct = calculateRestPct(ctx)
  if not restPct then return end

  local warn, crit = getThresholds(ctx)
  if not ctx.warnPlayed and restPct <= warn then
    ctx.warnPlayed = true
    playFile(WARN_SOUND)
  end
  if not ctx.critPlayed and restPct <= crit then
    ctx.critPlayed = true
    playFile(CRIT_SOUND)
  end
end

-- Every instance of each model-assigned profile of the model's cell count,
-- regardless of voltage plausibility. Used for the popup when
-- nothing matched the resting voltage, so the pilot can still pick from all
-- profiles — and as the "is anything selectable at all?" check for the
-- cell-count-mismatch tile.
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
                          packId = inst.id, wear = inst.wear or 0 }
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

-- Stick-gesture control for the selection popup, polled every tick — works in the
-- normal tile without fullscreen, unlike key events. Elevator up/down moves the
-- cursor (one step per deflection, re-armed in the dead-zone); aileron held full-
-- right with elevator centred commits. Flip the signs if a direction feels inverted.
local function pollSelectionSticks(ctx)
  if not ctx.pendingSelection then return end

  -- Resolve any slot that has a single candidate before reading the sticks.
  if ctx.parallel and autoSelectSlot(ctx) then return end

  local list = activeSelectionList(ctx)
  local n = #list
  if n == 0 then return end

  local cursor = ctx.popupCursor or 1
  if cursor < 1 then cursor = 1 elseif cursor > n then cursor = n end

  -- Navigate (elevator).
  local ele = getValue("ele")
  if math.abs(ele) < STICK_DEADZONE then
    ctx.stickArmed = true
  elseif ctx.stickArmed then
    if ele > STICK_STEP then
      cursor = cursor - 1            -- stick up → cursor up
      if cursor < 1 then cursor = 1 end
      ctx.stickArmed = false
    elseif ele < -STICK_STEP then
      cursor = cursor + 1            -- stick down → cursor down
      if cursor > n then cursor = n end
      ctx.stickArmed = false
    end
  end
  ctx.popupCursor = cursor

  -- Confirm (aileron held full-right, elevator centred). Re-armed only after the
  -- aileron returns to centre.
  local ail = getValue("ail")
  if math.abs(ail) < STICK_DEADZONE then
    ctx.confirmArmed = true
  end
  if ctx.confirmArmed and ail > CONFIRM_THRESHOLD and math.abs(ele) < STICK_DEADZONE then
    if ctx.confirmSince == nil then
      ctx.confirmSince = getTime()
    elseif (getTime() - ctx.confirmSince) >= CONFIRM_HOLD then
      ctx.confirmSince = nil
      commitSlot(ctx, list[cursor])
    end
  else
    ctx.confirmSince = nil          -- released or elevator moved → reset hold timer
  end
end

-- Renders the selection popup inside the widget zone (the traditional widget API
-- cannot draw outside its zone; on a full-screen widget this fills the screen).
-- Title + a scrolling window of "name #N" rows with a "> " cursor marker.
local function drawSelectionPopup(ctx)
  local w, h  = ctx.zone.w, ctx.zone.h
  local pad   = sx(2)
  -- Drawn on the background refresh() already set up, using the active palette
  -- (fg rows, accent cursor) so it tracks the Dark/Light theme.

  local title = ctx.parallel and "SELECT BATTERIES" or "SELECT BATTERY"
  dtext(math.floor(w / 2), pad, title, COLORS.accent, CENTER + BOLD)

  local firstRow = pad + TH
  local legendY  = h - TH                  -- bottom line reserved for the legend

  -- Parallel: once slot 1 is locked in, show it above the slot-2 list.
  if ctx.parallel and ctx.popupSlot == 2 and ctx.slot1Item then
    local s1 = ctx.slot1Item
    dtext(pad, firstRow, "Slot1: " .. formatBatteryLabel(s1.profile.name, { { pos = s1.pos } }), COLORS.muted, 0)
    firstRow = firstRow + TH
  end

  local list = activeSelectionList(ctx)
  if #list == 0 then
    dtext(pad, firstRow, "No profiles", COLORS.fg, 0)
    return
  end

  -- Pre-build the row texts and pick ONE font small enough for the widest of them
  -- (incl. the "> " cursor prefix) so long names plus the "(Nc)" cycle count fit the
  -- width instead of being clipped. Only the list rows scale — the title and legend
  -- keep their fixed size. The row height only tightens when the small font is
  -- actually used, so roomy popups look exactly as before.
  local availW  = w - 2 * pad
  local rows    = {}
  local rowFlag = 0
  for i, item in ipairs(list) do
    local label = formatBatteryLabel(item.profile.name, { { pos = item.pos } })
    rows[i] = label .. " (" .. cyclesFor(ctx, item.packId) .. "c)"
    if fitWidth("> " .. rows[i], 0, availW) == SMLSIZE then rowFlag = SMLSIZE end
  end
  local _, rowTextH = lcd.sizeText("0", rowFlag)
  local rowH = (rowFlag == SMLSIZE) and (rowTextH + sx(3)) or TH

  local cursor  = ctx.popupCursor or 1
  local maxRows = math.max(1, math.floor((legendY - firstRow) / rowH))

  -- Scrolling window: keep the cursor centred so neighbouring entries stay
  -- visible (you can always tell there are more), the list scrolls underneath.
  -- Clamped at both ends so no blank rows appear.
  local half  = math.floor((maxRows - 1) / 2)
  local start = cursor - half
  if start > #list - maxRows + 1 then start = #list - maxRows + 1 end
  if start < 1 then start = 1 end
  local last = math.min(#list, start + maxRows - 1)

  local y = firstRow
  for i = start, last do
    local prefix = (i == cursor) and "> " or "  "
    dtext(pad, y, prefix .. rows[i], (i == cursor) and COLORS.accent or COLORS.fg, rowFlag)
    y = y + rowH
  end

  -- Gesture legend. ASCII only — the EdgeTX font has no arrow glyphs.
  dtext(pad, legendY, "ele: up/dn  ail: > OK", COLORS.muted, 0)
end

-- Googly eyes for the brand heading: two white eyes whose pupils roll around and
-- blink now and then — the "nanny" keeping an eye on your pack. Drawn from
-- primitives (the EdgeTX font has no emoji). Box (x, y, w, h) sits beside the title.
-- Theme-independent: a light eyeball with a dark rim + dark pupil, so it reads as a
-- real eye on both the dark panel and the transparent/light background (the rim is
-- what makes the light eyeball visible on a light background).
local function drawMascotEyes(x, y, w, h)
  local t     = getTime()
  local r     = math.max(sx(3), math.floor(h * 0.30))
  local cy    = y + math.floor(h / 2)
  local cx1   = x + r
  local cx2   = cx1 + 2 * r + sx(2)
  local blink = (t % 250) < 25
  local ph    = (t % 180) / 180 * 2 * math.pi
  local dx    = math.floor(math.cos(ph) * r * 0.4)
  local dy    = math.floor(math.sin(ph) * r * 0.4)
  for _, cx in ipairs({ cx1, cx2 }) do
    lcd.drawFilledCircle(cx, cy, r, EYE_RIM)             -- dark rim (visible on any bg)
    lcd.drawFilledCircle(cx, cy, r - 1, EYE_WHITE)       -- light eyeball
    if blink then
      lcd.drawFilledRectangle(cx - r, cy - sx(1), 2 * r, math.max(2, sx(2)), EYE_RIM)
    else
      lcd.drawFilledCircle(cx + dx, cy + dy, math.max(1, math.floor(r * 0.5)), EYE_RIM)
    end
  end
end

-- Top-left "LIPO-NANNY" brand heading (accent) shown on the error/info tiles, with
-- the googly-eyes mascot beside it.
local function drawBrandHeading(ctx)
  local pad = sx(4)
  dtext(pad, pad, "LIPO-NANNY", COLORS.accent, SMLSIZE)
  local hw, hh = lcd.sizeText("LIPO-NANNY", SMLSIZE)
  drawMascotEyes(pad + hw + sx(6), pad, sx(20), math.max(hh, sx(14)))
end

-- Generic 2-line error tile.
local function drawErrorTile(ctx, line1, line2)
  drawBrandHeading(ctx)
  drawCenteredLines(ctx, { line1, line2 })
end

local function create(zone, options)
  local ctx = {
    -- Display zone
    zone = zone,

    -- Widget options (see table at end of file): cfg.Theme = 1 dark / 2 light,
    -- cfg.Transparency = milky-overlay strength 0–5.
    cfg = options,

    -- State machine
    state = STATE_WAITING,
    lastTelemetryTime = 0,
    connectedSinceTime = 0,
    endedTime = 0,
    lastTick = 0,

    -- Config + reload polling
    config = nil,
    configError = nil,
    lastGeneration = nil,
    lastConfigPoll = 0,

    -- Cycle counts live on the config instances. pendingBumps holds cycles earned
    -- this session but not yet written (survives failed writes for a later retry);
    -- they are flushed onto config.lua at flight end (read-modify-write).
    pendingBumps = {},

    -- Telemetry — last valid values. rawVoltage = latest unvalidated RxBt,
    -- used as online fallback when RQly is missing.
    voltage     = nil,
    rawVoltage  = 0,
    current     = nil,
    capacity    = nil,
    linkQuality = 0,

    -- Sensor existence (assume present until checkSensors proves otherwise, so
    -- the first frame doesn't flash "Sensor missing").
    hasRxBt = true,
    hasCurr = true,
    hasCapa = true,
    hasRQly = true,

    -- Robustness / error recovery
    errorStreak = 0,
    fatalError  = false,
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
  pollConfig(ctx)
  return ctx
end

local function update(ctx, options)
  -- Called when the pilot changes the widget settings.
  ctx.cfg = options
end

-- One data-processing cycle (no lcd.*). Bails out early on a config error or a
-- missing required sensor so it never computes on absent values.
local function tickImpl(ctx)
  pollConfig(ctx)
  if ctx.configError then return end
  checkSensors(ctx)
  if not ctx.hasRxBt or not ctx.hasCapa then return end  -- required sensors absent
  readTelemetry(ctx)
  updateStateMachine(ctx)
  if ctx.state == STATE_CONNECTED then
    detectBattery(ctx)        -- auto-select for 1 candidate; else sets pendingSelection
    pollSelectionSticks(ctx)  -- stick navigation while a selection popup is open
    evaluateWarnings(ctx)
    refreshTimeLeft(ctx)      -- snapshot the displayed time-left every 2 s
  end
end

-- Throttled, fault-tolerant wrapper. Called from BOTH background() and refresh():
-- EdgeTX only runs background() while the widget is off-screen, so refresh() must
-- drive it too or the visible tile freezes until a menu round-trip. Throttled to
-- TICK_INTERVAL (10 Hz) so the sample cadence is the same regardless of caller
-- (refresh ~20 Hz). tickImpl runs inside pcall: repeated failures flip the
-- widget into a terminal error state rather than crashing EdgeTX.
local function tick(ctx)
  if ctx.fatalError then return end

  local now = getTime()
  if ctx.lastTick ~= 0 and (now - ctx.lastTick) < TICK_INTERVAL then
    return
  end
  ctx.lastTick = now

  if pcall(tickImpl, ctx) then
    ctx.errorStreak = 0
  else
    ctx.errorStreak = (ctx.errorStreak or 0) + 1
    if ctx.errorStreak >= ERROR_LIMIT then
      ctx.fatalError = true
    end
  end
end

local function background(ctx)
  tick(ctx)
end

-- Picks and draws the appropriate tile for the current state. Wrapped in pcall by
-- refresh() so a rendering fault cannot crash EdgeTX either.
local function drawTile(ctx)
  -- Terminal error first — once set, nothing else is trustworthy.
  if ctx.fatalError then
    drawErrorTile(ctx, "Widget error", "Re-add or restart")
    return
  end

  -- Config / model setup problems.
  if ctx.configError == "missing" then
    drawErrorTile(ctx, "Setup required", "Open Tools/LIPONY")
    return
  end
  if ctx.configError == "parse" or ctx.configError == "schema" then
    drawErrorTile(ctx, "Config invalid", "Open Tools/LIPONY")
    return
  end
  if ctx.modelError == "missing" then
    drawBrandHeading(ctx)
    drawCenteredLines(ctx, {
      "Model not configured",
      '"' .. (activeModelName() or modelFilename() or "?") .. '"',
      "Open Tools/LIPONY",
    })
    return
  end
  if ctx.modelError == "no_batteries" then
    drawErrorTile(ctx, "No batteries assigned", "Open Tools/LIPONY")
    return
  end

  -- Telemetry setup problems.
  if not ctx.hasRxBt or not ctx.hasCapa then
    drawErrorTile(ctx, "Sensor missing", "Discover in EdgeTX")
    return
  end
  if ctx.cellMismatch then
    drawErrorTile(ctx, "Cell count mismatch", "Open Tools/LIPONY")
    return
  end

  -- Battery-selection popup (0 or >1 plausible candidates). Driven by stick
  -- gestures in tick() (pollSelectionSticks); here we only render it. Commit
  -- clears pendingSelection, so the next frame falls through to the live tile.
  if ctx.pendingSelection then
    drawSelectionPopup(ctx)
    drawHeartbeat(ctx)   -- blink the telemetry dot here too (link is live during selection)
    return
  end

  -- State-based tiles.
  if ctx.state == STATE_WAITING then
    drawWaitingTile(ctx)
  elseif ctx.state == STATE_CONNECTED then
    -- Settle window: no resting voltage / battery yet. Reuse the waiting tile instead
    -- of a CONNECTED tile full of "--" (cellMismatch + popup are handled above, so a
    -- nil profile here always means "still settling"). Heartbeat still shows the link.
    if ctx.selectedProfile then
      drawConnectedTile(ctx)
    else
      drawWaitingTile(ctx)
    end
    drawHeartbeat(ctx)
  elseif ctx.state == STATE_ENDED then
    drawEndedTile(ctx)
  end
end

local function refresh(ctx, event, touchEvent)
  tick(ctx)  -- Drive logic in the foreground too (background() won't run then; see tick()).

  -- Pick the palette for this frame from the "Theme" CHOICE option. EdgeTX CHOICE
  -- values are 1-based, so "Dark" = 1, "Light" = 2 (confirmed on hardware). refresh()
  -- is the only draw path and runs one instance at a time, so a module-global active
  -- palette is safe here. Anything other than 2 (incl. unset) falls back to Dark.
  COLORS = (ctx.cfg and ctx.cfg.Theme == 2) and LIGHT or DARK

  -- DARK paints its own panel so the tile looks the same on any radio theme; LIGHT
  -- leaves the background transparent so the radio theme shows through.
  if not COLORS.transparent then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLORS.panel)
  end

  -- Optional milky overlay — Light theme only; Dark always stays solid black.
  -- Pilot sets 0–5, ×3 → alpha 0/3/6/9/12/15 (0 = invisible, 15 = opaque). Drawn in a
  -- theme colour over the (transparent) Light background for a frosted look.
  local trans = ctx.cfg and ctx.cfg.Transparency or 0
  if COLORS.transparent and trans > 0 then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLOR_THEME_PRIMARY2, 3 * trans)
  end

  pcall(drawTile, ctx)
end

return {
  name       = "LIPONY",
  options    = {
    -- Theme dropdown (CHOICE labels are a nested table; the value is the 1-based
    -- index, so default 1 = "Dark"; needs EdgeTX 2.11+). Transparency = milky overlay
    -- 0–5 (default 2), applied in the Light theme only (Dark stays solid black).
    { "Theme", CHOICE, 1, { "Dark", "Light" } },
    { "Transparency", VALUE, 2, 0, 5 },
  },
  create     = create,
  update     = update,
  background = background,
  refresh    = refresh,
}
