---- #TNS# "LIPONY"
---- #TNE#
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

local VERSION        = "1.0.0"
local SCHEMA_VERSION = 1
local CONFIG_PATH    = "/SCRIPTS/LIPONY/config.lua"
local STATS_PATH     = "/SCRIPTS/LIPONY/stats.lua"
local WARN_SOUND     = "/SOUNDS/en/scripts/LIPONY/warn.wav"
local CRIT_SOUND     = "/SOUNDS/en/scripts/LIPONY/crit.wav"

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

-- io.open "w" does NOT truncate on some EdgeTX/simulator builds, so a shorter
-- write would leave the old file's tail behind (a parse error). Pad with trailing
-- newlines — valid whitespace after the table — up to the previous length so the
-- old content is always fully overwritten. Pcall-wrapped so a read-only / full SD
-- card never raises.
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
  local ok, f = pcall(io.open, CONFIG_PATH, "r")
  if not ok or not f then return nil, "missing" end
  pcall(io.close, f)

  local pok, result = pcall(dofile, CONFIG_PATH)
  if not pok then return nil, "parse", tostring(result) end
  if type(result) ~= "table" then return nil, "parse", "not a table" end
  if result.schemaVersion ~= SCHEMA_VERSION then
    return nil, "schema", tostring(result.schemaVersion)
  end
  return result
end

-- Returns (stats) on success, or (nil, errKind) where errKind is "parse"|"schema".
-- A missing file is NOT an error — it is the legitimate empty start state. A file
-- that exists but cannot be parsed is reported so the caller refuses to overwrite
-- it (no silent reset that would discard the cycle history).
local function loadStats()
  local ok, f = pcall(io.open, STATS_PATH, "r")
  if not ok or not f then
    return { schemaVersion = SCHEMA_VERSION, instances = {}, archive = {} }
  end
  pcall(io.close, f)

  local pok, result = pcall(dofile, STATS_PATH)
  if not pok or type(result) ~= "table" or type(result.instances) ~= "table" then
    return nil, "parse"
  end
  if result.schemaVersion ~= SCHEMA_VERSION then return nil, "schema" end
  result.archive = result.archive or {}
  return result
end

local function defaultConfig()
  return {
    schemaVersion = SCHEMA_VERSION,
    generation    = 0,
    nextPackId    = 1,
    defaults      = { warn_pct = 30, crit_pct = 20 },
    batteries     = {},
    models        = {},
  }
end

-- Increments the reload sentinel and writes the config. Returns true on success.
local function saveConfig(cfg)
  cfg.generation = (cfg.generation or 0) + 1
  local content = "-- Lipo-Nanny configuration (auto-generated by the Tools-Script).\n"
                  .. "return " .. serialize(cfg, "") .. "\n"
  return writeFile(CONFIG_PATH, content)
end

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------

local SCREEN_FIRST_START  = "first_start"
local SCREEN_CONFIG_ERROR = "config_error"
local SCREEN_MAIN         = "main"
local SCREEN_BATTERIES    = "batteries"
local SCREEN_PROFILE      = "profile"
local SCREEN_PACKS        = "packs"
local SCREEN_MODELS       = "models"
local SCREEN_MODEL        = "model"
local SCREEN_ASSIGN       = "assign"
local SCREEN_DEFAULTS     = "defaults"
local SCREEN_ABOUT        = "about"

local CHEM_NAMES = { "LiPo", "LiPoHV", "LiIon" }
local CHARSET    = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-+.#"
local MFR_MAX  = 10
local NAME_MAX = 30

local S = {
  screen   = SCREEN_MAIN,
  cfg      = nil,
  stats    = nil,
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
-- Event helpers (color-radio virtual keys)
-- ---------------------------------------------------------------------------

local function isNext(e)
  return e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC
end
local function isPrev(e)
  return e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC
end
local function isEnter(e) return e == EVT_VIRTUAL_ENTER end
local function isExit(e)  return e == EVT_VIRTUAL_EXIT end

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
local LINE = math.max(18, math.floor(LCD_H / 13))
local COL1 = PAD * 2                    -- label / entry column
local COL2 = math.floor(LCD_W * 0.42)   -- value column (two-column editor fields)

local function btn(name) return "[--" .. name .. "--]" end

-- Packs table column x-anchors (computed from the display width).
local PK_ID, PK_CYC, PK_WEAR, PK_ACT =
  COL1, math.floor(LCD_W * 0.24), math.floor(LCD_W * 0.46), math.floor(LCD_W * 0.68)

local function drawHeader(title)
  local h = LINE + PAD
  lcd.drawFilledRectangle(0, 0, LCD_W, h, COLOR_THEME_SECONDARY1)
  local _, th = lcd.sizeText("Mg")            -- font height; vertically centre the title
  lcd.drawText(PAD, math.floor((h - th) / 2), title, COLOR_THEME_PRIMARY2 + BOLD)
end

local function bodyY(row)
  return LINE + PAD * 2 + (row - 1) * LINE
end

-- Selection is shown by inverting text (no focus bar). A navigation/action row
-- (list entry, button, sub-page opener) is a single string at COL1: `folder`
-- prefixes "> " and bolds it (everything that opens a sub-page), `disabled` dims
-- it, and the cursor row is drawn INVERS.
local function drawNavRow(row, text, selected, opts)
  opts = opts or {}
  local flags = opts.disabled and COLOR_THEME_DISABLED or COLOR_THEME_PRIMARY1
  if opts.folder then text = "> " .. text; flags = flags + BOLD end
  if selected then flags = flags + INVERS end
  lcd.drawText(COL1, bodyY(row), text, flags)
end

-- A two-column field row: label at COL1, value at COL2. Only the value is
-- highlighted — INVERS when the row is selected, BLINK+INVERS while editing —
-- except a folder field (opens a sub-page), where the whole row inverts.
local function drawFieldRow(row, label, value, opts)
  opts = opts or {}
  local y      = bodyY(row)
  local base   = opts.disabled and COLOR_THEME_DISABLED or COLOR_THEME_PRIMARY1
  local lflags = base
  if opts.folder then label = "> " .. label; lflags = lflags + BOLD end
  if opts.selected and opts.folder then lflags = lflags + INVERS end
  lcd.drawText(COL1, y, label, lflags)
  if value ~= nil then
    local vflags = base
    if opts.editing then vflags = vflags + BLINK + INVERS
    elseif opts.selected then vflags = vflags + INVERS end
    lcd.drawText(COL2, y, value, vflags)
  end
end

-- Draws a row from left-to-right segments starting at COL1, so a single element
-- can be highlighted instead of the whole line (used by the Packs page when
-- "dived" into a row). seg.hl: "sel" → INVERS, "edit" → BLINK+INVERS, nil → plain.
local function drawSegments(row, segments)
  local x, y = COL1, bodyY(row)
  for _, seg in ipairs(segments) do
    local flags = COLOR_THEME_PRIMARY1
    if seg.hl == "edit" then flags = flags + BLINK + INVERS
    elseif seg.hl == "sel" then flags = flags + INVERS end
    lcd.drawText(x, y, seg.text, flags)
    x = x + (lcd.sizeText and lcd.sizeText(seg.text) or (#seg.text * 6))
  end
end

-- Action buttons as one horizontal bar pinned just above the footer, separated by
-- a thin line. The button whose cursor index is selected is drawn inverted.
-- `firstItem` is the cursor index of labels[1]; pass the screen's cursor value.
-- Gap (px) between the separator line and the button row.
local BTN_GAP = 8

-- Y of the separator line above the bottom button bar — also the bottom edge of
-- the scrolling content area above. The buttons get equal spacing above (to the
-- separator) and below (to the screen edge): both BTN_GAP.
local function barTopY()
  local _, th = lcd.sizeText("Mg")
  return LCD_H - (th + 4) - 2 * BTN_GAP
end

-- Bottom button bar: each action is drawn as a real button (outlined box; the
-- selected one filled with the accent colour). `firstItem` is the cursor index of
-- labels[1]; pass the screen's cursor value.
local function drawButtonBar(labels, firstItem, cursor)
  local _, th = lcd.sizeText("Mg")
  local btnH  = th + 4
  local sepY  = barTopY()
  local btnY  = sepY + BTN_GAP
  lcd.drawFilledRectangle(PAD, sepY, LCD_W - 2 * PAD, 1, COLOR_THEME_PRIMARY3)
  local padX, x = 6, PAD
  for i, label in ipairs(labels) do
    local w   = lcd.sizeText(label) + 2 * padX
    if cursor == firstItem + i - 1 then
      lcd.drawFilledRectangle(x, btnY, w, btnH, COLOR_THEME_FOCUS)
      lcd.drawText(x + padX, btnY + 2, label, COLOR_THEME_PRIMARY2)
    else
      lcd.drawRectangle(x, btnY, w, btnH, COLOR_THEME_PRIMARY1)
      lcd.drawText(x + padX, btnY + 2, label, COLOR_THEME_PRIMARY1)
    end
    x = x + w + PAD
  end
end

-- Inline hint for the non-obvious PAGE function of the field being edited: a
-- "<PAGE>" key chip (filled, like a hardware button) plus what it does, drawn
-- right-aligned on the edited row.
-- `valueRight` = right edge (px) of the field's value text; the hint is skipped
-- when the value would reach it, so a long Name never overlaps the chip.
local function drawPageHint(y, action, valueRight)
  local key       = "<PAGE>"
  local kw, kh    = lcd.sizeText(key)
  local aw        = lcd.sizeText(action)
  local x         = LCD_W - PAD - (kw + 4 + 4 + aw)
  if valueRight and valueRight + PAD > x then return end   -- would overlap the value
  lcd.drawFilledRectangle(x, y - 1, kw + 4, kh + 2, COLOR_THEME_FOCUS)
  lcd.drawText(x + 2, y, key, COLOR_THEME_PRIMARY2)
  lcd.drawText(x + kw + 8, y, action, COLOR_THEME_PRIMARY1)
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
-- Screen: first start
-- ---------------------------------------------------------------------------

local function drawFirstStart()
  drawHeader("LIPONY — First start")
  lcd.drawText(COL1, bodyY(1), "No configuration found.", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(2), "Press ENTER to create defaults.", COLOR_THEME_PRIMARY1)
  drawButtonBar({ "Create" }, 1, 1)
end

local function handleFirstStart(e)
  if isEnter(e) then
    S.cfg = defaultConfig()
    withRetry(function() return saveConfig(S.cfg) end, function()
      S.screen = SCREEN_MAIN
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
  lcd.drawText(COL1, bodyY(3), "Edit config.lua on PC", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(4), "or delete it to reset.", COLOR_THEME_PRIMARY1)
  drawButtonBar({ "Exit" }, 1, 1)
end

local function handleConfigError(e)
  if isEnter(e) or isExit(e) then return 1 end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: main menu
-- ---------------------------------------------------------------------------

local MAIN_ITEMS = { "Batteries", "Models", "Settings", "About" }

local function drawMain()
  drawHeader("LIPONY — SETUP")
  for i, item in ipairs(MAIN_ITEMS) do
    drawNavRow(i, item, S.cursor == i, { folder = true })
  end
end

local function enterDefaults()
  S.def        = { warn = S.cfg.defaults.warn_pct, crit = S.cfg.defaults.crit_pct }
  S.defEditing = false
  S.cursor     = 1
  S.screen     = SCREEN_DEFAULTS
end

local function handleMain(e)
  S.cursor = moveCursor(S.cursor, e, #MAIN_ITEMS)
  if isEnter(e) then
    local item = MAIN_ITEMS[S.cursor]
    if item == "Batteries" then
      S.screen = SCREEN_BATTERIES
      S.cursor = 1
    elseif item == "Models" then
      S.screen = SCREEN_MODELS
      S.cursor = 1
    elseif item == "Settings" then
      enterDefaults()
    elseif item == "About" then
      S.screen = SCREEN_ABOUT
    end
  elseif isExit(e) then
    return 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: About
-- ---------------------------------------------------------------------------

local function drawAbout()
  drawHeader("LIPO-NANNY")
  lcd.drawText(COL1, bodyY(1), "(c) Mariator-pro   GPL-2.0", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(2), "LIPONY  v" .. VERSION, COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(3), "Widget: /WIDGETS/LIPONY/main.lua", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(4), "Tools:  /SCRIPTS/TOOLS/LIPONY.lua", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(5), "Data:   /SCRIPTS/LIPONY/", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(6), "Schema version: " .. SCHEMA_VERSION, COLOR_THEME_PRIMARY1)
end

local function handleAbout(e)
  if isExit(e) then S.screen = SCREEN_MAIN; S.cursor = 4 end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Defaults editor
-- ---------------------------------------------------------------------------

local DEF_ITEMS = 6   -- warn, crit, test-warn, test-crit, save, cancel

local function defaultsDirty()
  return S.def.warn ~= S.cfg.defaults.warn_pct or S.def.crit ~= S.cfg.defaults.crit_pct
end

local function leaveDefaults()
  S.screen = SCREEN_MAIN
  S.cursor = 3
end

local function saveDefaults()
  if not (S.def.warn > S.def.crit) then
    openAlert("Low must be above Critical")
    return
  end
  S.cfg.defaults.warn_pct = S.def.warn
  S.cfg.defaults.crit_pct = S.def.crit
  withRetry(function() return saveConfig(S.cfg) end, leaveDefaults)
end

local function cancelDefaults()
  if defaultsDirty() then
    openDialog("Discard changes?", leaveDefaults)
  else
    leaveDefaults()
  end
end

local function drawDefaults()
  drawHeader("SETTINGS")
  drawFieldRow(1, "Low threshold", S.def.warn .. " %",
               { selected = S.cursor == 1, editing = S.defEditing and S.defField == "warn" })
  drawFieldRow(2, "Critical threshold", S.def.crit .. " %",
               { selected = S.cursor == 2, editing = S.defEditing and S.defField == "crit" })
  drawNavRow(3, btn("Test low sound"), S.cursor == 3)
  drawNavRow(4, btn("Test critical sound"), S.cursor == 4)
  drawButtonBar({ "Save", "Cancel" }, 5, S.cursor)
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

  S.cursor = moveCursor(S.cursor, e, DEF_ITEMS)
  if isEnter(e) then
    if S.cursor == 1 then
      S.defEditing, S.defField, S.defOrig = true, "warn", S.def.warn
    elseif S.cursor == 2 then
      S.defEditing, S.defField, S.defOrig = true, "crit", S.def.crit
    elseif S.cursor == 3 then
      playFile(WARN_SOUND)
    elseif S.cursor == 4 then
      playFile(CRIT_SOUND)
    elseif S.cursor == 5 then
      saveDefaults()
    elseif S.cursor == 6 then
      cancelDefaults()
    end
  elseif isExit(e) then
    cancelDefaults()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Batteries: shared helpers
-- ---------------------------------------------------------------------------

local function isPageNext(e) return e == EVT_VIRTUAL_NEXT_PAGE end
local function isPagePrev(e) return e == EVT_VIRTUAL_PREV_PAGE end

-- Auto-generated profile name: "<Manufacturer> <S>s <Chemistry> <mAh>mAh"
-- e.g. "Tattu 6s LiPo 1300mAh".
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

-- Cycle count for one physical battery, keyed by its stable pack id (0 if none).
local function cyclesFor(packId)
  local inst = S.stats and S.stats.instances
  local e    = packId and inst and inst[packId]
  return (e and e.cycles) or 0
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
  drawButtonBar({ "[+] Add new" }, #items + 1, S.cursor)
end

local function handleBatteries(e)
  local items = batteryListItems()
  local count = #items + 1            -- profiles + "[+] Add new"
  S.cursor = moveCursor(S.cursor, e, count)
  if isEnter(e) then
    if S.cursor <= #items then
      enterProfile(items[S.cursor])
    else
      enterProfile(nil)
    end
  elseif isExit(e) then
    S.screen = SCREEN_MAIN
    S.cursor = 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Profile editor
-- ---------------------------------------------------------------------------

-- Focusable items: name, manufacturer, chemistry, capacity, cells, packs,
-- warn, crit, [Save], [Cancel], and [Delete] (11, existing profiles only).

-- Smallest positive label not yet used by the instance list (B1: a new pack
-- fills the lowest free display number, leaving archived numbers as gaps).
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
              instances = { { id = nil, label = 1, wear = 0 } } }
  p.name = genName(p)
  return p
end

-- Deep-copies the instance objects { id, label, wear } so the editor can mutate
-- its working copy without touching the stored profile until save.
local function copyInstances(src)
  local out = {}
  for i, p in ipairs(src or {}) do
    out[i] = { id = p.id, label = p.label, wear = p.wear or 0 }
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
  -- Cycle counts live in stats.lua, not the profile; load them onto the working
  -- copies so they can be shown and hand-edited on the Packs page (synced back to
  -- stats on save). The baseline copy carries them too, for the dirty check.
  for _, p in ipairs(S.prof.instances)     do p.cycles = cyclesFor(p.id) end
  for _, p in ipairs(S.profOrig.instances) do p.cycles = cyclesFor(p.id) end
  S.profCursor  = 1
  S.profEditing = nil
  S.capStep     = 100
  S.textBuf     = nil
  S.screen      = SCREEN_PROFILE
end

local function leaveProfile()
  S.screen  = SCREEN_BATTERIES
  -- Place the list cursor; clamp later in handler.
end

-- Re-derive the auto name after a field that feeds it changed.
local function refreshAutoName()
  if S.prof.nameAuto then S.prof.name = genName(S.prof) end
end

-- Live text-edit buffer with the cursor character in brackets, so the pilot sees
-- which character the roller is changing.
local function textWithCursor(buf, pos)
  local ch     = (pos > #buf) and " " or string.sub(buf, pos, pos)
  local before = string.sub(buf, 1, pos - 1)
  local after  = (pos < #buf) and string.sub(buf, pos + 1) or ""
  return before .. "[" .. ch .. "]" .. after
end

-- Builds the display descriptors; each carries its focusable item index plus the
-- kind: a two-column field {label,value}, a `folder` field (opens a sub-page) or
-- a `button`. While a text field is being edited, its value is the live buffer.
local function buildProfileLines()
  local p, lines = S.prof, {}
  local function field(item, label, value) lines[#lines + 1] = { item = item, label = label, value = value } end
  local function folder(item, label, value) lines[#lines + 1] = { item = item, label = label, value = value, folder = true } end

  if S.profEditing == 1 then
    field(1, "Name", textWithCursor(S.textBuf, S.textPos))
  else
    field(1, "Name", p.name .. (p.nameAuto and "  (auto)" or ""))
  end
  if S.profEditing == 2 then
    field(2, "Manufacturer", textWithCursor(S.textBuf, S.textPos))
  else
    field(2, "Manufacturer", p.manufacturer ~= "" and p.manufacturer or "—")
  end
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

-- Bottom-bar buttons: Save/Cancel always, Delete for an existing profile, and
-- "Reset name" only while the name is a manual override (nameAuto == false) — it
-- reverts to the auto-generated name. The cursor index of labels[i] is 8 + i.
local function profileActions()
  local acts = { "Save", "Cancel" }
  if not S.profIsNew then acts[#acts + 1] = "Delete" end
  if not S.prof.nameAuto then acts[#acts + 1] = "Reset name" end
  return acts
end

local function drawProfile()
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
    local sel = ln.item == S.profCursor
    local row = i - start + 1
    -- Text fields (1,2) show their bracketed live buffer; don't also blink it.
    local editing = (S.profEditing == ln.item) and ln.item ~= 1 and ln.item ~= 2
    drawFieldRow(row, ln.label, ln.value, { selected = sel, editing = editing, folder = ln.folder })
    if ln.item == S.profEditing then editY = bodyY(row); editVal = ln.value end
  end
  drawButtonBar(profileActions(), 9, S.profCursor)
  -- Inline PAGE hint for the two fields whose PAGE function isn't self-evident;
  -- skipped automatically if the value text would reach the chip.
  local valueRight = editVal and (COL2 + lcd.sizeText(editVal))
  if editY and S.profEditing == 4 then
    drawPageHint(editY, "step " .. S.capStep, valueRight)
  elseif editY and (S.profEditing == 1 or S.profEditing == 2) then
    drawPageHint(editY, "move cursor", valueRight)
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

local function cycleChar(ch, dir)
  local i = string.find(CHARSET, ch, 1, true) or 1
  i = i + dir
  if i < 1 then i = #CHARSET elseif i > #CHARSET then i = 1 end
  return string.sub(CHARSET, i, i)
end

-- Items 1 = Name, 2 = Manufacturer.
local function startTextEdit(field)
  S.profEditing = field
  S.textBuf = (field == 2) and S.prof.manufacturer or S.prof.name
  S.textMax = (field == 2) and MFR_MAX or NAME_MAX
  S.textPos = math.max(1, #S.textBuf)
  if #S.textBuf == 0 then S.textPos = 1 end
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
  S.profEditing, S.textBuf = nil, nil
end

local function handleTextEdit(e)
  if isNext(e) then
    S.textBuf = setChar(S.textBuf, S.textPos, cycleChar(charAt(S.textBuf, S.textPos), 1))
  elseif isPrev(e) then
    S.textBuf = setChar(S.textBuf, S.textPos, cycleChar(charAt(S.textBuf, S.textPos), -1))
  elseif isPageNext(e) then
    S.textPos = math.min(S.textMax, #S.textBuf + 1, S.textPos + 1)
  elseif isPagePrev(e) then
    S.textPos = math.max(1, S.textPos - 1)
  elseif isEnter(e) then
    commitTextEdit()
  elseif isExit(e) then
    S.profEditing, S.textBuf = nil, nil   -- cancel
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
  elseif item == 4 then                              -- capacity (PAGE toggles step)
    if isPageNext(e) or isPagePrev(e) then
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

-- Writes stats.lua (active cycle counts + the archive of retired packs). The
-- widget owns the active counts and the tool owns the archive; each re-reads the
-- file before writing so it never clobbers the other's part.
local function writeStats(stats)
  local content = "-- Lipo-Nanny statistics: active cycle counts + archived packs.\n"
                  .. "return " .. serialize(stats, "") .. "\n"
  return writeFile(STATS_PATH, content)
end

-- Retires one instance: moves it from stats.instances into stats.archive, keyed
-- by its stable pack id, keeping the battery's name as a human-readable reference.
local function archiveInstance(stats, profileName, packId)
  if not packId then return end
  local snap = stats.instances[packId]
  stats.archive[packId] = { name = profileName, cycles = (snap and snap.cycles) or 0 }
  stats.instances[packId] = nil
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
  S.screen = SCREEN_BATTERIES
  S.cursor = 1
end

-- Mints pack ids for packs the pilot just added (placeholders, id == nil),
-- archives packs removed on the Packs page (present in the stored profile, gone
-- from the working copy), and writes back any hand-edited cycle counts onto
-- stats.instances. Returns true if stats.lua needs a write (something archived or
-- a cycle count changed). Runs once before the retried file writes.
local function reconcileInstances()
  for _, p in ipairs(S.prof.instances) do
    if not p.id then p.id = nextPackId(S.cfg) end
  end
  local kept = {}
  for _, p in ipairs(S.prof.instances) do kept[p.id] = true end
  local statsDirty = false
  -- Archive packs removed from the list.
  for _, p in ipairs(S.profOrig.instances) do
    if p.id and not kept[p.id] then
      archiveInstance(S.stats, S.profOrig.name, p.id)
      statsDirty = true
    end
  end
  -- Persist (possibly hand-edited) cycle counts of the kept packs.
  for _, p in ipairs(S.prof.instances) do
    local cur  = (S.stats.instances[p.id] and S.stats.instances[p.id].cycles) or 0
    local want = p.cycles or 0
    if want ~= cur then
      S.stats.instances[p.id] = S.stats.instances[p.id] or {}
      S.stats.instances[p.id].cycles = want
      statsDirty = true
    end
  end
  return statsDirty
end

-- Persists the edited profile: reconcile packs (ids / archive / cycle edits) into
-- stats, write the profile back into the library, then write stats (only when it
-- changed) followed by the config.
local function saveProfile()
  if not validateProfile() then return end
  if S.prof.nameAuto then S.prof.name = genName(S.prof) end
  if S.profIsNew then S.prof.id = nextBatteryId(S.cfg) end

  local statsDirty = reconcileInstances()
  local np = copyProfile(S.prof); np.id = S.prof.id
  if S.profIsNew then
    S.cfg.batteries[#S.cfg.batteries + 1] = np
  else
    for i, b in ipairs(S.cfg.batteries) do
      if b.id == S.prof.id then S.cfg.batteries[i] = np; break end
    end
  end
  withRetry(function()
    if statsDirty and not writeStats(S.stats) then return false end
    return saveConfig(S.cfg)
  end, gotoBatteries)
end

-- --- delete (archives the profile and all its packs) ---

local function doDeleteProfile()
  for _, p in ipairs(S.profOrig.instances) do
    archiveInstance(S.stats, S.profOrig.name, p.id)
  end
  for i, b in ipairs(S.cfg.batteries) do
    if b.id == S.prof.id then
      table.remove(S.cfg.batteries, i)
      break
    end
  end
  withRetry(function()
    if not writeStats(S.stats) then return false end
    return saveConfig(S.cfg)
  end, gotoBatteries)
end

local function deleteProfile()
  -- Deleting archives all packs → writes stats. Refuse if stats is unreadable.
  if S.statsErr then
    openAlert("stats.lua unreadable — fix on PC")
    return
  end
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

-- 8 field items, then the bottom-bar buttons (Save/Cancel + maybe Delete/Reset).
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
      elseif act == "Cancel" then cancelProfile()
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
  -- Offer to add the active model when it is not configured yet (pinned bottom bar).
  if active and not (S.cfg.models and S.cfg.models[active]) then
    drawButtonBar({ "[+] Add current model" }, #keys + 1, S.cursor)
  end
end

local function modelListCount()
  local active = modelFilename()
  local keys   = modelKeys(S.cfg, active)
  local n      = #keys
  if active and not (S.cfg.models and S.cfg.models[active]) then n = n + 1 end
  return n, keys, active
end

local function handleModels(e)
  local count, keys, active = modelListCount()
  S.cursor = moveCursor(S.cursor, e, math.max(1, count))
  if isEnter(e) then
    if S.cursor <= #keys then
      enterModel(keys[S.cursor])
    elseif active then
      enterModel(nil)            -- add current model
    end
  elseif isExit(e) then
    S.screen = SCREEN_MAIN
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
                batteryIds = {} }
    for _, id in ipairs(m.batteryIds or {}) do S.model.batteryIds[#S.model.batteryIds + 1] = id end
    S.modelIsNew = false
  else
    S.model = { filename = active, cells = 6, parallel = false, batteryIds = {} }
    S.modelIsNew = true
  end
  S.modelOrig = { cells = S.model.cells, parallel = S.model.parallel, batteryIds = {} }
  for _, id in ipairs(S.model.batteryIds) do S.modelOrig.batteryIds[#S.modelOrig.batteryIds + 1] = id end
  S.modelCursor  = 1
  S.modelEditing = false
  S.screen       = SCREEN_MODEL
end

local function modelItemCount()
  return S.modelIsNew and 5 or 6
end

local function modelDirty()
  return S.model.cells ~= S.modelOrig.cells
      or S.model.parallel ~= S.modelOrig.parallel
      or not idsEqual(S.model.batteryIds, S.modelOrig.batteryIds)
end

local function drawModel()
  drawHeader(S.modelIsNew and ("ADD MODEL  " .. modelDisplayName(S.model.filename))
             or ("EDIT MODEL  " .. modelDisplayName(S.model.filename)))
  drawFieldRow(1, "Cells", S.model.cells .. "S", { selected = S.modelCursor == 1, editing = S.modelEditing })
  drawFieldRow(2, "Parallel packs", S.model.parallel and "Yes" or "No", { selected = S.modelCursor == 2 })
  drawFieldRow(3, "Batteries", #S.model.batteryIds .. " selected", { selected = S.modelCursor == 3, folder = true })
  local actions = S.modelIsNew and { "Save", "Cancel" }
                  or { "Save", "Cancel", "Delete" }
  drawButtonBar(actions, 4, S.modelCursor)
end

local function leaveModel()
  S.screen  = SCREEN_MODELS
  S.cursor  = 1
end

local function finishModelSave()
  S.cfg.models[S.model.filename] = {
    cells = S.model.cells, parallel = S.model.parallel,
    batteryIds = S.model.batteryIds,
  }
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

local openAssign   -- forward declaration

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
      saveModel()
    elseif c == 5 then
      cancelModel()
    elseif c == 6 then
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
  S.screen = SCREEN_ASSIGN
end

local function applyAssign()
  local ids = {}
  for _, it in ipairs(S.assignItems) do
    if it.checked then ids[#ids + 1] = it.id end
  end
  S.model.batteryIds = ids
  S.screen = SCREEN_MODEL
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
  drawButtonBar({ "Done" }, #S.assignItems + 1, S.assignCursor)
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
-- Screen: Packs (per-pack cycles + wear, add / archive)
-- ---------------------------------------------------------------------------

-- Reason string if the highlighted pack must not be archived, else nil.
local function packArchiveLocked()
  if #S.prof.instances <= 1 then return "Last pack — delete the profile instead" end
  if S.statsErr then return "stats.lua unreadable — fix on PC" end
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
  S.screen       = SCREEN_PACKS
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
    local cyc        = S.statsErr and "?" or tostring(p.cycles or 0)
    local cycActive  = dived and S.packSub == "cycles"
    local wearActive = dived and S.packSub == "wear"
    local actActive  = dived and S.packSub == "archive"
    cell(PK_ID,   "#" .. p.label, rowSel, false)
    cell(PK_CYC,  cyc,            cycActive, cycActive and S.packEditCyc)
    cell(PK_WEAR, p.wear .. " %", wearActive, wearActive and S.packEditWear)
    cell(PK_ACT,  "Remove",       actActive, false)
  end

  drawButtonBar({ "[+] Add pack", "Done" }, #packs + 1, S.packsCursor)
end

local function handlePacks(e)
  local packs = S.prof.instances

  -- Editing the cycle count of the dived row (written back to stats on save).
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
        if S.statsErr then openAlert("stats.lua unreadable — fix on PC")
        else S.packEditCyc = true end
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
    elseif c == #packs + 1 then              -- [+] Add pack
      if #packs >= 20 then
        openAlert("Max 20 packs")
      else
        packs[#packs + 1] = { id = nil, label = nextLabel(packs), wear = 0, cycles = 0 }
        sortByLabel(packs)                   -- keep #1,#2,#3 order in the table
      end
    else                                      -- [Done]
      S.screen = SCREEN_PROFILE
    end
  elseif isExit(e) then
    S.screen = SCREEN_PROFILE
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function init()
  S.cfg, S.err, S.errDetail = loadConfig()
  S.stats, S.statsErr       = loadStats()
  -- Keep a usable empty table for reads, but remember the error so writes (which
  -- would overwrite the unreadable file) stay blocked and cycle counts show "?".
  if S.statsErr then S.stats = { schemaVersion = SCHEMA_VERSION, instances = {}, archive = {} } end
  S.modelNames = {}
  S.cursor    = 1
  S.dialog    = nil
  if S.err == "missing" then
    S.screen = SCREEN_FIRST_START
  elseif S.err then
    S.screen = SCREEN_CONFIG_ERROR
  else
    S.screen = SCREEN_MAIN
  end
end

-- Handle the event first, then draw — so one frame reflects the result of the
-- input (no one-frame lag) and a modal dialog renders on top of its screen.
local function handleEvent(event)
  if S.dialog then handleDialog(event); return 0 end
  if S.screen == SCREEN_FIRST_START  then return handleFirstStart(event)  end
  if S.screen == SCREEN_CONFIG_ERROR then return handleConfigError(event) end
  if S.screen == SCREEN_BATTERIES    then return handleBatteries(event)   end
  if S.screen == SCREEN_PROFILE      then return handleProfile(event)     end
  if S.screen == SCREEN_PACKS        then return handlePacks(event)       end
  if S.screen == SCREEN_MODELS       then return handleModels(event)      end
  if S.screen == SCREEN_MODEL        then return handleModel(event)       end
  if S.screen == SCREEN_ASSIGN       then return handleAssign(event)      end
  if S.screen == SCREEN_DEFAULTS     then return handleDefaults(event)    end
  if S.screen == SCREEN_ABOUT        then return handleAbout(event)       end
  return handleMain(event)
end

local function draw()
  lcd.clear()
  if S.screen == SCREEN_FIRST_START then
    drawFirstStart()
  elseif S.screen == SCREEN_CONFIG_ERROR then
    drawConfigError()
  elseif S.screen == SCREEN_BATTERIES then
    drawBatteries()
  elseif S.screen == SCREEN_PROFILE then
    drawProfile()
  elseif S.screen == SCREEN_PACKS then
    drawPacks()
  elseif S.screen == SCREEN_MODELS then
    drawModels()
  elseif S.screen == SCREEN_MODEL then
    drawModel()
  elseif S.screen == SCREEN_ASSIGN then
    drawAssign()
  elseif S.screen == SCREEN_DEFAULTS then
    drawDefaults()
  elseif S.screen == SCREEN_ABOUT then
    drawAbout()
  else
    drawMain()
  end
  if S.dialog then drawDialog() end   -- overlay on top of the current screen
end

local function run(event, touchState)
  local ret = handleEvent(event) or 0
  draw()
  return ret
end

return { init = init, run = run }
