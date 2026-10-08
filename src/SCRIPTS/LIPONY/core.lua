-- =====================================================================
-- core.lua  --  Shared core for Lipo-Nanny.
-- =====================================================================
-- SD card path: /SCRIPTS/LIPONY/core.lua
--
-- Single source of truth used by BOTH scripts (must be installed alongside
-- whichever is used):
--   * the widget       /WIDGETS/LIPONY/main.lua       (display consumes this)
--   * the settings tool /SCRIPTS/TOOLS/FLIGHTBAG.lua  (config editor)
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
-- Single source of the version: the settings tool reads VERSION, API and
-- CONFIG_PATH as text from the head of this file (keep them near the top).
Core.VERSION = "2.0.0"
Core.API     = { 1, 0 }
Core.CONFIG_PATH = "/SCRIPTS/LIPONY/config.lua"
-- API is the interface version for scripts that load this core: { breaking, additive }.
-- Adding an exported function or field bumps the second number; changing or
-- removing one bumps the first and resets the second. Fixes and internal
-- changes leave it alone. A loader accepts the same first and at least its second.

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local CONFIG_PATH          = Core.CONFIG_PATH
local SCHEMA_VERSION       = 1
Core.SCHEMA_VERSION = SCHEMA_VERSION

local CONFIG_POLL_INTERVAL  = 500  -- 5 s in hundredths of a second (getTime())
local SENSOR_CHECK_INTERVAL = 100  -- 1 s; sensor existence is model config, 1 s cache is plenty
local TIME_LEFT_INTERVAL    = 200  -- 2 s; how often the DISPLAYED time-left is refreshed
local SETTLE_DELAY          = 300  -- 3 s after PRE starts before sampling resting voltage and
                                   -- latching mAh — lets stale telemetry from the last flight clear

-- Default telemetry sensor names (CRSF/ELRS standard). A model may override these
-- per the config's sensors block. The Tools-Script reads this to keep the stored
-- config sparse (only names that differ are written) and to label the picker.
local DEFAULT_SENSORS = { voltage = "RxBt", current = "Curr", capacity = "Capa" }
Core.DEFAULT_SENSORS = DEFAULT_SENSORS
local DEFAULT_SENSOR_VOLTAGE  = DEFAULT_SENSORS.voltage
local DEFAULT_SENSOR_CURRENT  = DEFAULT_SENSORS.current
local DEFAULT_SENSOR_CAPACITY = DEFAULT_SENSORS.capacity

-- Warning sounds. The config stores only a file name from SOUND_DIR under
-- sounds.<key> (false = muted, absent = the default; a missing custom file
-- falls back to the default).
Core.SOUND_DIR      = "/SOUNDS/en/SCRIPTS/LIPONY/"
Core.SOUND_KEYS     = { "warn", "crit", "charge" }
Core.SOUND_DEFAULTS = { warn = "warn.wav", crit = "crit.wav", charge = "charge.wav" }

-- Optional haptic alongside the warning sounds, off by default: pulse length per
-- strength tier (tune on the radio) and pulses per warning (critical buzzes twice).
local HAPTIC_DUR = { [1] = 15, [2] = 30, [3] = 50 }
Core.HAPTIC_DUR    = HAPTIC_DUR
Core.HAPTIC_PULSES = { warn = 1, crit = 2, charge = 1 }

-- Editable ranges and factory defaults, keyed like the config: the single source
-- for defaultConfig(), getThresholds(), normalizeConfig() and the settings tool.
-- warnPct must stay above critPct (remaining-capacity %). cells, capacityMah and
-- wear are the battery profile / model fields; one cell range for both, since
-- profile.cells must match model.cells for battery detection.
local LIMITS = {
  warnPct        = { min = 1, max = 99, step = 1 },
  critPct        = { min = 1, max = 99, step = 1 },
  hapticStrength = { min = 1, max = 3,  step = 1 },
  cells          = { min = 1, max = 30, step = 1 },
  capacityMah    = { min = 10, max = 50000, step = 100 },
  wear           = { min = 0, max = 50, step = 1 },
}
local DEFAULTS = { warnPct = 30, critPct = 20, audio = true, haptic = false, hapticStrength = 2,
                   cells = 6, capacityMah = 1300 }
Core.LIMITS   = LIMITS
Core.DEFAULTS = DEFAULTS

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

local function serializeScalar(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return quoteString(v) end
  return "nil"
end

-- One open table of a running serialization: its keys (array part first, then the
-- hash part) and the parts serialized so far. `prefix` is the text before this
-- table in its parent ("  [\"key\"] = ").
local function serialFrame(t, indent, prefix)
  local keys, n = {}, #t
  for i = 1, n do keys[i] = i end
  for k in pairs(t) do
    if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then
      keys[#keys + 1] = k
    end
  end
  return { t = t, keys = keys, n = n, i = 0, indent = indent, next = indent .. "  ",
           parts = {}, prefix = prefix }
end

-- Serialization that can be split across calls, so the widget stays under its
-- per-call instruction limit on a large config.
local function newSerialJob(value)
  return { stack = { serialFrame(value, "", "") } }
end

-- Serializes up to `budget` values; true once done (the text is then in job.text).
local function stepSerial(job, budget)
  local stack = job.stack
  while budget > 0 do
    local f = stack[#stack]
    f.i = f.i + 1
    local k = f.keys[f.i]
    if k == nil then
      local s = "{}"
      if #f.parts > 0 then
        s = "{\n" .. table.concat(f.parts, ",\n") .. ",\n" .. f.indent .. "}"
      end
      stack[#stack] = nil
      local parent = stack[#stack]
      if not parent then job.text = s; return true end
      parent.parts[#parent.parts + 1] = f.prefix .. s
    else
      local prefix = f.next
      if f.i > f.n then
        prefix = prefix .. "[" .. (type(k) == "string" and quoteString(k) or tostring(k)) .. "] = "
      end
      local v = f.t[k]
      if type(v) == "table" then
        stack[#stack + 1] = serialFrame(v, f.next, prefix)
      else
        f.parts[#f.parts + 1] = prefix .. serializeScalar(v)
      end
    end
    budget = budget - 1
  end
  return false
end

-- Serializes a Lua value back into source text in one go. Handles the array part
-- and the remaining hash part with string/number keys. Functions/userdata are not
-- expected.
local function serialize(value)
  if type(value) ~= "table" then return serializeScalar(value) end
  local job = newSerialJob(value)
  stepSerial(job, math.huge)
  return job.text
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

-- True unless fstat positively says the file is gone. fstat is absent on the
-- desktop and pcall-guarded, so "unknown" keeps the custom name (no regression).
local function soundFileExists(name)
  if not fstat then return true end
  local ok, info = pcall(fstat, Core.SOUND_DIR .. name)
  return not ok or info ~= nil
end

-- Sound override: a string is a custom file name (an older full path is cut to its
-- name; dropped to the default when the file no longer exists on the card, so the
-- warning still sounds), `false` means the user muted this warning, and anything
-- else (nil / garbage) is the default (nil) so no junk ever reaches playFile.
local function soundOr(v)
  if type(v) == "string" then
    local name = string.match(v, "[^/]+$")
    if name and soundFileExists(name) then return name end
    return nil
  end
  if v == false then return false end
  return nil
end

local function clampNum(n, lo, hi, fallback)
  if type(n) ~= "number" then return fallback end
  if n < lo then return lo elseif n > hi then return hi end
  return n
end

-- Normalises a parsed config into a copy: settings clamped to LIMITS (wrong types
-- fall back to DEFAULTS), sounds as file names, older layouts converted (defaults
-- block and warn_pct / crit_pct become warnPct / critPct, also per profile, full
-- sound paths become file names). Unknown entries are kept as they are, so a
-- setting written by a newer version survives a save through this one. Profile
-- overrides stay optional (nil = follow the general value).
local function normalizeConfig(cfg)
  local out = {}
  if type(cfg) == "table" then for k, v in pairs(cfg) do out[k] = v end end
  local old = type(out.defaults) == "table" and out.defaults or {}
  if out.warnPct == nil then out.warnPct = old.warn_pct end
  if out.critPct == nil then out.critPct = old.crit_pct end
  out.defaults = nil
  local L = LIMITS
  out.warnPct        = clampNum(out.warnPct, L.warnPct.min, L.warnPct.max, DEFAULTS.warnPct)
  out.critPct        = clampNum(out.critPct, L.critPct.min, L.critPct.max, DEFAULTS.critPct)
  if type(out.audio) ~= "boolean" then out.audio = DEFAULTS.audio end
  if type(out.haptic) ~= "boolean" then out.haptic = DEFAULTS.haptic end
  out.hapticStrength = clampNum(out.hapticStrength, L.hapticStrength.min, L.hapticStrength.max,
                                DEFAULTS.hapticStrength)
  local snd, sounds = (type(out.sounds) == "table") and out.sounds or {}, {}
  for k, v in pairs(snd) do sounds[k] = v end
  for _, k in ipairs(Core.SOUND_KEYS) do sounds[k] = soundOr(snd[k]) end
  out.sounds = sounds
  -- Non-table battery entries (hand-edited file) are dropped instead of crashing later.
  local bats = {}
  for _, b in ipairs(type(out.batteries) == "table" and out.batteries or {}) do
    if type(b) == "table" then
      if b.warnPct == nil then b.warnPct = b.warn_pct end
      if b.critPct == nil then b.critPct = b.crit_pct end
      b.warn_pct, b.crit_pct = nil, nil
      bats[#bats + 1] = b
    end
  end
  out.batteries = bats
  if type(out.archive) ~= "table" then out.archive = {} end
  if type(out.models) ~= "table" then out.models = {} end
  return out
end

-- Loads and validates the config file. Returns (configTable) on success, or
-- (nil, errKind[, detail]) where errKind is "missing" | "parse" | "schema".
-- The widget ignores `detail`; the Tools-Script surfaces it on the error screen.
-- keepSounds: custom sound names stay even while the file is missing, so a
-- flight-end save never drops them (playback falls back to the default).
local function loadConfig(keepSounds)
  local ok, f = pcall(io.open, CONFIG_PATH, "r")
  if not ok or not f then return nil, "missing" end
  pcall(io.close, f)

  -- Text only, no .luac: the radio would prefer a compiled copy with the same
  -- 2 s FAT timestamp over a newer config.lua.
  local cok, chunk, err = pcall(loadScript, CONFIG_PATH, "tx")
  if not cok or not chunk then return nil, "parse", tostring(err or chunk) end
  local pok, result = pcall(chunk)
  if not pok then return nil, "parse", tostring(result) end
  if type(result) ~= "table" then return nil, "parse", "not a table" end
  if result.schemaVersion ~= SCHEMA_VERSION then
    return nil, "schema", tostring(result.schemaVersion)
  end
  if type(result.generation) ~= "number" then
    return nil, "schema", "generation"
  end
  local cfg = normalizeConfig(result)
  if keepSounds and type(result.sounds) == "table" then
    for _, k in ipairs(Core.SOUND_KEYS) do
      local v = result.sounds[k]
      if type(v) == "string" then cfg.sounds[k] = string.match(v, "[^/]+$") end
    end
  end
  return cfg
end

-- Increments the reload sentinel and writes the whole config back. The generation
-- bump makes a running widget pick up the change on its next poll. Returns true on
-- success.
local CONFIG_HEADER = "-- Lipo-Nanny configuration (auto-generated by the Tools-Script).\nreturn "

local function saveConfig(config)
  config.generation = (config.generation or 0) + 1
  return writeFile(CONFIG_PATH, CONFIG_HEADER .. serialize(config) .. "\n")
end

-- Factory defaults. Returns a FRESH table on every call (no shared references and
-- no overlay of a loaded config), so "Reset to defaults" always restores the true
-- factory values rather than echoing whatever is currently saved.
local function defaultConfig()
  return {
    schemaVersion = SCHEMA_VERSION,
    generation    = 0,
    nextPackId    = 1,
    nextBatteryId = 1,
    warnPct       = DEFAULTS.warnPct,
    critPct       = DEFAULTS.critPct,
    audio         = DEFAULTS.audio,
    haptic        = DEFAULTS.haptic,
    hapticStrength = DEFAULTS.hapticStrength,
    batteries     = {},
    archive       = {},
    sounds        = {},
    models        = {},
  }
end

-- Settings back to factory values (thresholds, sounds); batteries, models and
-- statistics stay, and so do the shared settings (audio, haptic), which are set once for
-- all scripts in the settings tool. Returns true on success; false without a readable
-- config, so a damaged file is never overwritten.
local function resetSettings()
  local cfg = loadConfig()
  if not cfg then return false end
  cfg.warnPct, cfg.critPct, cfg.sounds = DEFAULTS.warnPct, DEFAULTS.critPct, {}
  return saveConfig(cfg)
end

-- Zeroes every pack's cycle count and statistics and empties the archive;
-- profiles and models stay. Returns true on success.
local function resetStats()
  local cfg = loadConfig()
  if not cfg then return false end
  for _, b in ipairs(cfg.batteries) do
    for _, inst in ipairs(b.instances or {}) do
      inst.cycles, inst.totalMah, inst.lastUsed, inst.minVCell = 0, 0, nil, nil
    end
  end
  cfg.archive = {}
  return saveConfig(cfg)
end

-- Everything erased (batteries, models, statistics, settings) except the shared
-- settings. The pack-id counter safely restarts at 1: nothing survives that a
-- fresh id could collide with. Returns true on success.
local function factoryReset()
  local cfg, fresh = loadConfig(), defaultConfig()
  if cfg then
    fresh.audio, fresh.haptic, fresh.hapticStrength = cfg.audio, cfg.haptic, cfg.hapticStrength
    fresh.generation = cfg.generation
  end
  return saveConfig(fresh)
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

-- getFieldInfo is nil for a sensor that was never discovered; getValue would give 0.
local function sensorExists(name)
  local ok, info = pcall(getFieldInfo, name)
  return ok and info ~= nil
end

-- Existence per sensor, re-checked at most every `interval` (same unit as `now`).
-- names = { key = "SensorName", ... }; returns the cached { key = true/false }.
local function sensorsPresent(state, names, now, interval)
  if state.sensorCheckAt == nil or now - state.sensorCheckAt >= interval then
    state.sensorCheckAt = now
    local has = {}
    for key, name in pairs(names) do has[key] = sensorExists(name) end
    state.sensorsPresent = has
  end
  return state.sensorsPresent
end

-- True while EdgeTX receives telemetry (any protocol).
local function linkUp()
  return getRSSI() ~= 0
end

-- Debounced loss: true once the link has been down for `grace` (same unit as `now`).
-- state.linkLostSince is nil while the link is up.
local function linkLost(state, up, now, grace)
  if up then
    state.linkLostSince = nil
    return false
  end
  state.linkLostSince = state.linkLostSince or now
  return now - state.linkLostSince >= grace
end

-- Disarmed marker in the FM text: Betaflight appends * ! ?, ArduPilot *,
-- INAV sends OK / WAIT / !ERR. "!FS!" (failsafe) is armed despite its "!".
local INAV_DISARMED = { OK = true, WAIT = true, ["!ERR"] = true }
local function fmDisarmed(fm)
  if fm == "!FS!" then return false end
  if INAV_DISARMED[fm] then return true end
  local last = string.sub(fm, -1)
  return last == "*" or last == "!" or last == "?"
end

-- armed, known. Known only once a disarmed marker was seen on this link
-- (state.disarmSeen): some setups never send one, and a text without a marker
-- alone proves nothing. Clear state.disarmSeen when the flight ends.
local function armedFromFM(state, fm)
  if type(fm) ~= "string" or fm == "" then return false, false end
  if fmDisarmed(fm) then
    state.disarmSeen = true
    return false, true
  end
  if not state.disarmSeen then return false, false end
  return true, true
end

-- Flight phases, word for word the same in every script. They pick the page:
-- WAITING (no link) -> PRE (link up) -> FLIGHT (armed, or the app's preflight
-- check met for PRE_HOLD_T without a break) -> ENDED (link lost LINK_LOSS_T)
-- -> WAITING after ENDED_HOLD_T. No way back from FLIGHT to PRE (a disarm keeps
-- FLIGHT). A loss in PRE goes straight to WAITING (no flight). A loss while
-- armed is a link failure: back within ENDED_HOLD_T, the same flight goes on.
-- Display only: logic that needs the real armed state reads armedFromFM.
-- Times in ms. Returns the phase and an event: "new" (a new flight starts in
-- PRE), "lost" (PRE -> WAITING), "end" (FLIGHT -> ENDED, s.linkFailure tells
-- why), "resume" (link back after a failure) or "over" (ENDED_HOLD_T without
-- link), else nil.
local LINK_LOSS_T, ENDED_HOLD_T, PRE_HOLD_T = 1500, 30000, 15000
local function flightPhase(s, up, armed, ready, now)
  local phase, event = s.phase or "WAITING", nil
  local lost = linkLost(s, up, now, LINK_LOSS_T)
  if up then s.armedBeforeLoss = armed == true end
  if phase == "WAITING" then
    if up then phase, event = "PRE", "new" end
  elseif phase == "ENDED" then
    if up and s.linkFailure then
      phase, event = "FLIGHT", "resume"
    elseif up then
      phase, event = "PRE", "new"
    elseif now - s.endedAt >= ENDED_HOLD_T then
      phase, event = "WAITING", "over"
    end
    if phase ~= "ENDED" then s.linkFailure = nil end
  elseif phase == "FLIGHT" then
    if lost then
      phase, event, s.endedAt, s.linkFailure = "ENDED", "end", now, s.armedBeforeLoss
    end
  elseif lost then
    phase, event = "WAITING", "lost"
  elseif up then
    if not ready then s.readySince = nil elseif not s.readySince then s.readySince = now end
    if armed or (s.readySince and now - s.readySince >= PRE_HOLD_T) then phase = "FLIGHT" end
  end
  if phase ~= "PRE" then s.readySince = nil end
  s.phase = phase
  return phase, event
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
-- clear "Sensor missing" hint instead of computing on absent values.
local function checkSensors(ctx)
  local names = ctx.sensorNames
  if names.voltage ~= ctx.sensorVoltage or names.current ~= ctx.sensorCurrent
     or names.capacity ~= ctx.sensorCapacity then
    -- Remapped in the config: new names table, re-check at once.
    names = { voltage = ctx.sensorVoltage, current = ctx.sensorCurrent, capacity = ctx.sensorCapacity }
    ctx.sensorNames   = names
    ctx.sensorCheckAt = nil
  end
  local has = sensorsPresent(ctx, names, getTime(), SENSOR_CHECK_INTERVAL)
  ctx.hasRxBt, ctx.hasCurr, ctx.hasCapa = has.voltage, has.current, has.capacity
end

-- Link up and a flight going on or about to (phase PRE or FLIGHT).
local function isActive(ctx)
  return ctx.phase == "PRE" or ctx.phase == "FLIGHT"
end


-- Reads the three sensors and the link state, applies plausibility filters and
-- keeps the last valid value on ctx (invalid samples dropped). Voltage validation
-- needs ctx.cells.
local function readTelemetry(ctx)
  local v = safeGetValue(ctx.sensorVoltage)
  local i = safeGetValue(ctx.sensorCurrent)
  local q = safeGetValue(ctx.sensorCapacity)
  local link = linkUp()
  ctx.linkUp = link
  if link then
    -- Armed state from the CRSF flight mode text (true only when known armed),
    -- for the flight phase.
    local okFm, fm = pcall(getValue, "FM")
    ctx.armed = armedFromFM(ctx, okFm and fm or nil)
  end

  -- FC on USB (no battery): link live but voltage, current and capacity all zero.
  -- All three never glitch to zero at once, so no debounce is needed.
  ctx.noBatterySignal = link and v == 0 and i == 0 and q == 0

  -- Voltage: [0.5 V × cells … 5 V × cells]
  local cells = ctx.cells
  if cells and v >= 0.5 * cells and v <= 5 * cells then
    ctx.voltage = v
  end

  -- Current: ≥ 0, and only when the sensor exists (else leave nil → "—.- A").
  if ctx.hasCurr and i >= 0 then
    ctx.current = i
  end

  -- Capacity sensor sending remaining % (e.g. ArduPilot over FrSky): convert to
  -- consumed mAh against the nominal capacity of the selected pack(s), which the FC
  -- must use as well. Needs a selection, so nothing latches before one is made.
  if ctx.capacityPct then
    local p, inst = ctx.selectedProfile, ctx.selectedInstances
    if p and p.capacityMah and inst and q >= 0 and q <= 100 then
      q = (100 - q) / 100 * p.capacityMah * #inst
    else
      q = -1
    end
  end

  -- Capacity (consumed mAh). After a dropout EdgeTX still reports the previous
  -- flight's high Capa until the new RX sends a fresh (zeroed) frame, so only start
  -- latching after the SETTLE_DELAY window — by then the stale value is gone. Then
  -- monotonic up only.
  if q >= 0 and isActive(ctx)
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
  ctx.capacityPct    = false

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
    ctx.capacityPct = s.capacityUnit == "pct"
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

local function isOnline(ctx)
  return ctx.linkUp
end

-- Settle window elapsed, link live, but no battery ever reported → FC on USB.
-- Self-correcting: once a real pack reports, restVoltage is set and this is false.
local function isUsbConnected(ctx)
  return isActive(ctx)
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
  ctx.chargePending       = false
  ctx.currentSumA         = 0
  ctx.currentSampleCount  = 0
  ctx.timeLeftStr         = nil   -- recompute the displayed time-left promptly
  ctx.timeLeftStamp       = nil
  ctx.restVoltage         = nil
  ctx.minVCell            = nil   -- lowest per-cell voltage seen this flight (statistics)
  ctx.minVoltage          = nil   -- pack voltage and current extremes this flight, for
  ctx.maxVoltage          = nil   -- scripts that load the core (not shown by the widget)
  ctx.maxCurrent          = nil
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
  ctx.bookedMah           = nil   -- per-pack mAh already saved this flight (link failure)
  ctx.bookedCycle         = nil   -- packs already given their cycle this flight
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

-- Values serialized per tick while saving at flight end: keeps each widget call
-- well under the 20,000-instruction limit, whatever the config size.
local SAVE_STEP_VALUES = 100

-- Adds one pack's flight statistics to a pending table (mAh summed, newest date,
-- lowest cell voltage).
local function addPendingStats(pending, id, mah, lastUsed, minVCell)
  local st = pending[id] or {}
  st.mah = (st.mah or 0) + (mah or 0)
  if lastUsed and (not st.lastUsed or lastUsed > st.lastUsed) then st.lastUsed = lastUsed end
  if minVCell and (not st.minVCell or minVCell < st.minVCell) then st.minVCell = minVCell end
  pending[id] = st
end

-- Hands the deltas of a failed save back to ctx (on top of any a newer flight added),
-- so the next flight end retries them.
local function restorePending(ctx, bumps, stats)
  for id, n in pairs(bumps) do ctx.pendingBumps[id] = (ctx.pendingBumps[id] or 0) + n end
  for id, st in pairs(stats) do
    addPendingStats(ctx.pendingStats, id, st.mah, st.lastUsed, st.minVCell)
  end
end

-- Read-modify-write: re-reads config.lua (so tool edits survive), adds the deltas
-- onto its instances and starts serializing it; stepSave() finishes over the next
-- ticks. A bump for a vanished pack is dropped.
local function startSave(ctx, bumps, stats)
  local fresh = loadConfig(true)
  if not fresh then restorePending(ctx, bumps, stats); return end
  for _, b in ipairs(fresh.batteries or {}) do
    for _, inst in ipairs(b.instances or {}) do
      local n = bumps[inst.id]
      if n then inst.cycles = (inst.cycles or 0) + n end
      local st = stats[inst.id]
      if st then
        if st.mah then inst.totalMah = (inst.totalMah or 0) + math.floor(st.mah + 0.5) end
        if st.lastUsed then inst.lastUsed = st.lastUsed end
        if st.minVCell and (not inst.minVCell or st.minVCell < inst.minVCell) then
          inst.minVCell = st.minVCell
        end
      end
    end
  end
  local baseGen = fresh.generation
  fresh.generation = baseGen + 1
  ctx.saveJob = { cfg = fresh, baseGen = baseGen, bumps = bumps, stats = stats,
                  serial = newSerialJob(fresh) }
end

-- Saves the pending deltas unless a save is already running (its end picks them up).
local function flushPending(ctx)
  if ctx.saveJob or (not next(ctx.pendingBumps) and not next(ctx.pendingStats)) then return end
  local bumps, stats = ctx.pendingBumps, ctx.pendingStats
  ctx.pendingBumps, ctx.pendingStats = {}, {}
  startSave(ctx, bumps, stats)
end

-- Advances a running save by one step per tick; the write gets a tick of its own.
local function stepSave(ctx)
  local job = ctx.saveJob
  if not job then return end
  if not job.serial.text then
    stepSerial(job.serial, SAVE_STEP_VALUES)
    return
  end
  ctx.saveJob = nil
  local cur = loadConfig()
  if cur and cur.generation ~= job.baseGen then
    startSave(ctx, job.bumps, job.stats)   -- the tool saved meanwhile: redo on its version
  elseif cur and writeFile(CONFIG_PATH, CONFIG_HEADER .. job.serial.text .. "\n") then
    ctx.config         = job.cfg            -- refresh the read cache (incl. bumped cycles)
    ctx.lastGeneration = job.cfg.generation -- our own write; don't re-adopt it next poll
    flushPending(ctx)                       -- a flight that ended during the save
  else
    restorePending(ctx, job.bumps, job.stats)
  end
end

-- Called at every FLIGHT→ENDED transition (and a link loss in PRE): records a +1 cycle bump for each
-- used pack that drew more than 10% of its capacity this flight (parallel splits the
-- consumption evenly), records the per-pack statistics (consumed mAh, last-used date,
-- lowest cell voltage), then starts saving them to config.lua. A flight resumed
-- after a link failure ends again: only what was not saved yet is added.
local function finalizeFlight(ctx)
  local profile   = ctx.selectedProfile
  local instances = ctx.selectedInstances
  if profile and profile.capacityMah and instances and #instances > 0 then
    -- The consumed mAh is split evenly across the used packs (50/50 in parallel).
    local perBattery = (ctx.capacity or 0) / #instances
    local booked     = ctx.bookedMah or 0
    ctx.bookedMah    = math.max(booked, perBattery)
    ctx.bookedCycle  = ctx.bookedCycle or {}
    local dt   = getDateTime()
    local date = string.format("%04d-%02d-%02d", dt.year, dt.mon, dt.day)
    for _, inst in ipairs(instances) do
      if inst.id then
        local effCap = profile.capacityMah * (1 - (inst.wear or 0) / 100)
        -- Cycle: only when the pack drew more than 10% of ITS effective capacity.
        if effCap > 0 and perBattery > 0.10 * effCap and not ctx.bookedCycle[inst.id] then
          ctx.pendingBumps[inst.id] = (ctx.pendingBumps[inst.id] or 0) + 1
          ctx.bookedCycle[inst.id]  = true
        end
        -- Statistics: recorded for every used pack, independent of the cycle threshold.
        addPendingStats(ctx.pendingStats, inst.id, math.max(0, perBattery - booked), date, ctx.minVCell)
      end
    end
  end
  flushPending(ctx)
end

-- ---------------------------------------------------------------------------
-- Flight state machine
-- ---------------------------------------------------------------------------

-- Drives the flight phase (flightPhase) and what each phase does. Must run
-- after readTelemetry so that the link state reflects the latest sample.
-- ready: the preflight check is met (preflightMet, worked out by tick).
local function updateStateMachine(ctx, ready)
  local now = getTime()
  local online = isOnline(ctx)
  local _, event = flightPhase(ctx, online, ctx.armed, ready, now * 10)
  if event == "new" then
    ctx.connectedSinceTime = now
    resetFlightState(ctx)
  elseif event == "end" then
    captureFlightSummary(ctx)
    finalizeFlight(ctx)   -- cycle-counter evaluation + statistics save
  elseif event == "lost" then
    -- Link gone before the flight page: no summary, a chosen pack is saved as
    -- before (without arming it draws far below a cycle). Clears the popup.
    finalizeFlight(ctx)
    resetFlightState(ctx)
  end
  if event == "lost" or event == "over" or (event == "end" and not ctx.linkFailure) then
    ctx.disarmSeen = nil   -- flight over: new proof needed
  end

  if online and isActive(ctx) and event == nil then   -- not in the tick that starts or resumes
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
    -- Pack voltage and current extremes this flight (kept through ENDED).
    local v, i = ctx.voltage, ctx.current
    if v then
      if not ctx.minVoltage or v < ctx.minVoltage then ctx.minVoltage = v end
      if not ctx.maxVoltage or v > ctx.maxVoltage then ctx.maxVoltage = v end
    end
    if i and (not ctx.maxCurrent or i > ctx.maxCurrent) then ctx.maxCurrent = i end
  end
end

-- ---------------------------------------------------------------------------
-- Derived metrics (thresholds, remaining %, remaining time)
-- ---------------------------------------------------------------------------

-- Clamp a threshold into the editable range; a non-number falls back to `fallback`.
local function clampPct(v, fallback)
  return clampNum(v, LIMITS.warnPct.min, LIMITS.warnPct.max, fallback)
end

-- Returns (warnPct, critPct): profile overrides win over the general values, both
-- clamped and falling back to the factory DEFAULTS.
local function getThresholds(ctx)
  local profile = ctx.selectedProfile or {}
  local cfg     = ctx.config or {}
  local warn = clampPct(profile.warnPct or cfg.warnPct, DEFAULTS.warnPct)
  local crit = clampPct(profile.critPct or cfg.critPct, DEFAULTS.critPct)
  return warn, crit
end

-- Effective total capacity in mAh: sum over the selected packs of
-- profile.capacityMah × (1 − wear/100). Wear shrinks the usable capacity so the
-- Preflight check of the battery from the remaining % and the thresholds:
-- PACK READY (level 0), BATTERY LOW at the warning level (1) or the critical one
-- (2). pct nil (not known yet in the first seconds) counts as full.
local function preflight(pct, warn, crit)
  pct = pct or 100
  local level = (pct <= crit and 2) or (pct <= warn and 1) or 0
  return { text = (level > 0) and "BATTERY LOW" or "PACK READY", level = level }
end

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

-- Level of the pack voltage from its per-cell voltage and the chemistry's
-- thresholds: 0 OK, 1 warning, 2 critical; nil without a voltage, 0 when the
-- chemistry or the cell count is unknown.
local function voltageLevel(ctx)
  if not ctx.voltage then return nil end
  local profile = ctx.selectedProfile
  local chem    = profile and CHEMISTRIES[profile.chemistry]
  if not chem or not chem.voltageWarn or not ctx.cells or ctx.cells <= 0 then return 0 end
  local vpc = ctx.voltage / ctx.cells
  if vpc >= chem.voltageWarn then return 0 end
  if vpc >= chem.voltageCrit then return 1 end
  return 2
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

-- "calc.." during the first 60 s after PRE starts, "--:--" when the value is
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

  -- A pack already below the warn threshold at connect gets the "not charged"
  -- announcement instead: "return home" / "land now" make no sense on the
  -- ground, so only thresholds crossed later play them.
  local warn, crit = getThresholds(ctx)
  ctx.warnPlayed    = soc <= warn
  ctx.critPlayed    = soc <= crit
  ctx.chargePending = soc <= warn
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

-- Vibrate with a warning, HAPTIC_PULSES[key] pulses (critical buzzes twice). No-op when haptic
-- is off or playHaptic is absent (sim / motorless radio), so it never affects the logic.
local function warnHaptic(ctx, key)
  local cfg = ctx.config
  if not cfg or cfg.haptic ~= true or not playHaptic then return end
  local L = LIMITS.hapticStrength
  local s = clampNum(cfg.hapticStrength, L.min, L.max, DEFAULTS.hapticStrength)
  local dur    = HAPTIC_DUR[s] or HAPTIC_DUR[DEFAULTS.hapticStrength]
  local pulses = Core.HAPTIC_PULSES[key] or 1
  for i = 1, pulses do
    playHaptic(dur, (i < pulses) and dur or 0)   -- gap between pulses, none after the last
  end
end

-- Restarts the backlight timeout so a dark display lights up with a warning.
local function wakeDisplay()
  if lcd and lcd.resetBacklightTimeout then lcd.resetBacklightTimeout() end
end

-- Sound, haptic and backlight for one warning. A muted warning (sounds.x ==
-- false, or all sounds off via audio == false) skips playFile but still
-- buzzes: the haptic cue has its own on/off setting.
local function alert(ctx, key)
  local sounds = (ctx.config and ctx.config.sounds) or {}
  local audio = not (ctx.config and ctx.config.audio == false)
  local f = soundOr(sounds[key])
  if f == nil then f = Core.SOUND_DEFAULTS[key] end
  if f and audio then playFile(Core.SOUND_DIR .. f) end
  warnHaptic(ctx, key)
  wakeDisplay()
end

-- Plays "not charged" once for a pack already low at connect, then the warn /
-- crit voice file once each as the remaining percentage drops past the
-- thresholds. No debounce: the mAh counter only rises, so each threshold is
-- crossed exactly once per flight.
local function evaluateWarnings(ctx)
  if not ctx.selectedProfile then return end
  if ctx.chargePending then
    ctx.chargePending = false
    alert(ctx, "charge")
  end
  local restPct = calculateRestPct(ctx)
  if not restPct then return end

  local warn, crit = getThresholds(ctx)
  if not ctx.warnPlayed and restPct <= warn then
    ctx.warnPlayed = true
    alert(ctx, "warn")
  end
  if not ctx.critPlayed and restPct <= crit then
    ctx.critPlayed = true
    alert(ctx, "crit")
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
-- Per-tick pipeline
-- ---------------------------------------------------------------------------

-- Setup errors of the active model that need no telemetry, one text each (the
-- settings tool lists them; a widget only shows that there is one). ctx as kept
-- by tick (or pollConfig); without ctx a fresh one is read for the call.
local function setupErrors(ctx)
  if not ctx then
    ctx = Core.newContext()
    pollConfig(ctx)
  end
  if ctx.configError == "missing" then return { "No settings file yet" } end
  if ctx.configError then return { "Settings file damaged" } end
  if ctx.modelError == "missing" then return { "Model not set up" } end
  local out = {}
  if ctx.modelError == "no_batteries" then
    out[#out + 1] = "No batteries assigned to this model"
  elseif not hasMatchingCellProfile(ctx) then
    out[#out + 1] = "No assigned battery has " .. tostring(ctx.cells) .. " cells"
  end
  checkSensors(ctx)
  local missing = {}
  if not ctx.hasRxBt then missing[#missing + 1] = ctx.sensorVoltage end
  if not ctx.hasCapa then missing[#missing + 1] = ctx.sensorCapacity end
  if #missing > 0 then
    out[#out + 1] = "Missing sensors: " .. table.concat(missing, ", ")
    out[#out + 1] = "Check sensors config"
  end
  return out
end

-- Preflight check met: a pack chosen (no selection open) and not low.
local function preflightMet(ctx)
  if not ctx.selectedProfile or ctx.pendingSelection then return false end
  local warn, crit = getThresholds(ctx)
  return preflight(calculateRestPct(ctx), warn, crit).level == 0
end

-- One data-processing cycle (no lcd.*), the single entry point every consumer
-- drives. Bails out early on a config error or a missing required sensor so it
-- never computes on absent values. Returns true when the connected branch ran,
-- so the caller knows when to poll its own selection input.
local function tick(ctx)
  local saving = ctx.saveJob ~= nil
  stepSave(ctx)             -- first: a config error or missing sensor must not stall it
  -- The save re-reads the file itself and sets ctx.config; polling during it (or
  -- in its write tick) only costs instructions.
  if not saving then pollConfig(ctx) end
  if ctx.configError then return false end
  checkSensors(ctx)
  if not ctx.hasRxBt or not ctx.hasCapa then return false end  -- required sensors absent
  readTelemetry(ctx)
  updateStateMachine(ctx, preflightMet(ctx))
  if not isActive(ctx) then return false end
  detectBattery(ctx)        -- auto-select for 1 candidate; else sets pendingSelection
  evaluateWarnings(ctx)
  refreshTimeLeft(ctx)      -- snapshot the displayed time-left every 2 s
  return true
end

-- Stick-gesture thresholds for the selection popup (getValue range -1024..+1024).
local STICK_STEP        = 500  -- deflection that counts as one cursor step
local STICK_DEADZONE    = 200  -- re-arms the next step once back inside this
local CONFIRM_THRESHOLD = 700  -- aileron deflection (full right) that means "confirm"
local CONFIRM_HOLD      = 100  -- 1.0 s hold (hundredths of a second) before commit
Core.CONFIRM_HOLD = CONFIRM_HOLD

-- Stick-gesture control for the selection popup, polled every tick by the widget
-- (works without fullscreen, unlike key events; shared with Flight Wingman). Elevator moves the cursor one step per deflection
-- (re-armed in the dead-zone); aileron held full-right with elevator centred commits.
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

-- ---------------------------------------------------------------------------
-- Context factory
-- ---------------------------------------------------------------------------

-- Fresh logic context (everything the state machine / telemetry / selection
-- touch). The widget adds its own display/lifecycle fields (zone, cfg, lastTick,
-- errorStreak, fatalError) on top and calls pollConfig() once after create.
local function newContext()
  return {
    -- State machine
    phase = "WAITING",     -- flight phase (flightPhase), picks the tile
    linkLostSince     = nil,
    connectedSinceTime = 0,

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
    saveJob      = nil,   -- flight-end save in progress (see stepSave)

    -- Telemetry — last valid values.
    voltage     = nil,
    current     = nil,
    capacity    = nil,
    linkUp      = false,
    noBatterySignal = false,
    disarmSeen      = nil, -- a disarmed FM text was seen this flight (armedFromFM)
    armed           = false, -- known armed (armedFromFM), while the link is up

    -- Sensor existence (assume present until checkSensors proves otherwise, so
    -- the first frame doesn't flash "Sensor missing").
    hasRxBt = true,
    hasCurr = true,
    hasCapa = true,
    sensorCheckAt = nil,
    sensorNames   = {},

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
    chargePending = false,

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
Core.normalizeConfig      = normalizeConfig
Core.resetSettings        = resetSettings
Core.resetStats           = resetStats
Core.factoryReset         = factoryReset

-- Derived values used by the widget's display
Core.socFromVoltage       = socFromVoltage
Core.getThresholds        = getThresholds
Core.preflight            = preflight
Core.effectiveCapacityMah = effectiveCapacityMah
Core.calculateRestPct     = calculateRestPct
Core.voltageLevel         = voltageLevel
Core.formatTimeLeft       = formatTimeLeft
Core.refreshTimeLeft      = refreshTimeLeft
Core.cyclesFor            = cyclesFor
Core.modelFilename        = modelFilename
Core.activeModelName      = activeModelName

-- Per-tick pipeline: consumers call tick(); the steps stay exported for tests
Core.tick                 = tick
Core.pollConfig           = pollConfig
Core.checkSensors         = checkSensors
Core.setupErrors          = setupErrors
Core.readTelemetry        = readTelemetry
Core.updateStateMachine   = updateStateMachine
Core.detectBattery        = detectBattery
Core.evaluateWarnings     = evaluateWarnings
Core.finalizeFlight       = finalizeFlight
Core.stepSave             = stepSave

-- Link status + selection helpers the widget's tiles / stick input consult
Core.isOnline             = isOnline
Core.isActive             = isActive
Core.flightPhase          = flightPhase
Core.LINK_LOSS_T, Core.ENDED_HOLD_T, Core.PRE_HOLD_T = LINK_LOSS_T, ENDED_HOLD_T, PRE_HOLD_T
Core.isUsbConnected       = isUsbConnected
Core.activeSelectionList  = activeSelectionList
Core.commitSlot           = commitSlot
Core.autoSelectSlot       = autoSelectSlot
Core.pollSelectionSticks  = pollSelectionSticks

Core.newContext           = newContext

return Core
