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
local STATS_PATH           = "/SCRIPTS/LIPONY/stats.lua"
local SCHEMA_VERSION       = 1
local CONFIG_POLL_INTERVAL = 500  -- 5 s in hundredths of a second (getTime())
local ENDED_TIMEOUT        = 500  -- 5 s without online signal → ENDED
local TICK_INTERVAL        = 10   -- 0.1 s; data-processing cadence (10 Hz)
local REST_VOLTAGE_DELAY   = 100  -- 1 s after CONNECTED before sampling the resting voltage
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

-- Battery chemistries. Per entry: chargeVoltage
-- (100% SoC), dischargeVoltage (0% SoC) and a descending SoC curve of
-- {v_per_cell, soc%} pairs (5% steps), used by lookupNearestSoc().
local CHEMISTRIES = {
  LiPo = {
    chargeVoltage    = 4.20,
    dischargeVoltage = 3.00,
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

  -- Capacity: monotonically increasing (reset on battery change is done by the
  -- state machine). The first value is always accepted.
  if q >= 0 and (ctx.capacity == nil or q >= ctx.capacity) then
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
-- Statistics (cycle counter) persistence
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

-- Writes content to path. Returns true on success. All I/O is pcall-wrapped so a
-- read-only / full SD card never raises a script error.
--
-- io.open "w" does NOT truncate on some EdgeTX/simulator builds, so a shorter
-- write would leave the old file's tail behind (a parse error). Pad with trailing
-- newlines — valid whitespace after the table — up to the previous length so the
-- old content is always fully overwritten.
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

-- Loads stats.lua. A missing file is the legitimate empty start state. A file
-- that exists but cannot be parsed is reported via the second return, so the
-- caller refuses to overwrite it — no silent reset that would wipe the cycle
-- history. Stats are not flight-critical, so the flight itself runs either way.
local function loadStats()
  local ok, f = pcall(io.open, STATS_PATH, "r")
  if not ok or not f then
    return { schemaVersion = SCHEMA_VERSION, instances = {}, archive = {} }
  end
  pcall(io.close, f)

  local pok, result = pcall(dofile, STATS_PATH)
  if not pok or type(result) ~= "table"
     or result.schemaVersion ~= SCHEMA_VERSION
     or type(result.instances) ~= "table" then
    return nil, "parse"
  end
  result.archive = result.archive or {}
  return result
end

-- Cycle count for one physical battery, keyed by its stable pack id (0 if none).
local function cyclesFor(ctx, packId)
  local instances = ctx.stats and ctx.stats.instances
  local entry     = packId and instances and instances[packId]
  return (entry and entry.cycles) or 0
end

-- Re-reads the on-disk stats and applies the pending cycle bumps to it, so a
-- write never clobbers what the tool changed since the widget started (the
-- archive block, or instances it retired). Returns the merged table, or nil if
-- the file exists but is unreadable — then we must leave it untouched.
local function mergeStatsForWrite(ctx)
  local disk = loadStats()      -- missing -> fresh empty; unreadable -> nil
  if not disk then return nil end
  for packId, n in pairs(ctx.pendingBumps) do
    local entry = disk.instances[packId]
    if not entry then entry = { cycles = 0 }; disk.instances[packId] = entry end
    entry.cycles = (entry.cycles or 0) + n
  end
  return disk
end

-- Flushes the pending cycle bumps at flight end. Read-modify-write: the file on
-- disk is the source of truth (it may hold archived packs written by the tool),
-- so we re-read it, add our bumps and write it back — never a blind dump of
-- ctx.stats. An unreadable file is left untouched; a failed write also keeps the
-- bumps pending for a later retry. Only here, at flight end, to spare the SD card.
local function flushStats(ctx)
  if not next(ctx.pendingBumps) then return end
  local merged = mergeStatsForWrite(ctx)
  if not merged then ctx.statsError = true; return end
  local content = "-- Lipo-Nanny statistics: active cycle counts + archived packs.\n"
                  .. "return " .. serialize(merged, "") .. "\n"
  if writeFile(STATS_PATH, content) then
    ctx.stats        = merged       -- refresh the read cache
    ctx.pendingBumps = {}
    ctx.statsError   = false
  end
end

-- Called once at the CONNECTED→ENDED transition: records a +1 cycle bump for each
-- used battery if more than 10% of the profile capacity was drawn this flight
-- (parallel splits the consumption in half, so both share the same result), then
-- flushes the bumps to disk.
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
  flushStats(ctx)
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
      -- Resting voltage: captured once, 1 s after connect, so the reading is
      -- taken at idle rather than under load. Basis for battery detection.
      if ctx.restVoltage == nil and ctx.voltage
         and (now - ctx.connectedSinceTime) >= REST_VOLTAGE_DELAY then
        ctx.restVoltage = ctx.voltage
      end
      -- Average-current accumulator for time-left: one validated-current
      -- sample per tick (10 Hz).
      if ctx.current and ctx.current > 0 then
        ctx.currentSumA        = ctx.currentSumA + ctx.current
        ctx.currentSampleCount = ctx.currentSampleCount + 1
      end
    elseif (now - ctx.lastTelemetryTime) >= ENDED_TIMEOUT then
      captureFlightSummary(ctx)
      finalizeFlight(ctx)   -- cycle-counter evaluation + statistics write
      ctx.state = STATE_ENDED
    end

  elseif ctx.state == STATE_ENDED then
    if online then
      -- Battery change (lost link, then reconnect).
      ctx.state              = STATE_CONNECTED
      ctx.connectedSinceTime = now
      ctx.lastTelemetryTime  = now
      resetFlightState(ctx)
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

-- Remaining flight time in seconds, or nil if not yet computable.
-- Pure data; warmup gating happens in formatTimeLeft.
local function calculateTimeLeftSeconds(ctx)
  if ctx.currentSampleCount == 0 then return nil end
  local avgCurrent = ctx.currentSumA / ctx.currentSampleCount
  if avgCurrent <= 0 then return nil end
  local restPct = calculateRestPct(ctx)
  if not restPct then return nil end
  local effective = effectiveCapacityMah(ctx)
  if not effective then return nil end
  local restMah = effective * restPct / 100
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

-- Bar-fill color (only the bar changes color, text stays neutral).
local function getBarColor(restPct, warnPct, critPct)
  if restPct > warnPct then return lcd.RGB(60, 180, 60)  end   -- green
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

-- Renders the 4-row CONNECTED tile:
--   1) battery label
--   2) bar + percent
--   3) "Time left: …"
--   4) "x.xx V/cell   y.y A"
local function drawConnectedTile(ctx)
  local zone   = ctx.zone
  local w, h   = zone.w, zone.h
  local pad    = sx(2)
  local blockH = 4 * TH
  local startY = math.floor((h - blockH) / 2)
  if startY < 0 then startY = 0 end

  -- Row 1: battery label
  local profileName = ctx.selectedProfile and ctx.selectedProfile.name or nil
  lcd.drawText(pad, startY, formatBatteryLabel(profileName, ctx.selectedInstances))

  -- Row 2: bar + percent
  local barY  = startY + TH
  local barH  = TH - sx(4)
  local barW  = math.floor(w * 0.65)
  lcd.drawRectangle(pad, barY, barW, barH)
  local restPct = calculateRestPct(ctx)
  if restPct and restPct > 0 then
    local fillW = math.floor((barW - 2) * restPct / 100)
    if fillW > 0 then
      local warn, crit = getThresholds(ctx)
      lcd.drawFilledRectangle(pad + 1, barY + 1, fillW, barH - 2, getBarColor(restPct, warn, crit))
    end
  end
  local pctText = restPct and string.format("%d%%", math.floor(restPct + 0.5)) or "--%"
  lcd.drawText(pad + barW + pad, barY, pctText)

  -- Row 3: time left
  lcd.drawText(pad, startY + 2 * TH, "Time left: " .. formatTimeLeft(ctx))

  -- Row 4: V/cell + A
  local vText
  if ctx.voltage and ctx.cells and ctx.cells > 0 then
    vText = string.format("%.2f V/cell", ctx.voltage / ctx.cells)
  else
    vText = "—.- V/cell"
  end
  local aText
  if ctx.current then
    aText = string.format("%.1f A", ctx.current)
  else
    aText = "—.- A"
  end
  lcd.drawText(pad,     startY + 3 * TH, vText)
  lcd.drawText(w - pad, startY + 3 * TH, aText, RIGHT)
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
    lcd.drawText(cx, startY + (i - 1) * TH, lines[i], CENTER)
  end
end

-- WAITING tile: one centered line.
local function drawWaitingTile(ctx)
  drawCenteredLines(ctx, { "Waiting for telemetry…" })
end

-- ENDED tile: 4-row summary of the just-finished flight.
local function drawEndedTile(ctx)
  local w, h   = ctx.zone.w, ctx.zone.h
  local pad    = sx(2)
  local blockH = 4 * TH
  local startY = math.floor((h - blockH) / 2)
  if startY < 0 then startY = 0 end
  local lf = ctx.lastFlight or {}

  -- Row 1: fixed label
  lcd.drawText(pad, startY, "Flight ended")

  -- Row 2: battery label
  lcd.drawText(pad, startY + TH, formatBatteryLabel(lf.profileName, lf.instances))

  -- Row 3: Used X mAh (Y%) — Y% includes the start offset.
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
  lcd.drawText(pad, startY + 2 * TH, usedText)

  -- Row 4: Last: x.xx V/cell
  local lastText
  if lf.lastVoltagePerCell then
    lastText = string.format("Last: %.2f V/cell", lf.lastVoltagePerCell)
  else
    lastText = "Last: —.- V/cell"
  end
  lcd.drawText(pad, startY + 3 * TH, lastText)
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

-- Stick-gesture control for the selection popup. Polled every tick — works in
-- the normal tile without fullscreen, unlike key events (which a widget only
-- receives in fullscreen).
--   Navigate: elevator up/down moves the cursor, one step per deflection
--     (re-armed only after the stick returns to the dead-zone).
--   Confirm: aileron held full-right while the elevator is centred → commit the
--     highlighted entry. The hold keeps it distinct from a quick stick check, and
--     it must be re-armed by recentring the aileron so one held gesture cannot
--     roll through both parallel slots.
-- Flip the signs if a direction feels inverted on hardware.
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
  -- No background fill: the popup draws straight onto the normal widget/theme
  -- background (EdgeTX repaints it each frame).

  local title = ctx.parallel and "SELECT BATTERIES" or "SELECT BATTERY"
  lcd.drawText(math.floor(w / 2), pad, title, CENTER)

  local firstRow = pad + TH
  local legendY  = h - TH                  -- bottom line reserved for the legend

  -- Parallel: once slot 1 is locked in, show it above the slot-2 list.
  if ctx.parallel and ctx.popupSlot == 2 and ctx.slot1Item then
    local s1 = ctx.slot1Item
    lcd.drawText(pad, firstRow, "Slot1: " .. formatBatteryLabel(s1.profile.name, { { pos = s1.pos } }))
    firstRow = firstRow + TH
  end

  local list = activeSelectionList(ctx)
  if #list == 0 then
    lcd.drawText(pad, firstRow, "No profiles")
    return
  end

  local cursor  = ctx.popupCursor or 1
  local maxRows = math.max(1, math.floor((legendY - firstRow) / TH))

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
    local item   = list[i]
    local label  = formatBatteryLabel(item.profile.name, { { pos = item.pos } })
    local cyc    = cyclesFor(ctx, item.packId)
    local prefix = (i == cursor) and "> " or "  "
    lcd.drawText(pad, y, prefix .. label .. " (" .. cyc .. "c)")
    y = y + TH
  end

  -- Gesture legend. ASCII only — the EdgeTX font has no arrow glyphs.
  lcd.drawText(pad, legendY, "ele: up/dn  ail: > OK")
end

-- Generic 2-line error tile.
local function drawErrorTile(ctx, line1, line2)
  drawCenteredLines(ctx, { line1, line2 })
end

local function create(zone, options)
  local ctx = {
    -- Display zone
    zone = zone,

    -- Widget options (see table at end of file); cfg.Transparency = opacity 0–5.
    cfg = options,

    -- State machine
    state = STATE_WAITING,
    lastTelemetryTime = 0,
    connectedSinceTime = 0,
    lastTick = 0,

    -- Config + reload polling
    config = nil,
    configError = nil,
    lastGeneration = nil,
    lastConfigPoll = 0,

    -- Stats — loaded below. The widget owns the active cycle counts; the tool owns
    -- the archive block. pendingBumps holds cycles earned but not yet written
    -- (survives failed writes for retry); statsError flags an unreadable file we
    -- must not overwrite.
    stats = nil,
    statsError = false,
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
  local loaded, statsErr = loadStats()
  ctx.statsError = statsErr ~= nil
  if ctx.statsError then
    -- Keep a usable empty table for reads; the flush path refuses to write while
    -- statsError is set, so the unreadable file on disk is preserved.
    ctx.stats = { schemaVersion = SCHEMA_VERSION, instances = {}, archive = {} }
  else
    ctx.stats = loaded
  end
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
    drawCenteredLines(ctx, {
      "Model not configured",
      '"' .. (modelFilename() or "?") .. '"',
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
    return
  end

  -- State-based tiles.
  if ctx.state == STATE_WAITING then
    drawWaitingTile(ctx)
  elseif ctx.state == STATE_CONNECTED then
    drawConnectedTile(ctx)
  elseif ctx.state == STATE_ENDED then
    drawEndedTile(ctx)
  end
end

local function refresh(ctx, event, touchEvent)
  tick(ctx)  -- Drive logic in the foreground too (background() won't run then; see tick()).

  -- Optional semi-transparent background. Pilot sets 0–5,
  -- ×3 → alpha 0/3/6/9/12/15 (0 = invisible, 15 = opaque).
  local trans = ctx.cfg and ctx.cfg.Transparency or 0
  if trans > 0 then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLOR_THEME_PRIMARY2, 3 * trans)
  end

  pcall(drawTile, ctx)
end

return {
  name       = "LIPONY",
  options    = {
    { "Transparency", VALUE, 2, 0, 5 },
  },
  create     = create,
  update     = update,
  background = background,
  refresh    = refresh,
}
