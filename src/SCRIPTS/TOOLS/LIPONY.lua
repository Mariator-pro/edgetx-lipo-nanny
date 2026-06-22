-- TNS|Lipo Nanny|TNE
-- =====================================================================
-- LIPONY.lua  --  EdgeTX Tools Script for Lipo-Nanny configuration
-- =====================================================================
-- SD card path: /SCRIPTS/TOOLS/LIPONY.lua
-- (Reads and writes the shared config the widget consumes.)
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

local VERSION        = "1.0.1"
local SCHEMA_VERSION = 1
local PATHS = {
  config    = "/SCRIPTS/LIPONY/config.lua",
  soundDir  = "/SOUNDS/en/scripts/LIPONY/",   -- trailing slash: prefix for full paths
  soundList = "/SOUNDS/en/scripts/LIPONY",    -- no trailing slash: passed to dir()
}
PATHS.warnSound = PATHS.soundDir .. "warn.wav"
PATHS.critSound = PATHS.soundDir .. "crit.wav"

-- ---------------------------------------------------------------------------
-- Serialization (same table shape the widget loads) + file write
-- ---------------------------------------------------------------------------

local function quoteString(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "\n", "\\n")
  return '"' .. s .. '"'
end

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

-- io.open "w" does NOT truncate on some EdgeTX/SD builds, so a shorter write would
-- leave the old tail behind — pad with trailing newlines (valid after the table) up
-- to the old length. Pcall-wrapped so a full/read-only SD never raises.
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

-- ---------------------------------------------------------------------------
-- Config load / default / save
-- ---------------------------------------------------------------------------

-- Returns (config) on success, or (nil, errKind, detail) where errKind is
-- "missing" | "parse" | "schema".
local function loadConfig()
  local ok, f = pcall(io.open, PATHS.config, "r")
  if not ok or not f then return nil, "missing" end
  pcall(io.close, f)

  local pok, result = pcall(dofile, PATHS.config)
  if not pok then return nil, "parse", tostring(result) end
  if type(result) ~= "table" then return nil, "parse", "not a table" end
  if result.schemaVersion ~= SCHEMA_VERSION then
    return nil, "schema", tostring(result.schemaVersion)
  end
  result.archive = result.archive or {}
  result.sounds  = result.sounds or {}
  return result
end

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

-- Increments the reload sentinel and writes the config. Returns true on success.
local function saveConfig(cfg)
  cfg.generation = (cfg.generation or 0) + 1
  local content = "-- Lipo-Nanny configuration (auto-generated by the Tools-Script).\n"
                  .. "return " .. serialize(cfg, "") .. "\n"
  return writeFile(PATHS.config, content)
end

-- ---------------------------------------------------------------------------
-- Custom warning sounds
-- ---------------------------------------------------------------------------

-- Excluded from the named list — reachable via the "Default" option instead.
local SOUND_DEFAULT_FILES = { ["warn.wav"] = true, ["crit.wav"] = true }

-- Sorted *.wav files in the sound folder (any user-named file shows up). pcall:
-- dir() raises when the folder is missing. string.lower/match as free functions:
-- EdgeTX-Lua has no string methods (fname:lower() would raise on the radio).
local function listSoundFiles()
  local files = {}
  pcall(function()
    for fname in dir(PATHS.soundList) do
      if type(fname) == "string" and string.match(string.lower(fname), "%.wav$")
         and not SOUND_DEFAULT_FILES[fname] then
        files[#files + 1] = fname
      end
    end
  end)
  table.sort(files, function(a, b) return string.lower(a) < string.lower(b) end)
  return files
end

-- Picker options { label, path }; index 1 is the default, stored as nil in the
-- config so a deleted file falls back to the bundled default instead of breaking.
local function buildSoundOptions(defaultPath, files)
  local opts = { { label = "Default", path = defaultPath } }
  for _, fname in ipairs(files) do
    opts[#opts + 1] = { label = fname, path = PATHS.soundDir .. fname }
  end
  return opts
end

-- 1-based index of the option matching `path` (nil or no-longer-present -> 1 = Default).
local function soundOptionIndex(opts, path)
  if path then
    for i, o in ipairs(opts) do if o.path == path then return i end end
  end
  return 1
end

-- Config value for a selection: nil for Default, else the chosen file's path.
local function soundConfigValue(opts, idx)
  return (idx > 1) and opts[idx].path or nil
end

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------

local SCREEN = {
  FIRST_START  = "first_start",
  CONFIG_ERROR = "config_error",
  MAIN         = "main",
  BATTERIES    = "batteries",
  PROFILE      = "profile",
  PACKS        = "packs",
  MODELS       = "models",
  MODEL        = "model",
  ASSIGN       = "assign",
  SENSORS      = "sensors",
  DEFAULTS     = "defaults",
  ABOUT        = "about",
}

local CHEM_NAMES = { "LiPo", "LiPoHV", "LiIon" }

-- Default telemetry sensor names (CRSF/ELRS). Must stay in sync with the widget's
-- DEFAULT_SENSOR_* constants. SENSOR_FIELDS drives the per-model sensor-editor rows.
local DEFAULT_SENSORS = { voltage = "RxBt", current = "Curr", capacity = "Capa", link = "RQly" }
-- `desc` is the multi-line "what it does + expected values" help shown for the
-- focused field on the Sensors screen, so the pilot can map it to the right sensor
-- of their telemetry system.
local SENSOR_FIELDS = {
  { key = "voltage",  label = "Voltage", desc = {
      "Whole-pack voltage (V). Sets SoC % and",
      "warnings. 4S full ~16.8V, empty ~14.0V." } },
  { key = "current",  label = "Current", desc = {
      "Live current draw (A). Feeds the",
      "remaining-time estimate. e.g. 0-120A." } },
  { key = "capacity", label = "Capacity", desc = {
      "Consumed mAh, counts UP from 0 (not %).",
      "Main warn trigger. 1300mAh pack: 0->1300." } },
  { key = "link",     label = "Link", desc = {
      "Link/signal quality for online detect.",
      "Any value >0 = receiving. e.g. RQly, RSSI." } },
}
local MFR_MAX  = 10
local NAME_MAX = 30

-- Character groups for the ring picker. The active group is tracked in S.charGroup, so
-- the wheel cycles within one group and wraps at its ends; MDL jumps to the next group's
-- `first`. Each group ends in a space, so spinning left off the first char lands on blank.
local CHAR_GROUPS = {
  { label = "ABC",  chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ ", first = "A" },
  { label = "abc",  chars = "abcdefghijklmnopqrstuvwxyz ", first = "a" },
  { label = "123#", chars = "0123456789-+.# ",            first = "0" },
}

-- Best-effort group for a character (space lives in every group; first match wins).
-- Used only to seed S.charGroup when the cursor lands on an existing character.
local function groupOfChar(ch)
  for gi, g in ipairs(CHAR_GROUPS) do
    if string.find(g.chars, ch, 1, true) then return gi end
  end
  return 1
end

local S = {
  screen   = SCREEN.MAIN,
  cfg      = nil,
  err      = nil,
  errDetail = nil,
  cursor   = 1,
  dialog   = nil,   -- { text, yes = "Yes", no = "No", onYes = fn }
  -- Defaults editor working state
  def        = nil, -- { warn, crit }
  defEditing = false,
  defField   = nil,
  defOrig    = nil,
}

-- ---------------------------------------------------------------------------
-- Event helpers (virtual keys)
-- ---------------------------------------------------------------------------

local function isNext(e)
  return e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC
end
local function isPrev(e)
  return e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC
end
local function isEnter(e) return e == EVT_VIRTUAL_ENTER end
local function isExit(e)  return e == EVT_VIRTUAL_EXIT end

-- The MDL key switches the char-ring group; it maps to EVT_VIRTUAL_MENU (shared by the
-- MDL/SYS/MENU keys). The `or -1` guards a firmware lacking the constant, so a nil event
-- never matches.
local EVT_GROUP_SWITCH = EVT_VIRTUAL_MENU or -1
local function isGroupSwitch(e)
  return e == EVT_GROUP_SWITCH
end

-- Moves a 1-based cursor within [1, count], clamped (no wrap).
local function moveCursor(cur, e, count)
  if isNext(e) and cur < count then return cur + 1 end
  if isPrev(e) and cur > 1     then return cur - 1 end
  return cur
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local PAD  = 6
-- Row pitch. The screen-height fraction is only a load-time fallback (sizeText is not
-- valid until a frame runs); draw() raises LINE to the real font height on the first
-- frame, so rows and buttons never overlap. Layout reads LINE at draw time, so the
-- correction propagates everywhere.
local LINE = math.max(18, math.floor(LCD_H / 13))
local COL1 = PAD * 2                    -- label / entry column
local COL2 = math.floor(LCD_W * 0.42)   -- value column (two-column editor fields)

-- Packs table column x-anchors (computed from the display width).
local PK_ID, PK_CYC, PK_WEAR, PK_ACT =
  COL1, math.floor(LCD_W * 0.24), math.floor(LCD_W * 0.46), math.floor(LCD_W * 0.68)

-- Settings table column x-anchors (Warning label / Threshold / Sound / Test).
local ST_WARN, ST_THR, ST_SND, ST_TEST =
  COL1, math.floor(LCD_W * 0.26), math.floor(LCD_W * 0.46), math.floor(LCD_W * 0.70)

local function drawHeader(title)
  local h = LINE + PAD
  lcd.drawFilledRectangle(0, 0, LCD_W, h, COLOR_THEME_SECONDARY1)
  local _, th = lcd.sizeText("Mg")            -- font height; vertically centre the title
  lcd.drawText(PAD, math.floor((h - th) / 2), title, COLOR_THEME_PRIMARY2 + BOLD)
end

local function bodyY(row)
  return LINE + PAD * 2 + (row - 1) * LINE
end

-- Selection inverts the text (no focus bar). A navigation/action row is a single
-- string at COL1: `folder` prefixes "> " and bolds it (opens a sub-page), `disabled`
-- dims it, the cursor row is drawn INVERS.
local function drawNavRow(row, text, selected, opts)
  opts = opts or {}
  local flags = opts.disabled and COLOR_THEME_DISABLED or COLOR_THEME_PRIMARY1
  if opts.folder then text = "> " .. text; flags = flags + BOLD end
  if selected then flags = flags + INVERS end
  lcd.drawText(COL1, bodyY(row), text, flags)
end

-- Downward triangle marking a field that opens a picker popup. Stacked 1px rows,
-- so no triangle primitive is needed. (x, y) is the top-left.
local ARROW_W   = 11
local ARROW_H   = math.ceil(ARROW_W / 2)
local ARROW_GAP = 5
local function drawDownArrow(x, y, color)
  for i = 0, ARROW_H - 1 do
    lcd.drawFilledRectangle(x + i, y + i, ARROW_W - 2 * i, 1, color)
  end
end

-- Draws the popup arrow at (x, y), vertically centred on the row; returns the x
-- where the value text should start (right of the arrow).
local function drawArrowBefore(x, y, color)
  local _, th = lcd.sizeText("Mg")
  drawDownArrow(x, y + math.floor((th - ARROW_H) / 2), color)
  return x + ARROW_W + ARROW_GAP
end

-- A two-column field row at an explicit y: label at COL1, value at COL2. Only the
-- value is highlighted — INVERS when selected, BLINK+INVERS while editing — except a
-- folder field (opens a sub-page), where the whole row inverts. opts.popup adds a
-- down-arrow before the value (field opens a picker).
local function drawFieldRowY(y, label, value, opts)
  opts = opts or {}
  local base   = opts.disabled and COLOR_THEME_DISABLED or COLOR_THEME_PRIMARY1
  local lflags = base
  if opts.folder then label = "> " .. label; lflags = lflags + BOLD end
  if opts.selected and opts.folder then lflags = lflags + INVERS end
  lcd.drawText(COL1, y, label, lflags)
  if value ~= nil then
    local vflags = base
    if opts.editing then vflags = vflags + BLINK + INVERS
    elseif opts.selected then vflags = vflags + INVERS end
    local vx = opts.popup and drawArrowBefore(COL2, y, base) or COL2
    lcd.drawText(vx, y, value, vflags)
  end
end

local function drawFieldRow(row, label, value, opts)
  drawFieldRowY(bodyY(row), label, value, opts)
end

-- Gap (px) between the separator line and the bottom button row (see drawButtonBar).
local BTN_GAP = 8

-- Y of the separator line above the bottom button bar — also the bottom edge of
-- the scrolling content area above. The buttons get equal spacing above (to the
-- separator) and below (to the screen edge): both BTN_GAP.
local function barTopY()
  local _, th = lcd.sizeText("Mg")
  return LCD_H - (th + 4) - 2 * BTN_GAP
end

-- Draws one button at (x, y): outlined, or filled with the accent colour when focused.
-- Returns its width so callers can lay several out in a row.
local BTN_PADX = 6
local function drawButton(x, y, label, focused)
  local _, th = lcd.sizeText("Mg")
  local w     = lcd.sizeText(label) + 2 * BTN_PADX
  if focused then
    lcd.drawFilledRectangle(x, y, w, th + 4, COLOR_THEME_FOCUS)
    lcd.drawText(x + BTN_PADX, y + 2, label, COLOR_THEME_PRIMARY2)
  else
    lcd.drawRectangle(x, y, w, th + 4, COLOR_THEME_PRIMARY1)
    lcd.drawText(x + BTN_PADX, y + 2, label, COLOR_THEME_PRIMARY1)
  end
  return w
end

-- Bottom action bar; `firstItem` is the cursor index of labels[1].
local function drawButtonBar(labels, firstItem, cursor)
  local sepY = barTopY()
  local btnY = sepY + BTN_GAP
  lcd.drawFilledRectangle(PAD, sepY, LCD_W - 2 * PAD, 1, COLOR_THEME_PRIMARY3)
  local x = PAD
  for i, label in ipairs(labels) do
    local w = drawButton(x, btnY, label, cursor == firstItem + i - 1)
    x = x + w + PAD
  end
end

-- A blue chip with the key name plus its action label at (x, y); returns the next x.
local function drawKeyChip(x, y, key, action)
  local kw, kh = lcd.sizeText(key)
  lcd.drawFilledRectangle(x, y - 1, kw + 4, kh + 2, COLOR_THEME_FOCUS)
  lcd.drawText(x + 2, y, key, COLOR_THEME_PRIMARY2)
  lcd.drawText(x + kw + 8, y, action, COLOR_THEME_PRIMARY1)
  return x + kw + 8 + lcd.sizeText(action)
end

-- Right-aligned key-chip hint for the field being edited (the key's effect isn't
-- self-evident). valueRight = right edge of the value text; the hint is skipped when
-- the value would reach it, so a long Name never overlaps the chip.
local function drawKeyHint(y, key, action, valueRight)
  local x = LCD_W - PAD - (lcd.sizeText(key) + 8 + lcd.sizeText(action))
  if valueRight and valueRight + PAD > x then return end   -- would overlap the value
  drawKeyChip(x, y, key, action)
end

-- Full-screen shade behind a popup/dialog. opacity 0 = solid, 15 = invisible;
-- 9 = ~40% black. Lower it for a darker backdrop.
local DIM_OPACITY = 9
local function dimScreen()
  lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, lcd.RGB(0, 0, 0), DIM_OPACITY)
end

-- ---------------------------------------------------------------------------
-- Generic confirm dialog
-- ---------------------------------------------------------------------------

local function openDialog(text, onYes, yesLabel, noLabel)
  S.dialog = { text = text, onYes = onYes, cursor = 2,  -- default to the safe answer
               yes = yesLabel or "Yes", no = noLabel or "No" }
end

-- Modal info popup with a single [ OK ] button (dismiss with ENTER/EXIT). Used for
-- validation / blocked-action messages so they never overlap the screen content.
local function openAlert(text)
  S.dialog = { text = text, alert = true }
end

local function drawDialog()
  local d = S.dialog
  dimScreen()
  local w = math.floor(LCD_W * 0.8)
  local h = 3 * LINE + PAD * 2
  local x = math.floor((LCD_W - w) / 2)
  local y = math.floor((LCD_H - h) / 2)
  lcd.drawFilledRectangle(x, y, w, h, COLOR_THEME_SECONDARY1)
  lcd.drawRectangle(x, y, w, h, COLOR_THEME_PRIMARY2)
  lcd.drawText(x + PAD, y + PAD, d.text, COLOR_THEME_PRIMARY2)
  local by = y + h - LINE - PAD
  local function btn(bx, label, sel)
    lcd.drawText(bx, by, label, COLOR_THEME_PRIMARY2 + (sel and INVERS or 0))
  end
  if d.alert then
    btn(math.floor(LCD_W / 2) - PAD * 2, "[ OK ]", true)
  else
    btn(x + PAD * 2,                 d.yes, d.cursor == 1)
    btn(x + math.floor(w / 2) + PAD, d.no,  d.cursor == 2)
  end
end

local function handleDialog(e)
  local d = S.dialog
  if d.alert then
    if isEnter(e) or isExit(e) then S.dialog = nil end
    return
  end
  if isNext(e) or isPrev(e) then
    d.cursor = (d.cursor == 1) and 2 or 1
  elseif isEnter(e) then
    local onYes = d.onYes
    local choseYes = d.cursor == 1
    S.dialog = nil
    if choseYes and onYes then onYes() end
  elseif isExit(e) then
    S.dialog = nil   -- EXIT == the cancelling answer
  end
end

-- ---------------------------------------------------------------------------
-- Generic scrollable picker popup
-- ---------------------------------------------------------------------------

-- Most rows shown at once; longer lists scroll.
local PICKER_MAX_ROWS = 5

-- Keeps the highlighted row inside the visible window.
local function pickerEnsureVisible(rows)
  local p = S.picker
  if p.sel < p.top then p.top = p.sel end
  if p.sel > p.top + rows - 1 then p.top = p.sel - rows + 1 end
  if p.top < 1 then p.top = 1 end
end

-- `sel` pre-selected, `onPick(idx)` runs on ENTER, EXIT cancels.
local function openPicker(title, labels, sel, onPick)
  S.picker = { title = title, labels = labels, sel = sel or 1, top = 1, onPick = onPick }
end

-- Rows the box shows: capped by the max, the list, and what fits the screen.
local function pickerRows()
  local _, th  = lcd.sizeText("Mg")
  local maxFit = math.floor((LCD_H - 2 * LINE - th - 2 * PAD) / LINE)
  return math.max(1, math.min(PICKER_MAX_ROWS, #S.picker.labels, maxFit))
end

local PICK_INDENT = 8
local function drawPicker()
  local p     = S.picker
  local n     = #p.labels
  local rows  = pickerRows()
  local _, th = lcd.sizeText("Mg")
  local headH = th + 6
  local w     = math.floor(LCD_W * 0.58)
  local h     = headH + rows * LINE + 4
  local x     = math.floor((LCD_W - w) / 2)
  local y     = math.floor((LCD_H - h) / 2)
  local hasBar = n > rows
  local textY  = math.floor((LINE - th) / 2)   -- vertical centring in a row

  dimScreen()

  -- Drop shadow, light body, thin frame.
  lcd.drawFilledRectangle(x + 3, y + 3, w, h, COLOR_THEME_PRIMARY1)
  lcd.drawFilledRectangle(x, y, w, h, COLOR_THEME_SECONDARY3)
  lcd.drawRectangle(x, y, w, h, COLOR_THEME_SECONDARY1)

  -- Title bar + "selected/total" counter.
  lcd.drawFilledRectangle(x, y, w, headH, COLOR_THEME_SECONDARY1)
  lcd.drawText(x + PICK_INDENT, y + 3, p.title, COLOR_THEME_PRIMARY2 + BOLD)
  lcd.drawText(x + w - PICK_INDENT, y + 3, p.sel .. "/" .. n, COLOR_THEME_PRIMARY2 + RIGHT)

  local listY = y + headH
  for i = 0, rows - 1 do
    local idx = p.top + i
    if idx <= n then
      local ry = listY + i * LINE
      if idx == p.sel then
        local barW = w - (hasBar and 5 or 0)
        lcd.drawFilledRectangle(x, ry, barW, LINE, COLOR_THEME_FOCUS)
        lcd.drawText(x + PICK_INDENT, ry + textY, p.labels[idx], COLOR_THEME_PRIMARY2)
      else
        lcd.drawText(x + PICK_INDENT, ry + textY, p.labels[idx], COLOR_THEME_PRIMARY1)
      end
    end
  end

  -- Scrollbar when the list overflows.
  if hasBar then
    local trackH = rows * LINE
    local sx     = x + w - 4
    lcd.drawFilledRectangle(sx, listY, 3, trackH, COLOR_THEME_PRIMARY3)
    local thumbH = math.max(6, math.floor(trackH * rows / n))
    local thumbY = listY + math.floor(trackH * (p.top - 1) / n)
    lcd.drawFilledRectangle(sx, thumbY, 3, thumbH, COLOR_THEME_FOCUS)
  end
end

local function handlePicker(e)
  local p = S.picker
  local n = #p.labels
  if isNext(e) or isPrev(e) then
    p.sel = isNext(e) and (p.sel % n + 1) or ((p.sel - 2) % n + 1)
    pickerEnsureVisible(pickerRows())
  elseif isEnter(e) then
    local onPick, sel = p.onPick, p.sel
    S.picker = nil
    if onPick then onPick(sel) end
  elseif isExit(e) then
    S.picker = nil          -- cancel
  end
end

-- Runs a write closure (returns true on success). On failure it shows a
-- Retry / Cancel dialog that re-runs the same closure; on success it calls
-- onDone. The closure must do only the (idempotent) file writes — any RAM
-- mutation must already be applied so a retry does not repeat it.
local function withRetry(writeFn, onDone)
  if writeFn() then
    if onDone then onDone() end
  else
    openDialog("Save failed — check SD card.",
               function() withRetry(writeFn, onDone) end, "Retry", "Cancel")
  end
end

-- ---------------------------------------------------------------------------
-- Destructive resets (shared by Settings and the config-error recovery)
-- ---------------------------------------------------------------------------

-- Zeroes every active pack's cycle count and empties the archive, then saves (the
-- generation bump makes a running widget pick up the cleared counts). Profiles and
-- models are kept. The RAM mutation is idempotent, so a withRetry retry is harmless.
local function resetStats(onDone)
  for _, b in ipairs(S.cfg.batteries) do
    for _, inst in ipairs(b.instances or {}) do inst.cycles = 0 end
  end
  S.cfg.archive = {}
  withRetry(function() return saveConfig(S.cfg) end, onDone)
end

-- Overwrites config.lua with factory defaults (batteries, models, archive and cycle
-- counts all erased) and clears any parse/schema error. The pack-id counter safely
-- restarts at 1 — nothing survives the reset that a fresh id could collide with.
local function resetConfig(onDone)
  local fresh = defaultConfig()
  withRetry(function() return saveConfig(fresh) end, function()
    S.cfg              = fresh
    S.err, S.errDetail = nil, nil
    if onDone then onDone() end
  end)
end

-- ---------------------------------------------------------------------------
-- Screen: first start
-- ---------------------------------------------------------------------------

local function drawFirstStart()
  drawHeader("LIPO NANNY — FIRST START")
  lcd.drawText(COL1, bodyY(1), "No configuration found.", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(2), "Press ENTER to create defaults.", COLOR_THEME_PRIMARY1)
  drawButtonBar({ "Create" }, 1, 1)
end

local function handleFirstStart(e)
  if isEnter(e) then
    S.cfg = defaultConfig()
    withRetry(function() return saveConfig(S.cfg) end, function()
      S.screen = SCREEN.MAIN
      S.cursor = 1
    end)
  elseif isExit(e) then
    return 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: config error
-- ---------------------------------------------------------------------------

local function drawConfigError()
  drawHeader("CONFIG ERROR")
  if S.err == "schema" then
    lcd.drawText(COL1, bodyY(1), "Schema version mismatch", COLOR_THEME_PRIMARY1)
    lcd.drawText(COL1, bodyY(2), "(found " .. tostring(S.errDetail) .. ", expected "
                 .. SCHEMA_VERSION .. ").", COLOR_THEME_PRIMARY1)
  else
    lcd.drawText(COL1, bodyY(1), "Parse error in config.lua", COLOR_THEME_PRIMARY1)
  end
  lcd.drawText(COL1, bodyY(3), "Edit config.lua on PC,", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(4), "or reset to defaults below.", COLOR_THEME_PRIMARY1)
  drawButtonBar({ "Reset config", "Exit" }, 1, S.cursor)
end

local function handleConfigError(e)
  S.cursor = moveCursor(S.cursor, e, 2)
  if isEnter(e) then
    if S.cursor == 1 then
      openDialog("Reset configuration to defaults? All settings are erased.",
                 function() resetConfig(function() S.screen = SCREEN.MAIN; S.cursor = 1 end) end)
    else
      return 1
    end
  elseif isExit(e) then
    return 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: main menu
-- ---------------------------------------------------------------------------

local MAIN_ITEMS = { "Batteries", "Models", "Settings", "About" }

local function drawMain()
  drawHeader("LIPO NANNY — SETUP")
  for i, item in ipairs(MAIN_ITEMS) do
    drawNavRow(i, item, S.cursor == i, { folder = true })
  end
  drawButtonBar({ "Exit" }, #MAIN_ITEMS + 1, S.cursor)
end

local function enterDefaults()
  S.def         = { warn = S.cfg.defaults.warn_pct, crit = S.cfg.defaults.crit_pct }
  local files   = listSoundFiles()
  S.sndWarnOpts = buildSoundOptions(PATHS.warnSound, files)
  S.sndCritOpts = buildSoundOptions(PATHS.critSound, files)
  local snd     = S.cfg.sounds or {}
  S.def.warnSnd = soundOptionIndex(S.sndWarnOpts, snd.warn)
  S.def.critSnd = soundOptionIndex(S.sndCritOpts, snd.crit)
  S.defEditing  = false
  S.defDive     = nil       -- focused warning row (dived in), or nil at top level
  S.defSub      = "thr"     -- active cell once dived: "thr" | "snd" | "test"
  S.cursor      = 1
  S.screen      = SCREEN.DEFAULTS
end

local function handleMain(e)
  S.cursor = moveCursor(S.cursor, e, #MAIN_ITEMS + 1)
  if isEnter(e) then
    if S.cursor > #MAIN_ITEMS then
      return 1                 -- Exit button closes the tool
    end
    local item = MAIN_ITEMS[S.cursor]
    if item == "Batteries" then
      S.screen = SCREEN.BATTERIES
      S.cursor = 1
    elseif item == "Models" then
      S.screen = SCREEN.MODELS
      S.cursor = 1
    elseif item == "Settings" then
      enterDefaults()
    elseif item == "About" then
      S.screen = SCREEN.ABOUT
      S.cursor = 1
    end
  elseif isExit(e) then
    return 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: About
-- ---------------------------------------------------------------------------

local ABOUT_LINES = {
  "(c) Mariator-pro   GPL-2.0",
  "LIPONY  v" .. VERSION,
  "Widget: /WIDGETS/LIPONY/main.lua",
  "Tools:  /SCRIPTS/TOOLS/LIPONY.lua",
  "Data:   /SCRIPTS/LIPONY/",
  "Sounds: " .. PATHS.soundDir,
  "Schema version: " .. SCHEMA_VERSION,
}

-- Scrolling info list (same window logic as the Batteries list). The lines have no
-- action, so ENTER or EXIT just returns; the wheel scrolls.
local function drawAbout()
  drawHeader("ABOUT")
  local n       = #ABOUT_LINES
  local maxRows = math.max(1, math.floor((barTopY() - bodyY(1)) / LINE))
  local focus   = math.max(1, math.min(S.cursor, n))
  local start   = math.max(1, math.min(focus - math.floor(maxRows / 2), n - maxRows + 1))
  if start < 1 then start = 1 end
  local row = 0
  for i = start, math.min(n, start + maxRows - 1) do
    row = row + 1
    lcd.drawText(COL1, bodyY(row), ABOUT_LINES[i], COLOR_THEME_PRIMARY1 + (S.cursor == i and INVERS or 0))
  end
  drawButtonBar({ "Back" }, n + 1, S.cursor)
end

local function handleAbout(e)
  S.cursor = moveCursor(S.cursor, e, #ABOUT_LINES + 1)   -- scroll the info lines + Back
  if isEnter(e) or isExit(e) then S.screen = SCREEN.MAIN; S.cursor = 4 end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Defaults editor
-- ---------------------------------------------------------------------------

-- Top-level rows: Low (1), Critical (2), reset-stats (3), reset-config (4),
-- Back (5), Save (6). ENTER on a warning row dives in; the roller then steps its
-- cells (DEF_SUBS) and ENTER edits/plays the focused one (Packs-style).
local DEF_ITEMS = 6
local DEF_SUBS  = { "thr", "snd", "test" }

local function defaultsDirty()
  local snd = S.cfg.sounds or {}
  return S.def.warn ~= S.cfg.defaults.warn_pct
      or S.def.crit ~= S.cfg.defaults.crit_pct
      or soundConfigValue(S.sndWarnOpts, S.def.warnSnd) ~= snd.warn
      or soundConfigValue(S.sndCritOpts, S.def.critSnd) ~= snd.crit
end

local function leaveDefaults()
  S.screen = SCREEN.MAIN
  S.cursor = 3
end

local function saveDefaults()
  if not (S.def.warn > S.def.crit) then
    openAlert("Low must be above Critical")
    return
  end
  S.cfg.defaults.warn_pct = S.def.warn
  S.cfg.defaults.crit_pct = S.def.crit
  S.cfg.sounds = S.cfg.sounds or {}
  S.cfg.sounds.warn = soundConfigValue(S.sndWarnOpts, S.def.warnSnd)
  S.cfg.sounds.crit = soundConfigValue(S.sndCritOpts, S.def.critSnd)
  withRetry(function() return saveConfig(S.cfg) end, leaveDefaults)
end

local function cancelDefaults()
  if defaultsDirty() then
    openDialog("Discard changes?", leaveDefaults)
  else
    leaveDefaults()
  end
end

-- One warning row per line: label, threshold value, and the sound option list +
-- selected index.
local function defaultsRows()
  return {
    { label = "Low",      thr = S.def.warn,
      sndOpts = S.sndWarnOpts, sndIdx = S.def.warnSnd },
    { label = "Critical", thr = S.def.crit,
      sndOpts = S.sndCritOpts, sndIdx = S.def.critSnd },
  }
end

local function drawDefaults()
  drawHeader("SETTINGS")

  -- Column header row (bold, not selectable).
  local hy = bodyY(1)
  lcd.drawText(ST_WARN, hy, "Warning",   COLOR_THEME_PRIMARY1 + BOLD)
  lcd.drawText(ST_THR,  hy, "Threshold", COLOR_THEME_PRIMARY1 + BOLD)
  lcd.drawText(ST_SND,  hy, "Sound",     COLOR_THEME_PRIMARY1 + BOLD)
  lcd.drawText(ST_TEST, hy, "Test",      COLOR_THEME_PRIMARY1 + BOLD)

  for r, row in ipairs(defaultsRows()) do
    local y      = bodyY(1 + r)
    local dived  = S.defDive == r
    local rowSel = (S.cursor == r) and not dived
    -- The row label inverts to mark the focused row before diving in; once dived,
    -- only the active cell inverts (and blinks while being edited).
    lcd.drawText(ST_WARN, y, row.label, COLOR_THEME_PRIMARY1 + (rowSel and INVERS or 0))
    local function cell(x, text, sub, editing)
      local f = COLOR_THEME_PRIMARY1
      if editing then f = f + BLINK + INVERS
      elseif dived and S.defSub == sub then f = f + INVERS end
      lcd.drawText(x, y, text, f)
    end
    cell(ST_THR,  row.thr .. " %",               "thr",  dived and S.defSub == "thr" and S.defEditing)
    local sndTextX = drawArrowBefore(ST_SND, y, COLOR_THEME_PRIMARY1)
    cell(sndTextX, row.sndOpts[row.sndIdx].label, "snd", false)   -- sound uses the picker
    drawButton(ST_TEST, y - 2, "Play", dived and S.defSub == "test")
  end

  -- Destructive resets as buttons (Back/Save style), stacked below the table.
  drawButton(PAD, bodyY(5), "Reset statistics",    S.cursor == 3)
  drawButton(PAD, bodyY(6), "Reset configuration", S.cursor == 4)
  drawButtonBar({ "Back", "Save" }, 5, S.cursor)
end

local function handleDefaults(e)
  if S.defEditing then
    local field = S.defField
    if isNext(e) and S.def[field] < 99 then
      S.def[field] = S.def[field] + 1
    elseif isPrev(e) and S.def[field] > 1 then
      S.def[field] = S.def[field] - 1
    elseif isEnter(e) then
      S.defEditing = false
    elseif isExit(e) then
      S.def[field]  = S.defOrig   -- cancel edit
      S.defEditing  = false
    end
    return 0
  end

  -- Dived into a warning row: roller steps Threshold→Sound→Test, ENTER edits/plays
  -- the focused cell, EXIT leaves the row.
  if S.defDive then
    if isNext(e) or isPrev(e) then
      local idx = 1
      for j, s in ipairs(DEF_SUBS) do if s == S.defSub then idx = j end end
      idx = idx + (isNext(e) and 1 or -1)
      if idx < 1 then idx = #DEF_SUBS elseif idx > #DEF_SUBS then idx = 1 end
      S.defSub = DEF_SUBS[idx]
    elseif isEnter(e) then
      local isWarn = S.defDive == 1
      if S.defSub == "thr" then
        S.defField   = isWarn and "warn" or "crit"
        S.defEditing, S.defOrig = true, S.def[S.defField]
      elseif S.defSub == "snd" then
        -- Sound picker; onPick stores the chosen index.
        local field  = isWarn and "warnSnd" or "critSnd"
        local opts   = isWarn and S.sndWarnOpts or S.sndCritOpts
        local labels = {}
        for _, o in ipairs(opts) do labels[#labels + 1] = o.label end
        openPicker(isWarn and "Low sound" or "Critical sound", labels, S.def[field],
                   function(sel) S.def[field] = sel end)
      else   -- test: preview the row's current sound
        playFile(isWarn and S.sndWarnOpts[S.def.warnSnd].path
                        or  S.sndCritOpts[S.def.critSnd].path)
      end
    elseif isExit(e) then
      S.defDive = nil
    end
    return 0
  end

  -- Top-level row navigation.
  S.cursor = moveCursor(S.cursor, e, DEF_ITEMS)
  if isEnter(e) then
    if S.cursor == 1 or S.cursor == 2 then
      S.defDive, S.defSub = S.cursor, "thr"   -- dive into the Low / Critical row
    elseif S.cursor == 3 then
      openDialog("Reset all statistics? Cycle counts and archive are lost.",
                 function() resetStats(function() openAlert("Statistics reset") end) end)
    elseif S.cursor == 4 then
      openDialog("Reset configuration? All batteries and models are erased.",
                 function() resetConfig(leaveDefaults) end)
    elseif S.cursor == 5 then
      cancelDefaults()   -- Back (discard with confirm if dirty)
    elseif S.cursor == 6 then
      saveDefaults()
    end
  elseif isExit(e) then
    cancelDefaults()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Batteries: shared helpers
-- ---------------------------------------------------------------------------

-- Auto-generated profile name: "<Manufacturer> <S>s <Chemistry> <mAh>mAh".
local function genName(p)
  local mfr = (p.manufacturer ~= "" and (p.manufacturer .. " ")) or ""
  return mfr .. p.cells .. "s " .. p.chemistry .. " " .. p.capacityMah .. "mAh"
end

-- Next free "bat_NNN" id.
local function nextBatteryId(cfg)
  local maxN = 0
  for _, b in ipairs(cfg.batteries) do
    local n = tonumber(string.match(tostring(b.id or ""), "^bat_(%d+)$"))
    if n and n > maxN then maxN = n end
  end
  return string.format("bat_%03d", maxN + 1)
end

-- Next free "pack_NNNN" id. A global, monotonically rising counter persisted in
-- the config; never reset or reused, so each physical battery keeps a stable
-- identity for its lifetime (statistics hang off this id, not the display index).
local function nextPackId(cfg)
  local n = (cfg.nextPackId or 1)
  cfg.nextPackId = n + 1
  return string.format("pack_%04d", n)
end

-- Profiles sorted alphabetically by name (case-insensitive).
local function sortedBatteries(cfg)
  local out = {}
  for _, b in ipairs(cfg.batteries) do out[#out + 1] = b end
  table.sort(out, function(a, b)
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Screen: Batteries list
-- ---------------------------------------------------------------------------

local enterProfile      -- forward declaration (defined below)
local enterPacks        -- forward declaration (Packs page, defined below)
local modelDisplayName  -- forward declaration (Models section); used by the
                        -- parallel-binding messages, which are built earlier

local function batteryListItems()
  return sortedBatteries(S.cfg)
end

local function drawBatteries()
  drawHeader("BATTERIES")
  local items = batteryListItems()
  if #items == 0 then
    lcd.drawText(COL1, bodyY(1), "No batteries yet — add your first.", COLOR_THEME_PRIMARY1)
  else
    -- Scrolling window between header and button bar (the "[+] Add new" cursor
    -- index, #items+1, keeps the list scrolled to the bottom).
    local maxRows = math.max(1, math.floor((barTopY() - bodyY(1)) / LINE))
    local focus   = math.max(1, math.min(S.cursor, #items))
    local start   = math.max(1, math.min(focus - math.floor(maxRows / 2), #items - maxRows + 1))
    if start < 1 then start = 1 end
    local row = 0
    for i = start, math.min(#items, start + maxRows - 1) do
      row = row + 1
      drawNavRow(row, items[i].name, S.cursor == i, { folder = true })
    end
  end
  drawButtonBar({ "Back", "[+] Add new" }, #items + 1, S.cursor)
end

local function handleBatteries(e)
  local items = batteryListItems()
  local count = #items + 2            -- profiles + "Back" + "[+] Add new"
  S.cursor = moveCursor(S.cursor, e, count)
  if isEnter(e) then
    if S.cursor <= #items then
      enterProfile(items[S.cursor])
    elseif S.cursor == #items + 1 then
      S.screen = SCREEN.MAIN
      S.cursor = 1
    else
      enterProfile(nil)
    end
  elseif isExit(e) then
    S.screen = SCREEN.MAIN
    S.cursor = 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Profile editor
-- ---------------------------------------------------------------------------

-- Focusable items: name, manufacturer, chemistry, capacity, cells, packs,
-- warn, crit, [Save], [Cancel], and [Delete] (11, existing profiles only).

-- Smallest free display number — a new pack fills the lowest gap left by an
-- archived one, so #N stays stable.
local function nextLabel(instances)
  local used = {}
  for _, p in ipairs(instances or {}) do used[p.label or 0] = true end
  local n = 1
  while used[n] do n = n + 1 end
  return n
end

-- Keeps the pack list ordered by display number, so the Packs page (and the saved
-- config) always read #1, #2, #3 even after archiving a middle pack and adding one.
local function sortByLabel(instances)
  table.sort(instances, function(a, b) return (a.label or 0) < (b.label or 0) end)
end

local function newProfile()
  -- One placeholder pack (#1); its real pack id is minted on first save.
  local p = { manufacturer = "", name = "", nameAuto = true, chemistry = "LiPo",
              capacityMah = 1300, cells = 6, warn_pct = nil, crit_pct = nil,
              instances = { { id = nil, label = 1, wear = 0, cycles = 0 } } }
  p.name = genName(p)
  return p
end

-- Deep-copies the instance objects { id, label, wear, cycles } so the editor can
-- mutate its working copy without touching the stored profile until save.
local function copyInstances(src)
  local out = {}
  for i, p in ipairs(src or {}) do
    out[i] = { id = p.id, label = p.label, wear = p.wear or 0, cycles = p.cycles or 0 }
  end
  return out
end

local function copyProfile(src)
  return { id = src.id, manufacturer = src.manufacturer or "", name = src.name or "",
           nameAuto = src.nameAuto ~= false, chemistry = src.chemistry or "LiPo",
           capacityMah = src.capacityMah or 1300, cells = src.cells or 6,
           warn_pct = src.warn_pct, crit_pct = src.crit_pct,
           instances = copyInstances(src.instances) }
end

local function instancesEqual(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].id ~= b[i].id or a[i].label ~= b[i].label
       or (a[i].wear or 0) ~= (b[i].wear or 0)
       or (a[i].cycles or 0) ~= (b[i].cycles or 0) then
      return false
    end
  end
  return true
end

local function profilesEqual(a, b)
  return a.manufacturer == b.manufacturer and a.name == b.name and a.nameAuto == b.nameAuto
     and a.chemistry == b.chemistry and a.capacityMah == b.capacityMah and a.cells == b.cells
     and a.warn_pct == b.warn_pct and a.crit_pct == b.crit_pct
     and instancesEqual(a.instances, b.instances)
end

enterProfile = function(existing)
  if existing then
    S.prof      = copyProfile(existing)
    S.profOrig  = copyProfile(existing)
    S.profIsNew = false
  else
    S.prof      = newProfile()
    S.profOrig  = copyProfile(S.prof)
    S.profIsNew = true
  end
  -- Normalise both copies to label order (identical sort → no spurious "dirty").
  sortByLabel(S.prof.instances)
  sortByLabel(S.profOrig.instances)
  S.profCursor   = 1
  S.profEditing  = nil
  S.capStep      = 100
  S.textBuf      = nil
  S.textCharMode = false
  S.textSnapshot = nil
  S.screen       = SCREEN.PROFILE
end

local function leaveProfile()
  S.screen  = SCREEN.BATTERIES
  -- Place the list cursor; clamp later in handler.
end

-- Re-derive the auto name after a field that feeds it changed.
local function refreshAutoName()
  if S.prof.nameAuto then S.prof.name = genName(S.prof) end
end

-- Position-mode cursor range: 1..#buf (existing chars), then an append slot (#buf+1, only
-- while there's room for more), then a final Done target. These helpers classify S.textPos.
local function textDoneIndex()
  local n = #S.textBuf
  return n + ((n < S.textMax) and 2 or 1)
end
local function textIsAppendSlot()
  return #S.textBuf < S.textMax and S.textPos == #S.textBuf + 1
end
local function textIsDone() return S.textPos == textDoneIndex() end
-- Clear button: one slot past Done (rightmost), empties the whole field.
local function textClearIndex() return textDoneIndex() + 1 end
local function textIsClear() return S.textPos == textClearIndex() end

-- Builds the display descriptors; each carries its focusable item index plus the kind: a
-- two-column field {label,value} or a `folder` field (opens a sub-page). Name/Manufacturer
-- are edited in a full-screen editor (drawTextEditor), so here they show the stored value.
local function buildProfileLines()
  local p, lines = S.prof, {}
  local function field(item, label, value) lines[#lines + 1] = { item = item, label = label, value = value } end
  local function folder(item, label, value) lines[#lines + 1] = { item = item, label = label, value = value, folder = true } end

  field(1, "Name", p.name .. (p.nameAuto and "  (auto)" or ""))
  field(2, "Manufacturer", p.manufacturer ~= "" and p.manufacturer or "—")
  field(3, "Chemistry", p.chemistry)
  field(4, "Capacity", p.capacityMah .. " mAh")
  field(5, "Cells", p.cells .. "S")
  -- Opens the Packs page (per-pack cycles, wear, add/archive).
  folder(6, "Packs", tostring(#p.instances))
  field(7, "Low", p.warn_pct and (p.warn_pct .. " %")
        or (S.cfg.defaults.warn_pct .. " % (default)"))
  field(8, "Critical", p.crit_pct and (p.crit_pct .. " %")
        or (S.cfg.defaults.crit_pct .. " % (default)"))
  -- Items 9/10/(11) are the Save/Cancel/Delete buttons; they are not field rows —
  -- drawProfile renders them in the pinned bottom button bar.
  return lines
end

-- Bottom-bar buttons: Back/Save always (Back leftmost), Delete for an existing
-- profile, and "Reset name" only while the name is a manual override
-- (nameAuto == false) — it reverts to the auto-generated name. labels[i] cursor = 8 + i.
local function profileActions()
  local acts = { "Back", "Save" }
  if not S.profIsNew then acts[#acts + 1] = "Delete" end
  if not S.prof.nameAuto then acts[#acts + 1] = "Reset name" end
  return acts
end

-- Character-ring picker shown while a text field is edited: the characters of the
-- current group (ABC / abc / 123#) are laid out around a circle, the active one boxed.
-- Spinning the wheel moves the marker around the ring; MDL jumps to the next group.
-- The centre names the groups and which one is active. Space renders as "_".
local function drawCharRing(ch)
  local gi = S.charGroup or groupOfChar(ch)
  local s  = CHAR_GROUPS[gi].chars
  local m  = #s
  local active = string.find(s, ch, 1, true) or 1

  -- Overlay panel filling the body down to the screen edge (no button bar here).
  local top    = bodyY(2) - 2
  local bottom = LCD_H - PAD
  lcd.drawFilledRectangle(PAD, top, LCD_W - 2 * PAD, bottom - top, COLOR_THEME_SECONDARY3)

  local _, th = lcd.sizeText("Mg")                  -- glyph height
  local half  = math.floor(th / 2)
  local cx = math.floor(LCD_W / 2)
  local cy = math.floor((top + bottom) / 2)
  -- Radius leaves room for a glyph centred on the ring plus its marker, so the row of
  -- characters never spills past the top/bottom edges of the panel.
  local r  = math.floor((bottom - top) / 2) - half - 6

  for j = 1, m do
    local ang = 2 * math.pi * (j - 1) / m            -- clockwise, index 1 at the top
    local px  = cx + math.floor(r * math.sin(ang))
    local py  = cy - math.floor(r * math.cos(ang))   -- glyph centre on the ring
    local c   = string.sub(s, j, j)
    if c == " " then c = "_" end
    -- Active char: black marker with white glyph; the rest are plain black on the
    -- light background.
    if j == active then
      lcd.drawFilledCircle(px, py, half + 1, COLOR_THEME_PRIMARY1)
    end
    local fg = (j == active) and COLOR_THEME_PRIMARY2 or COLOR_THEME_PRIMARY1
    lcd.drawText(px, py - half, c, fg + CENTER)
  end

  -- Centre: the group switcher with arrows showing the cycle order MDL steps through.
  -- The active group is drawn black-on-white like a selected field, the rest plain
  -- black. (The "MDL switch group" key hint lives up top, by the field row.)
  local sep   = " > "
  local total = 0
  for i, g in ipairs(CHAR_GROUPS) do
    total = total + lcd.sizeText(g.label) + (i < #CHAR_GROUPS and lcd.sizeText(sep) or 0)
  end
  local gx = cx - math.floor(total / 2)
  local gy = cy - half
  for idx, g in ipairs(CHAR_GROUPS) do
    local flags = (idx == gi) and (COLOR_THEME_PRIMARY1 + INVERS) or COLOR_THEME_PRIMARY1
    lcd.drawText(gx, gy, g.label, flags)
    gx = gx + lcd.sizeText(g.label)
    if idx < #CHAR_GROUPS then
      lcd.drawText(gx, gy, sep, COLOR_THEME_PRIMARY1)
      gx = gx + lcd.sizeText(sep)
    end
  end
end

-- Draws the live edit value in the field row. The character/slot at the cursor is marked
-- black (white glyph) -- in char mode that's the char being edited, in position mode the
-- bracketed slot. Position mode also draws a Done button fixed at the right of the row
-- (styled like Back/Save). The text occupies the space left of it and, when it would not
-- fit (long names), shows a window around the active slot with "..." clip markers.
local INV_FLAGS = COLOR_THEME_PRIMARY1 + INVERS
local function drawEditValue(y)
  local buf, pos, n = S.textBuf, S.textPos, #S.textBuf

  -- Tokens for the text portion: each existing char, plus the active append slot.
  local toks = {}
  for i = 1, n do
    local c = string.sub(buf, i, i); if c == " " then c = "_" end
    if i == pos and S.textCharMode then
      toks[#toks + 1] = { s = c, f = INV_FLAGS }                 -- char being edited
    elseif i == pos then
      toks[#toks + 1] = { s = "[" .. c .. "]", f = INV_FLAGS }   -- selected slot (bracketed)
    else
      toks[#toks + 1] = { s = c, f = COLOR_THEME_PRIMARY1 }
    end
  end
  if not S.textCharMode and n < S.textMax and pos == n + 1 then
    toks[#toks + 1] = { s = "[_]", f = INV_FLAGS }               -- active append slot
  end
  for _, t in ipairs(toks) do t.w = lcd.sizeText(t.s) end

  -- Done/Clear buttons (position mode only), fixed at the right edge of the row;
  -- Clear sits rightmost, Done to its left.
  local rightEdge = LCD_W - PAD
  if not S.textCharMode then
    local clearW = lcd.sizeText("Clear") + 2 * BTN_PADX
    drawButton(rightEdge - clearW, y - 2, "Clear", pos == textClearIndex())
    rightEdge = rightEdge - clearW - PAD
    local doneW = lcd.sizeText("Done") + 2 * BTN_PADX
    drawButton(rightEdge - doneW, y - 2, "Done", pos == textDoneIndex())
    rightEdge = rightEdge - doneW - PAD
  end
  if #toks == 0 then return end

  -- Window [lo, hi] of tokens around the active one, fitting the text width; "..." marks a
  -- clipped side (reserved in the width so it never overflows).
  local availW = rightEdge - COL1
  local dotsW  = lcd.sizeText("...")
  local active = math.min(pos, #toks)        -- on Done: keep the tail visible
  local function winW(lo, hi)
    local w = 0
    for i = lo, hi do w = w + toks[i].w end
    if lo > 1     then w = w + dotsW end
    if hi < #toks then w = w + dotsW end
    return w
  end
  local lo, hi = active, active
  while true do
    local grew = false
    if lo > 1     and winW(lo - 1, hi) <= availW then lo = lo - 1; grew = true end
    if hi < #toks and winW(lo, hi + 1) <= availW then hi = hi + 1; grew = true end
    if not grew then break end
  end

  local x = COL1
  if lo > 1 then lcd.drawText(x, y, "...", COLOR_THEME_PRIMARY1); x = x + dotsW end
  for i = lo, hi do
    lcd.drawText(x, y, toks[i].s, toks[i].f); x = x + toks[i].w
  end
  if hi < #toks then lcd.drawText(x, y, "...", COLOR_THEME_PRIMARY1) end
end

-- Full-screen editor for Name (item 1) / Manufacturer (item 2): the edited text sits
-- at the top with the Done target, the char ring fills the rest while a slot is open.
local function drawTextEditor()
  drawHeader(S.profEditing == 2 and "EDIT MANUFACTURER" or "EDIT NAME")
  local y = bodyY(1)
  drawEditValue(y)
  if S.textCharMode then
    local ch = (S.textPos > #S.textBuf) and " " or string.sub(S.textBuf, S.textPos, S.textPos)
    drawCharRing(ch)
    drawKeyHint(y, "MDL", "switch group")   -- on the text row; no Done button in char mode
  else
    local hy, hx = bodyY(2), COL1
    hx = drawKeyChip(hx, hy, "Wheel", "slot") + PAD * 2
    drawKeyChip(hx, hy, "ENTER", "edit")
  end
end

local function drawProfile()
  if S.profEditing == 1 or S.profEditing == 2 then
    drawTextEditor()
    return
  end
  drawHeader(S.profIsNew and "ADD BATTERY" or "EDIT BATTERY")
  local lines = buildProfileLines()
  -- When the cursor is on a button (item > #lines) keep the bottom fields in view.
  local focus = #lines
  for i, ln in ipairs(lines) do
    if ln.item == S.profCursor then focus = i break end
  end
  -- Reserve the bottom line for the pinned button bar (+separator).
  local maxRows = math.max(1, math.floor((barTopY() - bodyY(1)) / LINE))
  local start   = math.max(1, math.min(focus - math.floor(maxRows / 2), #lines - maxRows + 1))
  if start < 1 then start = 1 end
  local editY, editVal
  for i = start, math.min(#lines, start + maxRows - 1) do
    local ln  = lines[i]
    local row = i - start + 1
    drawFieldRow(row, ln.label, ln.value,
                 { selected = ln.item == S.profCursor, editing = S.profEditing == ln.item, folder = ln.folder })
    if ln.item == S.profEditing then editY, editVal = bodyY(row), ln.value end
  end
  drawButtonBar(profileActions(), 9, S.profCursor)
  -- Key-chip hint for the capacity field (MDL toggles the step size).
  if editY and S.profEditing == 4 then
    local valueRight = editVal and (COL2 + lcd.sizeText(editVal))
    drawKeyHint(editY, "MDL", "step " .. S.capStep, valueRight)
  end
end

-- --- text field editing (Manufacturer / Name) ---

local function charAt(buf, pos)
  if pos > #buf then return " " end
  return string.sub(buf, pos, pos)
end

local function setChar(buf, pos, ch)
  if pos > #buf then
    return buf .. string.rep(" ", pos - #buf - 1) .. ch
  end
  return string.sub(buf, 1, pos - 1) .. ch .. string.sub(buf, pos + 1)
end

-- Cycles within the active group (S.charGroup) only and wraps at its ends; switching
-- groups is done with MDL, never by spinning the wheel past a group boundary.
local function cycleChar(ch, dir)
  local g = CHAR_GROUPS[S.charGroup].chars
  local i = string.find(g, ch, 1, true) or 1
  i = i + dir
  if i < 1 then i = #g elseif i > #g then i = 1 end
  return string.sub(g, i, i)
end

-- Starting character for a freshly opened position: uppercase 'A' for the first
-- character, lowercase 'a' for any later one (names typically read "Abc...").
local function defaultChar(pos) return pos == 1 and "A" or "a" end

-- Items 1 = Name, 2 = Manufacturer. Editing opens in position mode (pick a slot with the
-- wheel); ENTER on a slot opens the char ring, ENTER on Done commits, RTN discards.
local function startTextEdit(field)
  S.profEditing  = field
  S.textBuf      = (field == 2) and S.prof.manufacturer or S.prof.name
  S.textMax      = (field == 2) and MFR_MAX or NAME_MAX
  S.textPos      = 1
  S.textCharMode = false
  S.textSnapshot = nil
end

local function cancelTextEdit()
  S.profEditing, S.textBuf = nil, nil
  S.textCharMode, S.textSnapshot = false, nil
end

local function commitTextEdit()
  local s = string.gsub(S.textBuf, "%s+$", "")   -- trim trailing spaces
  if S.profEditing == 2 then
    S.prof.manufacturer = s
    refreshAutoName()
  else
    if s == "" then
      S.prof.nameAuto = true
      S.prof.name = genName(S.prof)
    else
      S.prof.name = s
      S.prof.nameAuto = false
    end
  end
  cancelTextEdit()
end

local function handleTextEdit(e)
  if S.textCharMode then
    -- Char mode: the ring. Wheel changes the character, MDL switches group.
    if isNext(e) then
      S.textBuf = setChar(S.textBuf, S.textPos, cycleChar(charAt(S.textBuf, S.textPos), 1))
    elseif isPrev(e) then
      S.textBuf = setChar(S.textBuf, S.textPos, cycleChar(charAt(S.textBuf, S.textPos), -1))
    elseif isGroupSwitch(e) then
      S.charGroup = S.charGroup % #CHAR_GROUPS + 1   -- MDL: ABC -> abc -> 123# -> ABC
      S.textBuf = setChar(S.textBuf, S.textPos, CHAR_GROUPS[S.charGroup].first)
    elseif isEnter(e) then                           -- accept, then auto-advance one slot
      S.textSnapshot, S.textCharMode = nil, false
      S.textPos = math.min(S.textPos + 1, textDoneIndex())
    elseif isExit(e) then                            -- discard this character's change
      S.textBuf, S.textSnapshot, S.textCharMode = S.textSnapshot, nil, false
      S.textPos = math.min(S.textPos, textDoneIndex())
    end
  else
    -- Position mode: the wheel walks the slots, ENTER drills in (or commits on Done).
    if isNext(e) then
      S.textPos = math.min(S.textPos + 1, textClearIndex())
    elseif isPrev(e) then
      S.textPos = math.max(1, S.textPos - 1)
    elseif isEnter(e) then
      if textIsClear() then
        S.textBuf, S.textPos = "", 1   -- empty the field, back to the first slot
      elseif textIsDone() then
        commitTextEdit()
      else
        S.textSnapshot = S.textBuf
        if textIsAppendSlot() then   -- new slot is seeded with its default char
          S.textBuf = setChar(S.textBuf, S.textPos, defaultChar(S.textPos))
        end
        S.charGroup = groupOfChar(charAt(S.textBuf, S.textPos))
        S.textCharMode = true
      end
    elseif isExit(e) then
      cancelTextEdit()
    end
  end
end

-- --- number / dropdown / optional-number editing ---

local function adjustNumber(e)
  local item = S.profEditing
  local p = S.prof
  if item == 3 then                                  -- chemistry dropdown
    local idx = 1
    for i, c in ipairs(CHEM_NAMES) do if c == p.chemistry then idx = i end end
    if isNext(e) then idx = idx % #CHEM_NAMES + 1
    elseif isPrev(e) then idx = (idx - 2) % #CHEM_NAMES + 1 end
    p.chemistry = CHEM_NAMES[idx]
    refreshAutoName()
  elseif item == 4 then                              -- capacity (MDL toggles step)
    if isGroupSwitch(e) then
      S.capStep = (S.capStep == 10 and 100) or (S.capStep == 100 and 1000) or 10
    elseif isNext(e) then p.capacityMah = math.min(50000, p.capacityMah + S.capStep)
    elseif isPrev(e) then p.capacityMah = math.max(10, p.capacityMah - S.capStep) end
    refreshAutoName()
  elseif item == 5 then                              -- cells
    if isNext(e) then p.cells = math.min(30, p.cells + 1)
    elseif isPrev(e) then p.cells = math.max(1, p.cells - 1) end
    refreshAutoName()
  elseif item == 7 or item == 8 then                 -- warn/crit override (nil = follow default)
    local key = (item == 7) and "warn_pct" or "crit_pct"
    local def = (item == 7) and S.cfg.defaults.warn_pct or S.cfg.defaults.crit_pct
    local cur = p[key] or def         -- nil sits on the default value
    if isNext(e) then cur = math.min(99, cur + 1)
    elseif isPrev(e) then cur = math.max(1, cur - 1) end
    -- Landing back on the default value clears the override (shows "(default)").
    if cur == def then p[key] = nil else p[key] = cur end
  end
  if isEnter(e) then S.profEditing = nil end
end

-- --- archiving ---

-- Names of parallel=true models this profile is assigned to.
local function parallelModelsUsing(cfg, id)
  local out = {}
  for name, m in pairs(cfg.models or {}) do
    if m.parallel == true and m.batteryIds then
      for _, bid in ipairs(m.batteryIds) do
        if bid == id then out[#out + 1] = modelDisplayName(name); break end
      end
    end
  end
  table.sort(out)
  return out
end

-- Retires one instance into config.archive, keyed by its stable pack id, keeping
-- the battery's name and last cycle count as a human-readable reference.
local function archiveInstance(profileName, instance)
  if not instance or not instance.id then return end
  S.cfg.archive[instance.id] = { name = profileName, cycles = instance.cycles or 0 }
end

-- --- save ---

local function validateProfile()
  if S.prof.manufacturer == "" then
    openAlert("Manufacturer required")
    return false
  end
  if S.prof.warn_pct and S.prof.crit_pct and not (S.prof.warn_pct > S.prof.crit_pct) then
    openAlert("Low must be above Critical")
    return false
  end
  return true
end

local function gotoBatteries()
  S.screen = SCREEN.BATTERIES
  S.cursor = 1
end

-- Mints ids for newly added packs (id == nil) and archives packs removed on the
-- Packs page (in the stored profile, gone from the working copy) into config.archive.
-- Hand-edited cycle counts ride along on the working instances and are persisted when
-- the profile is saved back into the library.
local function reconcileInstances()
  for _, p in ipairs(S.prof.instances) do
    if not p.id then p.id = nextPackId(S.cfg) end
  end
  local kept = {}
  for _, p in ipairs(S.prof.instances) do kept[p.id] = true end
  for _, p in ipairs(S.profOrig.instances) do
    if p.id and not kept[p.id] then
      archiveInstance(S.profOrig.name, p)
    end
  end
end

-- Persists the edited profile: reconcile packs (mint ids / archive removed), write
-- the profile (including its instances' cycle counts) back into the library, then
-- save the config.
local function saveProfile()
  if not validateProfile() then return end
  if S.prof.nameAuto then S.prof.name = genName(S.prof) end
  if S.profIsNew then S.prof.id = nextBatteryId(S.cfg) end

  reconcileInstances()
  local np = copyProfile(S.prof); np.id = S.prof.id
  if S.profIsNew then
    S.cfg.batteries[#S.cfg.batteries + 1] = np
  else
    for i, b in ipairs(S.cfg.batteries) do
      if b.id == S.prof.id then S.cfg.batteries[i] = np; break end
    end
  end
  withRetry(function() return saveConfig(S.cfg) end, gotoBatteries)
end

-- --- delete (archives the profile and all its packs) ---

local function doDeleteProfile()
  for _, p in ipairs(S.profOrig.instances) do
    archiveInstance(S.profOrig.name, p)
  end
  for i, b in ipairs(S.cfg.batteries) do
    if b.id == S.prof.id then
      table.remove(S.cfg.batteries, i)
      break
    end
  end
  withRetry(function() return saveConfig(S.cfg) end, gotoBatteries)
end

local function deleteProfile()
  local names = parallelModelsUsing(S.cfg, S.prof.id)
  if #names > 0 then
    openAlert("Used by parallel model(s) " .. table.concat(names, ", ") .. " — unassign first")
    return
  end
  openDialog("Delete profile and archive all " .. #S.profOrig.instances .. " packs?",
             doDeleteProfile)
end

local function cancelProfile()
  if profilesEqual(S.prof, S.profOrig) then
    leaveProfile()
  else
    openDialog("Discard changes?", leaveProfile)
  end
end

-- Reverts a manually overridden name to the auto-generated one, then parks the
-- cursor on the Name field (the "Reset name" button it sat on just vanished).
local function resetName()
  S.prof.nameAuto = true
  S.prof.name = genName(S.prof)
  S.profCursor = 1
end

-- 8 field items, then the bottom-bar buttons (Back/Save + maybe Delete/Reset name).
local function profileItemCount()
  return 8 + #profileActions()
end

local function handleProfile(e)
  if S.profEditing == 1 or S.profEditing == 2 then
    handleTextEdit(e)
    return 0
  elseif S.profEditing then
    if isExit(e) then S.profEditing = nil else adjustNumber(e) end
    return 0
  end

  S.profCursor = moveCursor(S.profCursor, e, profileItemCount())
  if isEnter(e) then
    local c = S.profCursor
    if c == 1 or c == 2 then
      startTextEdit(c)
    elseif c == 3 or c == 4 or c == 5 or c == 7 or c == 8 then
      S.profEditing = c
    elseif c == 6 then
      enterPacks()
    elseif c >= 9 then
      local act = profileActions()[c - 8]
      if act == "Save" then saveProfile()
      elseif act == "Back" then cancelProfile()
      elseif act == "Delete" then deleteProfile()
      elseif act == "Reset name" then resetName() end
    end
  elseif isExit(e) then
    cancelProfile()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Models: shared helpers
-- ---------------------------------------------------------------------------

local function modelFilename()
  local ok, info = pcall(model.getInfo)
  if ok and type(info) == "table" then return info.filename end
  return nil
end

-- The model's EdgeTX display name, read straight from /MODELS/<filename>.yml
-- (the header's first `name:` field) — no EdgeTX API needed, works for any model.
-- Falls back to the filename, and caches per session so the file is read once.
modelDisplayName = function(filename)
  if not filename then return "?" end
  S.modelNames = S.modelNames or {}
  if S.modelNames[filename] == nil then
    local name = filename
    local ok, f = pcall(io.open, "/MODELS/" .. filename, "r")
    if ok and f then
      local rok, head = pcall(io.read, f, 512)
      pcall(io.close, f)
      local m = rok and head and string.match(head, 'name:%s*"(.-)"')
      if m and m ~= "" then name = m end
    end
    S.modelNames[filename] = name
  end
  return S.modelNames[filename]
end

local function profileById(cfg, id)
  for _, b in ipairs(cfg.batteries) do
    if b.id == id then return b end
  end
  return nil
end

-- Configured model keys: active model first, then the rest alphabetically.
local function modelKeys(cfg, active)
  local keys = {}
  for k in pairs(cfg.models or {}) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if a == active then return true end
    if b == active then return false end
    return string.lower(a) < string.lower(b)
  end)
  return keys
end

-- True if the model satisfies the parallel invariant: at least one assigned
-- profile of the model's cell count with two or more instances.
local function parallelInvariantOk(cfg, m)
  for _, id in ipairs(m.batteryIds) do
    local p = profileById(cfg, id)
    if p and p.cells == m.cells and #(p.instances or {}) >= 2 then return true end
  end
  return false
end

local function idsEqual(a, b)
  if #a ~= #b then return false end
  local set = {}
  for _, id in ipairs(a) do set[id] = true end
  for _, id in ipairs(b) do if not set[id] then return false end end
  return true
end

-- Telemetry sensor names of the ACTIVE model (model.getSensor only sees the active
-- one), de-duplicated, in slot order. Slots can be sparse, so scan the whole range
-- rather than stopping at the first nil.
local function modelSensorNames()
  local names, seen = {}, {}
  for i = 0, 63 do
    local ok, s = pcall(model.getSensor, i)
    if ok and type(s) == "table" and s.name and s.name ~= "" and not seen[s.name] then
      seen[s.name] = true
      names[#names + 1] = s.name
    end
  end
  return names
end

-- True if any sensor field is set to a non-default name (so the model deviates from
-- the CRSF standard). An unset / empty / default-valued field does not count.
local function sensorsAreCustom(s)
  if not s then return false end
  for _, f in ipairs(SENSOR_FIELDS) do
    local v = s[f.key]
    if v and v ~= "" and v ~= DEFAULT_SENSORS[f.key] then return true end
  end
  return false
end

local function sensorsEqual(a, b)
  for _, f in ipairs(SENSOR_FIELDS) do
    if ((a and a[f.key]) or "") ~= ((b and b[f.key]) or "") then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Screen: Models list
-- ---------------------------------------------------------------------------

local enterModel   -- forward declaration

local function drawModels()
  drawHeader("MODELS")
  local active = modelFilename()
  local keys   = modelKeys(S.cfg, active)
  if #keys == 0 and not active then
    lcd.drawText(COL1, bodyY(1), "No models configured.", COLOR_THEME_PRIMARY1)
  else
    -- Scrolling window between header and button bar (same as the Batteries list).
    local maxRows = math.max(1, math.floor((barTopY() - bodyY(1)) / LINE))
    local focus   = math.max(1, math.min(S.cursor, #keys))
    local start   = math.max(1, math.min(focus - math.floor(maxRows / 2), #keys - maxRows + 1))
    if start < 1 then start = 1 end
    local row = 0
    for i = start, math.min(#keys, start + maxRows - 1) do
      row = row + 1
      local k = keys[i]
      drawNavRow(row, modelDisplayName(k) .. (k == active and "   [active]" or ""),
                 S.cursor == i, { folder = true })
    end
  end
  -- Bottom bar: always "Back" to the main menu first, then optionally
  -- "[+] Add current model" (when the active model is not configured yet).
  local actions = { "Back" }
  if active and not (S.cfg.models and S.cfg.models[active]) then
    actions[#actions + 1] = "[+] Add current model"
  end
  drawButtonBar(actions, #keys + 1, S.cursor)
end

local function modelListCount()
  local active     = modelFilename()
  local keys       = modelKeys(S.cfg, active)
  local addCurrent = active and not (S.cfg.models and S.cfg.models[active])
  local n          = #keys + (addCurrent and 1 or 0) + 1   -- + "Back"
  return n, keys, addCurrent
end

local function handleModels(e)
  local count, keys, addCurrent = modelListCount()
  S.cursor = moveCursor(S.cursor, e, math.max(1, count))
  if isEnter(e) then
    if S.cursor <= #keys then
      enterModel(keys[S.cursor])
    elseif S.cursor == #keys + 1 then
      S.screen = SCREEN.MAIN       -- Back
      S.cursor = 2
    elseif addCurrent and S.cursor == #keys + 2 then
      enterModel(nil)              -- add current model
    end
  elseif isExit(e) then
    S.screen = SCREEN.MAIN
    S.cursor = 2
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Model editor
-- ---------------------------------------------------------------------------

enterModel = function(key)
  local active = modelFilename()
  if key then
    local m = S.cfg.models[key]
    S.model = { filename = key, cells = m.cells or 6, parallel = m.parallel == true,
                batteryIds = {}, sensors = {} }
    for _, id in ipairs(m.batteryIds or {}) do S.model.batteryIds[#S.model.batteryIds + 1] = id end
    if m.sensors then
      for _, f in ipairs(SENSOR_FIELDS) do S.model.sensors[f.key] = m.sensors[f.key] end
    end
    S.modelIsNew = false
  else
    S.model = { filename = active, cells = 6, parallel = false, batteryIds = {}, sensors = {} }
    S.modelIsNew = true
  end
  -- model.getSensor() only enumerates the active model, so non-active models show
  -- their stored names read-only (see the Sensors sub-screen).
  S.modelIsActive = S.model.filename == active
  S.modelOrig = { cells = S.model.cells, parallel = S.model.parallel, batteryIds = {}, sensors = {} }
  for _, id in ipairs(S.model.batteryIds) do S.modelOrig.batteryIds[#S.modelOrig.batteryIds + 1] = id end
  for _, f in ipairs(SENSOR_FIELDS) do S.modelOrig.sensors[f.key] = S.model.sensors[f.key] end
  S.modelCursor  = 1
  S.modelEditing = false
  S.screen       = SCREEN.MODEL
end

local function modelItemCount()
  return S.modelIsNew and 6 or 7
end

local function modelDirty()
  return S.model.cells ~= S.modelOrig.cells
      or S.model.parallel ~= S.modelOrig.parallel
      or not idsEqual(S.model.batteryIds, S.modelOrig.batteryIds)
      or not sensorsEqual(S.model.sensors, S.modelOrig.sensors)
end

local function drawModel()
  drawHeader(S.modelIsNew and ("ADD MODEL  " .. modelDisplayName(S.model.filename))
             or ("EDIT MODEL  " .. modelDisplayName(S.model.filename)))
  drawFieldRow(1, "Cells", S.model.cells .. "S", { selected = S.modelCursor == 1, editing = S.modelEditing })
  drawFieldRow(2, "Parallel packs", S.model.parallel and "Yes" or "No", { selected = S.modelCursor == 2 })
  drawFieldRow(3, "Batteries", #S.model.batteryIds .. " selected", { selected = S.modelCursor == 3, folder = true })
  drawFieldRow(4, "Sensors", sensorsAreCustom(S.model.sensors) and "custom" or "default",
               { selected = S.modelCursor == 4, folder = true })
  local actions = S.modelIsNew and { "Back", "Save" }
                  or { "Back", "Save", "Delete" }
  drawButtonBar(actions, 5, S.modelCursor)
end

local function leaveModel()
  S.screen  = SCREEN.MODELS
  S.cursor  = 1
end

local function finishModelSave()
  local entry = {
    cells = S.model.cells, parallel = S.model.parallel,
    batteryIds = S.model.batteryIds,
  }
  -- Only persist sensors that differ from the CRSF default; an all-default model
  -- gets no sensors block, keeping the config minimal.
  if sensorsAreCustom(S.model.sensors) then
    entry.sensors = {}
    for _, f in ipairs(SENSOR_FIELDS) do
      local v = S.model.sensors[f.key]
      if v and v ~= "" and v ~= DEFAULT_SENSORS[f.key] then entry.sensors[f.key] = v end
    end
  end
  S.cfg.models[S.model.filename] = entry
  withRetry(function() return saveConfig(S.cfg) end, leaveModel)
end

-- Parallel invariant check, then write.
local function proceedModelSave()
  if S.model.parallel and not parallelInvariantOk(S.cfg, S.model) then
    openAlert("Parallel mode needs a profile with 2+ packs")
    return
  end
  finishModelSave()
end

local function saveModel()
  -- Cells change may invalidate assigned profiles of a different cell count.
  local invalid = {}
  for _, id in ipairs(S.model.batteryIds) do
    local p = profileById(S.cfg, id)
    if p and p.cells ~= S.model.cells then invalid[#invalid + 1] = id end
  end
  if #invalid > 0 then
    openDialog("Changing cells unassigns " .. #invalid .. " batteries. Continue?", function()
      local kept = {}
      for _, id in ipairs(S.model.batteryIds) do
        local p = profileById(S.cfg, id)
        if p and p.cells == S.model.cells then kept[#kept + 1] = id end
      end
      S.model.batteryIds = kept
      proceedModelSave()
    end)
  else
    proceedModelSave()
  end
end

local function deleteModel()
  openDialog("Delete model config for " .. modelDisplayName(S.model.filename) .. "?", function()
    S.cfg.models[S.model.filename] = nil
    withRetry(function() return saveConfig(S.cfg) end, leaveModel)
  end)
end

local function cancelModel()
  if modelDirty() then
    openDialog("Discard changes?", leaveModel)
  else
    leaveModel()
  end
end

local openAssign    -- forward declaration
local openSensors   -- forward declaration

local function handleModel(e)
  if S.modelEditing then            -- editing Cells (number)
    if isExit(e) then
      S.modelEditing = false
    elseif isNext(e) then
      S.model.cells = math.min(30, S.model.cells + 1)
    elseif isPrev(e) then
      S.model.cells = math.max(1, S.model.cells - 1)
    elseif isEnter(e) then
      S.modelEditing = false
    end
    return 0
  end

  S.modelCursor = moveCursor(S.modelCursor, e, modelItemCount())
  if isEnter(e) then
    local c = S.modelCursor
    if c == 1 then
      S.modelEditing = true
    elseif c == 2 then
      S.model.parallel = not S.model.parallel
    elseif c == 3 then
      openAssign()
    elseif c == 4 then
      openSensors()
    elseif c == 5 then
      cancelModel()      -- Back (discard with confirm if dirty)
    elseif c == 6 then
      saveModel()
    elseif c == 7 then
      deleteModel()
    end
  elseif isExit(e) then
    cancelModel()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: battery-assignment submenu
-- ---------------------------------------------------------------------------

openAssign = function()
  -- Profiles of the model's cell count, checked ones first then alphabetical.
  local matching = {}
  for _, b in ipairs(S.cfg.batteries) do
    if b.cells == S.model.cells then matching[#matching + 1] = b end
  end
  local checkedSet = {}
  for _, id in ipairs(S.model.batteryIds) do checkedSet[id] = true end
  table.sort(matching, function(a, b)
    local ca, cb = checkedSet[a.id] == true, checkedSet[b.id] == true
    if ca ~= cb then return ca end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  S.assignItems = {}
  for _, b in ipairs(matching) do
    local qty = #(b.instances or {})
    S.assignItems[#S.assignItems + 1] = {
      id = b.id, name = b.name,
      checked = checkedSet[b.id] == true,
      selectable = (not S.model.parallel) or qty >= 2,
    }
  end
  S.assignCursor = 1
  S.screen = SCREEN.ASSIGN
end

local function applyAssign()
  local ids = {}
  for _, it in ipairs(S.assignItems) do
    if it.checked then ids[#ids + 1] = it.id end
  end
  S.model.batteryIds = ids
  S.screen = SCREEN.MODEL
  S.modelCursor = 3
end

local function drawAssign()
  drawHeader(S.model.parallel and ("SELECT " .. S.model.cells .. "S PARALLEL PROFILE")
             or ("SELECT " .. S.model.cells .. "S BATTERIES"))
  if #S.assignItems == 0 then
    lcd.drawText(COL1, bodyY(1), "No matching profiles.", COLOR_THEME_PRIMARY1)
  end
  for i, it in ipairs(S.assignItems) do
    local box
    if S.model.parallel then box = it.checked and "(o) " or "( ) "
    else box = it.checked and "[x] " or "[ ] " end
    -- Non-selectable profiles (parallel needs 2+ packs) are simply dimmed.
    drawNavRow(i, box .. it.name, S.assignCursor == i, { disabled = not it.selectable })
  end
  drawButtonBar({ "Back" }, #S.assignItems + 1, S.assignCursor)
end

local function handleAssign(e)
  local count = #S.assignItems + 1
  S.assignCursor = moveCursor(S.assignCursor, e, count)
  if isEnter(e) then
    if S.assignCursor <= #S.assignItems then
      local it = S.assignItems[S.assignCursor]
      if it.selectable then
        if S.model.parallel then
          for _, o in ipairs(S.assignItems) do o.checked = false end
          it.checked = true
        else
          it.checked = not it.checked
        end
      end
    else
      applyAssign()
    end
  elseif isExit(e) then
    applyAssign()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: per-model sensor mapping
-- ---------------------------------------------------------------------------
-- Lets each model override the four CRSF sensor names. For the active model a picker
-- lists the live sensors (model.getSensor); a non-active model shows its stored names
-- read-only. S.sensorOpts is { false } .. <sensor names>, where the false sentinel
-- means "use the CRSF default" (stored as nil).

openSensors = function()
  S.sensorList = S.modelIsActive and modelSensorNames() or {}
  S.sensorOpts = { false }
  for _, n in ipairs(S.sensorList) do S.sensorOpts[#S.sensorOpts + 1] = n end
  S.sensorCursor = 1
  S.screen       = SCREEN.SENSORS
end

local function sensorRowValue(key)
  local v = S.model.sensors[key]
  if v and v ~= "" then return v end
  return DEFAULT_SENSORS[key] .. " (default)"
end

-- The "Reset to CRSF defaults" button only makes sense (and is only shown) when the
-- model is editable AND at least one sensor deviates from the default.
local function sensorsResetShown()
  return S.modelIsActive and sensorsAreCustom(S.model.sensors)
end

-- Cursor span: four field rows, then Back (+ the optional Reset button).
local function sensorItemCount()
  return 5 + (sensorsResetShown() and 1 or 0)
end

local function sensorOptIndex(v)
  if not v or v == "" then return 1 end
  for i = 2, #S.sensorOpts do
    if S.sensorOpts[i] == v then return i end
  end
  return 1
end

local function leaveSensors()
  S.screen      = SCREEN.MODEL
  S.modelCursor = 4
end

local function drawSensors()
  drawHeader("SENSORS  " .. modelDisplayName(S.model.filename))
  -- The per-field description uses a small font, pinned above the button bar.
  local _, smH  = lcd.sizeText("Mg", SMLSIZE)
  local smPitch = smH + 4

  -- Four sensor field rows at normal size.
  local y = bodyY(1)
  for i, f in ipairs(SENSOR_FIELDS) do
    drawFieldRowY(y, f.label, sensorRowValue(f.key), {
      selected = S.sensorCursor == i,
      disabled = not S.modelIsActive,
      popup    = S.modelIsActive,
    })
    y = y + LINE
  end

  -- Footer pinned above the buttons: the focused field's description when editable,
  -- otherwise the read-only hint. Cursor is clamped to a field when it sits on a button.
  local footTop = barTopY()
  if S.modelIsActive then
    local desc = SENSOR_FIELDS[math.min(S.sensorCursor, #SENSOR_FIELDS)].desc
    local dy   = footTop - #desc * smPitch - 4
    for j, line in ipairs(desc) do
      lcd.drawText(COL1, dy + (j - 1) * smPitch, line, COLOR_THEME_DISABLED + SMLSIZE)
    end
  else
    lcd.drawText(COL1, footTop - smPitch - 4, "Activate this model to edit sensors.", COLOR_THEME_DISABLED + SMLSIZE)
  end

  local actions = sensorsResetShown() and { "Back", "Reset to CRSF defaults" } or { "Back" }
  drawButtonBar(actions, 5, S.sensorCursor)
end

-- Picker for field index `c`: option 1 is the CRSF default (stored as nil), the
-- rest are the model's live sensor names.
local function openSensorPicker(c)
  local key    = SENSOR_FIELDS[c].key
  local labels = { DEFAULT_SENSORS[key] .. " (default)" }
  for i = 2, #S.sensorOpts do labels[i] = S.sensorOpts[i] end
  openPicker(SENSOR_FIELDS[c].label .. " sensor", labels, sensorOptIndex(S.model.sensors[key]),
             function(idx) S.model.sensors[key] = (idx > 1) and S.sensorOpts[idx] or nil end)
end

local function handleSensors(e)
  S.sensorCursor = moveCursor(S.sensorCursor, e, sensorItemCount())
  if isEnter(e) then
    local c = S.sensorCursor
    if c <= 4 then
      if S.modelIsActive then openSensorPicker(c) end
    elseif c == 5 then
      leaveSensors()                         -- Back
    elseif sensorsResetShown() and c == 6 then
      S.model.sensors = {}                   -- Reset to CRSF defaults
      S.sensorCursor  = 5                     -- Reset row just vanished; focus Back
    end
  elseif isExit(e) then
    leaveSensors()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Packs (per-pack cycles + wear, add / archive)
-- ---------------------------------------------------------------------------

-- Reason string if the highlighted pack must not be archived, else nil.
local function packArchiveLocked()
  if #S.prof.instances <= 1 then return "Last pack — delete the profile instead" end
  local names = parallelModelsUsing(S.cfg, S.prof.id)
  if #names > 0 and (#S.prof.instances - 1) < 2 then
    return "Used by parallel model(s) " .. table.concat(names, ", ") .. " — keep 2+ packs"
  end
  return nil
end

-- Editable cells of a dived-in pack row, in roller order.
local PACK_SUBS = { "cycles", "wear", "archive" }

enterPacks = function()
  S.packsCursor  = 1
  S.packDive     = nil        -- active row (dived in) or nil
  S.packSub      = "cycles"   -- "cycles" | "wear" | "archive" while dived
  S.packEditCyc  = false
  S.packEditWear = false
  S.screen       = SCREEN.PACKS
end

local function drawPacks()
  drawHeader("PACKS — " .. S.prof.name)
  local packs = S.prof.instances

  -- Column header row (bold, not selectable).
  local hy = bodyY(1)
  lcd.drawText(PK_ID,   hy, "ID",     COLOR_THEME_PRIMARY1 + BOLD)
  lcd.drawText(PK_CYC,  hy, "Cycles", COLOR_THEME_PRIMARY1 + BOLD)
  lcd.drawText(PK_WEAR, hy, "Wear",   COLOR_THEME_PRIMARY1 + BOLD)
  lcd.drawText(PK_ACT,  hy, "Remove", COLOR_THEME_PRIMARY1 + BOLD)

  -- Scrolling window of pack rows between the header and the pinned button bar,
  -- so many packs never overrun the bar. The selected row is kept in view; when
  -- the cursor is on Add/Done it stays scrolled to the bottom packs.
  local n       = #packs
  local maxRows = math.max(1, math.floor((barTopY() - bodyY(2)) / LINE))
  local focus   = math.max(1, math.min(S.packsCursor, n))
  local start   = math.max(1, math.min(focus - math.floor(maxRows / 2), n - maxRows + 1))
  if start < 1 then start = 1 end
  local dispRow = 1                              -- 1 = header row
  for i = start, math.min(n, start + maxRows - 1) do
    local p      = packs[i]
    dispRow      = dispRow + 1
    local y      = bodyY(dispRow)
    local dived  = S.packDive == i
    local rowSel = (S.packsCursor == i) and not dived
    -- In row navigation only the ID cell inverts (marks the current row); after
    -- diving in, only the active cell inverts (the wear/cycle cell blinks while
    -- being edited).
    local function cell(x, text, active, editing)
      local f = COLOR_THEME_PRIMARY1
      if editing then f = f + BLINK + INVERS
      elseif active then f = f + INVERS end
      lcd.drawText(x, y, text, f)
    end
    local cyc        = tostring(p.cycles or 0)
    local cycActive  = dived and S.packSub == "cycles"
    local wearActive = dived and S.packSub == "wear"
    local actActive  = dived and S.packSub == "archive"
    cell(PK_ID,   "#" .. p.label, rowSel, false)
    cell(PK_CYC,  cyc,            cycActive, cycActive and S.packEditCyc)
    cell(PK_WEAR, p.wear .. " %", wearActive, wearActive and S.packEditWear)
    drawButton(PK_ACT, y - 2, "Remove", actActive)   -- Back/Save-style button
  end

  drawButtonBar({ "Back", "[+] Add pack" }, #packs + 1, S.packsCursor)
end

local function handlePacks(e)
  local packs = S.prof.instances

  -- Editing the cycle count of the dived row (saved with the config on profile save).
  if S.packEditCyc then
    local p = packs[S.packDive]
    if isNext(e) then p.cycles = math.min(9999, (p.cycles or 0) + 1)
    elseif isPrev(e) then p.cycles = math.max(0, (p.cycles or 0) - 1)
    elseif isEnter(e) or isExit(e) then S.packEditCyc = false end
    return 0
  end

  -- Editing the wear value of the dived row.
  if S.packEditWear then
    local p = packs[S.packDive]
    if isNext(e) then p.wear = math.min(50, p.wear + 1)
    elseif isPrev(e) then p.wear = math.max(0, p.wear - 1)
    elseif isEnter(e) or isExit(e) then S.packEditWear = false end
    return 0
  end

  -- Dived into a row: roller moves Cycles→Wear→Remove, ENTER acts, EXIT leaves.
  if S.packDive then
    if isNext(e) or isPrev(e) then
      local idx = 1
      for j, s in ipairs(PACK_SUBS) do if s == S.packSub then idx = j end end
      idx = idx + (isNext(e) and 1 or -1)
      if idx < 1 then idx = #PACK_SUBS elseif idx > #PACK_SUBS then idx = 1 end
      S.packSub = PACK_SUBS[idx]
    elseif isEnter(e) then
      if S.packSub == "cycles" then
        S.packEditCyc = true
      elseif S.packSub == "wear" then
        S.packEditWear = true
      else
        local reason = packArchiveLocked()
        if reason then
          openAlert(reason)
        else
          table.remove(packs, S.packDive)   -- archived for real on profile save
          S.packDive = nil
          S.packsCursor = math.min(S.packsCursor, #packs + 2)
        end
      end
    elseif isExit(e) then
      S.packDive = nil
    end
    return 0
  end

  -- Row navigation.
  S.packsCursor = moveCursor(S.packsCursor, e, #packs + 2)
  if isEnter(e) then
    local c = S.packsCursor
    if c <= #packs then
      S.packDive, S.packSub = c, "cycles"
    elseif c == #packs + 1 then              -- Back
      S.screen = SCREEN.PROFILE
    else                                      -- [+] Add pack
      if #packs >= 20 then
        openAlert("Max 20 packs")
      else
        packs[#packs + 1] = { id = nil, label = nextLabel(packs), wear = 0, cycles = 0 }
        sortByLabel(packs)                   -- keep #1,#2,#3 order in the table
      end
    end
  elseif isExit(e) then
    S.screen = SCREEN.PROFILE
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function init()
  S.cfg, S.err, S.errDetail = loadConfig()
  S.modelNames = {}
  S.cursor    = 1
  S.dialog    = nil
  S.picker    = nil
  if S.err == "missing" then
    S.screen = SCREEN.FIRST_START
  elseif S.err then
    S.screen = SCREEN.CONFIG_ERROR
  else
    S.screen = SCREEN.MAIN
  end
end

-- Handle the event first, then draw — so one frame reflects the result of the
-- input (no one-frame lag) and a modal dialog renders on top of its screen.
local function handleEvent(event)
  if S.dialog then handleDialog(event); return 0 end
  if S.picker then handlePicker(event); return 0 end
  if S.screen == SCREEN.FIRST_START  then return handleFirstStart(event)  end
  if S.screen == SCREEN.CONFIG_ERROR then return handleConfigError(event) end
  if S.screen == SCREEN.BATTERIES    then return handleBatteries(event)   end
  if S.screen == SCREEN.PROFILE      then return handleProfile(event)     end
  if S.screen == SCREEN.PACKS        then return handlePacks(event)       end
  if S.screen == SCREEN.MODELS       then return handleModels(event)      end
  if S.screen == SCREEN.MODEL        then return handleModel(event)       end
  if S.screen == SCREEN.ASSIGN       then return handleAssign(event)      end
  if S.screen == SCREEN.SENSORS      then return handleSensors(event)     end
  if S.screen == SCREEN.DEFAULTS     then return handleDefaults(event)    end
  if S.screen == SCREEN.ABOUT        then return handleAbout(event)       end
  return handleMain(event)
end

local function draw()
  lcd.clear()
  if not S.lineMeasured then            -- correct row pitch to the real font height once
    local _, fh = lcd.sizeText("Mg")
    if fh and fh > 0 then LINE = math.max(LINE, fh + 8) end
    S.lineMeasured = true
  end
  if S.screen == SCREEN.FIRST_START then
    drawFirstStart()
  elseif S.screen == SCREEN.CONFIG_ERROR then
    drawConfigError()
  elseif S.screen == SCREEN.BATTERIES then
    drawBatteries()
  elseif S.screen == SCREEN.PROFILE then
    drawProfile()
  elseif S.screen == SCREEN.PACKS then
    drawPacks()
  elseif S.screen == SCREEN.MODELS then
    drawModels()
  elseif S.screen == SCREEN.MODEL then
    drawModel()
  elseif S.screen == SCREEN.ASSIGN then
    drawAssign()
  elseif S.screen == SCREEN.SENSORS then
    drawSensors()
  elseif S.screen == SCREEN.DEFAULTS then
    drawDefaults()
  elseif S.screen == SCREEN.ABOUT then
    drawAbout()
  else
    drawMain()
  end
  if S.picker then drawPicker() end   -- overlays
  if S.dialog then drawDialog() end   -- overlays
end

local function run(event, touchState)
  local ret = handleEvent(event) or 0
  draw()
  return ret
end

return { init = init, run = run }
