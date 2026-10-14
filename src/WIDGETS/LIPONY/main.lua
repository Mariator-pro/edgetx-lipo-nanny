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

-- Non-display logic (config I/O, telemetry, state machine, battery detection,
-- warnings, metrics) lives in core.lua. If it fails to load, `core` stays nil
-- and drawTile() shows a "core.lua missing" tile instead of crashing.
local core
do
  local chunk = loadScript("/SCRIPTS/LIPONY/core.lua")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok then core = mod end
  end
end

-- ---------------------------------------------------------------------------
-- Constants, palette + fonts
-- ---------------------------------------------------------------------------

-- Widget-only lifecycle constants (logic timings live in core.lua).
local TICK_INTERVAL = 10   -- 0.1 s data-processing cadence
local ERROR_LIMIT   = 5    -- consecutive tick failures before the widget gives up

-- Confirm hold of the selection popup (the gestures live in the core).
local CONFIRM_HOLD = core and core.CONFIRM_HOLD or 100
-- Opacity of the confirm-hold fill (0 = opaque, 15 = invisible): semi-transparent
-- so the solid-brand cursor text stays readable on top.
local CONFIRM_FILL_OPACITY = 8

-- Pixel constants are relative to a 480 px reference width; S scales them up on
-- wider screens (S = LCD_W/480).
local REF_W = 480
local S     = (LCD_W or REF_W) / REF_W
local function sx(v) return math.floor(v * S + 0.5) end

-- Slack on the FULL/MEDIUM height thresholds so a zone a pixel or two above a tier
-- boundary doesn't flip tier on a minor font-metric change.
local TIER_TOL = sx(4)

-- Two palettes, picked per frame by the "Theme" option (see refresh()). DARK paints
-- a near-black panel; LIGHT stays transparent so the radio theme shows through.
-- `accent` is the "good"-state green (%/bar/voltage); warn/crit colours are
-- theme-independent. Brand/heading colour is separate (BRAND, below) so the Accent
-- option never touches these state colours.
local DARK = {
  panel   = lcd.RGB( 18,  20,  18),   -- near-black background
  accent  = lcd.RGB(124, 210,  48),   -- lime green (% / V / bar "ok" state)
  fg      = lcd.RGB(235, 235, 235),   -- primary readouts
  muted   = lcd.RGB(150, 150, 150),   -- captions / secondary lines
  track   = lcd.RGB( 55,  58,  55),   -- bar empty track
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
-- Escalation colours, theme-independent (warn = yellow, crit = red).
local WARN_COL = lcd.RGB(255, 180,   0)
local CRIT_COL = lcd.RGB(220,  40,  40)
-- Active palette; reassigned each frame in refresh() from ctx.cfg.Theme.
local COLORS = DARK

-- Brand/heading colour, resolved once per frame in refresh() from the Accent
-- option. Kept apart from COLORS.accent so the option can't bleed into the
-- bar/%/voltage state colours.
local BRAND = DARK.accent

-- Resolves the brand colour from the Accent option: "Theme" uses the active EdgeTX
-- focus colour, "Custom" the AccentColor picker (lcd.getColor normalises a theme
-- index to real RGB). Falls back to the palette accent (Default) if unavailable.
local function brandColor(opt, customCol)
  if opt == 2 and lcd.getColor then
    local c = lcd.getColor(COLOR_THEME_FOCUS)
    if c then return c end
  elseif opt == 3 and customCol then
    local c = lcd.getColor and lcd.getColor(customCol) or customCol
    if c then return c end
  end
  return COLORS.accent
end

-- Mascot-eye colours (theme-independent).
local EYE_WHITE = lcd.RGB(245, 245, 245)
local EYE_RIM   = lcd.RGB( 20,  20,  20)

-- Font flags from largest to smallest (0 = default font). Used by pickFont() to
-- scale text to the zone.
local FONT_STEPS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

-- Text-metric caches: fonts never change at runtime, so measurements are
-- session-constant. Height depends only on the font, width on font + text.
local FONT_H, TEXT_W = {}, {}
local function fontH(flags)
  flags = flags or 0
  local h = FONT_H[flags]
  if not h then
    h = select(2, lcd.sizeText("0", flags))
    FONT_H[flags] = h
  end
  return h
end
-- Width cache is capped: every new live value (distance, voltage ...) adds an
-- entry, so it starts over once TEXT_W_MAX entries are stored.
local TEXT_W_MAX = 200
local textWCount = 0
local function textW(text, flags)
  flags = flags or 0
  local byFlag = TEXT_W[flags]
  if not byFlag then byFlag = {}; TEXT_W[flags] = byFlag end
  local w = byFlag[text]
  if not w then
    if textWCount >= TEXT_W_MAX then
      TEXT_W, textWCount = {}, 0
      byFlag = {}; TEXT_W[flags] = byFlag
    end
    w = lcd.sizeText(text, flags); byFlag[text] = w
    textWCount = textWCount + 1
  end
  return w
end

-- Largest font flag whose rendered text fits within maxW×maxH, plus its measured
-- width/height. Falls back to the smallest font if nothing fits.
-- maxFont (optional): the largest font to consider.
local function pickFont(text, maxW, maxH, maxFont)
  local capped = not maxFont
  for _, flag in ipairs(FONT_STEPS) do
    if flag == maxFont then capped = true end
    local tw, th = textW(text, flag), fontH(flag)
    if capped and tw <= maxW and th <= maxH then return flag, tw, th end
  end
  local tw, th = textW(text, SMLSIZE), fontH(SMLSIZE)
  return SMLSIZE, tw, th
end

-- ---------------------------------------------------------------------------
-- Drawing + format helpers
-- ---------------------------------------------------------------------------

-- Draws coloured text. A raw lcd.RGB() value must not be added into the drawText
-- flags (its bits collide with size/attribute flags); colour goes through the
-- CUSTOM_COLOR slot instead, so `flags` only carries size/align/BOLD.
local function dtext(x, y, text, color, flags)
  lcd.setColor(CUSTOM_COLOR, color)
  lcd.drawText(x, y, text, CUSTOM_COLOR + (flags or 0))
end


-- Colour of a core level (0 ok, 1 warning, 2 critical): the big value, its bar
-- and the status green, yellow or red; small values text colour, yellow or red.
-- Levels come from the core, the widget never compares thresholds itself.
local function levelColor(level)
  if level == nil then return COLORS.fg end   -- no level: neutral
  if level == 2 then return CRIT_COL end
  if level == 1 then return WARN_COL end
  return COLORS.accent
end
-- A colour level from the core, guarded: a failing level function leaves only
-- that value in its neutral colour instead of breaking the whole tile.
local function lvl(f, ...)
  local ok, v = pcall(f, ...)
  if ok then return v end
end
local function smallColor(level)
  if level == 2 then return CRIT_COL end
  if level == 1 then return WARN_COL end
  return COLORS.fg
end

-- Label "name #N" (or "#1+2" for parallel). Instances are { pos = N, id = … }
-- pairs; the displayed number is the position, not the internal pack id.
local function formatBatteryLabel(name, instances)
  if not name then return "--" end
  if type(instances) ~= "table" or #instances == 0 then return name end
  if #instances == 1 then
    return name .. " #" .. tostring(instances[1].pos)
  end
  -- Parallel: "#1+2"
  return name .. " #" .. tostring(instances[1].pos) .. "+" .. tostring(instances[#instances].pos)
end

-- ---------------------------------------------------------------------------
-- Live tile (PRE and FLIGHT): readouts and threshold bar, scaling down through
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

-- Draws a number with its unit appended in a smaller font, bottom-aligned to the
-- number. Returns the total drawn width.
local function drawValueUnit(x, y, value, unit, color, valueFlag, unitFlag)
  dtext(x, y, value, color, valueFlag)
  local vw, vh = textW(value, valueFlag), fontH(valueFlag)
  if unit and unit ~= "" then
    local gap     = sx(3)
    local uw, uh  = textW(unit, unitFlag), fontH(unitFlag)
    dtext(x + vw + gap, y + (vh - uh), unit, color, unitFlag)
    return vw + gap + uw
  end
  return vw
end

-- "● Name #N" header: accent dot plus battery label, drawn at caption size
-- (SMLSIZE) so it's no larger than e.g. "REMAINING".
local function drawHeaderLabel(x, y, label)
  local th = fontH(SMLSIZE)   -- text height, to centre the dot
  local dot   = sx(5)
  lcd.drawFilledRectangle(x, y + math.floor((th - dot) / 2), dot, dot, BRAND)
  dtext(x + dot + sx(3), y, label, BRAND, SMLSIZE)
end

-- Horizontal threshold bar: track, coloured fill, yellow/red tick marks at warn/crit.
local function drawThresholdBar(x, y, w, h, pct, warn, crit)
  lcd.drawFilledRectangle(x, y, w, h, COLORS.track)
  local p     = math.max(0, math.min(100, pct or 0))
  local fillW = math.floor(w * p / 100)
  if fillW > 0 then
    lcd.drawFilledRectangle(x, y, fillW, h, levelColor(lvl(core.restLevel, p, warn, crit)))
  end
  local tickW = math.max(sx(2), 2)
  local function tick(thr, col)
    local tx = x + math.floor(w * thr / 100) - math.floor(tickW / 2)
    lcd.drawFilledRectangle(tx, y - sx(1), tickW, h + sx(2), col)
  end
  tick(warn, WARN_COL)
  tick(crit, CRIT_COL)
end

-- Pulsing red dot, top-right (fades in and out every 2 s); the caller draws it only
-- while telemetry is arriving. drawFilledCircle has no opacity, so the colour is
-- blended by hand between the background and red (light theme: white, the real
-- background there depends on the radio theme).
local HEARTBEAT_PERIOD = 200   -- getTime ticks
local HEARTBEAT_RED    = { 220, 40, 40 }
local HEARTBEAT_BG     = { dark = { 18, 20, 18 }, light = { 255, 255, 255 } }
local function drawHeartbeat(ctx)
  local t  = 0.5 - 0.5 * math.cos(2 * math.pi * (getTime() % HEARTBEAT_PERIOD) / HEARTBEAT_PERIOD)
  local bg = COLORS.transparent and HEARTBEAT_BG.light or HEARTBEAT_BG.dark
  local function mix(i) return math.floor(bg[i] + (HEARTBEAT_RED[i] - bg[i]) * t + 0.5) end
  local r = sx(3)
  lcd.drawFilledCircle(ctx.zone.w - sx(4) - r, sx(4) + r, r, lcd.RGB(mix(1), mix(2), mix(3)))
end

-- Colour for the voltage readouts (small values): text colour, yellow or red
-- from the chemistry's per-cell voltage thresholds.
local function voltageColor(ctx)
  return smallColor(lvl(core.voltageLevel, ctx))
end

-- Capacity and current, "--" when missing; large values in a shorter form so
-- they keep their column width: 10000 mAh and up in Ah, 100 A and up without
-- the decimal.
local function fmtMah(v)
  if not v then return "--" end
  local mah = math.floor(v + 0.5)
  return (mah >= 10000) and string.format("%.1f Ah", mah / 1000) or string.format("%d mAh", mah)
end
local function fmtAmps(v)
  if not v then return "--" end
  return (v >= 99.95) and string.format("%d A", math.floor(v + 0.5)) or string.format("%.1f A", v)
end

-- Builds the display strings/colours once for the live tile metrics.
local function connectedMetrics(ctx)
  local restPct    = core.calculateRestPct(ctx)
  local warn, crit = core.getThresholds(ctx)
  local effective  = core.effectiveCapacityMah(ctx)
  -- `used` includes the pre-flight start offset (drives remaining %/mAh)
  local used       = (ctx.capacity and ctx.startOffsetMah) and (ctx.capacity + ctx.startOffsetMah) or nil
  local remaining  = (effective and used) and math.max(0, effective - used) or nil
  local profile    = ctx.selectedProfile and ctx.selectedProfile.name or nil
  return {
    restPct  = restPct,
    warn     = warn,
    crit     = crit,
    pctColor = restPct and levelColor(lvl(core.restLevel, restPct, warn, crit)) or COLORS.fg,   -- missing: neutral
    vColor   = voltageColor(ctx),
    leftColor = smallColor(lvl(core.restLevel, restPct, warn, crit)),
    label    = formatBatteryLabel(profile, ctx.selectedInstances),
    pctText  = restPct and string.format("%d", math.floor(restPct + 0.5)) or "--",
    packText = ctx.voltage and string.format("%.1f V", ctx.voltage) or "--",
    cellText = (ctx.voltage and ctx.cells and ctx.cells > 0)
               and string.format("%.2f V", ctx.voltage / ctx.cells) or "--",
    leftText = fmtMah(remaining),
    currText = fmtAmps(ctx.current),
    timeLeft = ctx.timeLeftStr or core.formatTimeLeft(ctx),  -- 2 s-throttled snapshot
  }
end

-- Time beside the %, chosen in the settings tool: Timer 1 (none while it is off)
-- or the remaining flight time. Returns label, value and the value's colour.
local function flightTime(ctx, m)
  if ctx.config and ctx.config.flightTime == "timeleft" then return "TIME LEFT ", m.timeLeft end
  local t = model.getTimer and model.getTimer(0)
  if not (t and t.mode ~= 0) then return nil end
  local sec  = t.value
  local sign = (sec < 0) and "-" or ""
  local col  = smallColor(lvl(core.timerLevel, sec))   -- red once a countdown runs below zero
  sec = math.abs(sec)
  return "TIMER ", string.format("%s%02d:%02d", sign, math.floor(sec / 60), sec % 60), col
end

-- Muted label followed by its value (text colour unless `col` is given).
local function drawKV(x, y, label, value, col)
  dtext(x, y, label, COLORS.muted, SMLSIZE)
  dtext(x + textW(label, SMLSIZE), y, value, col or COLORS.fg, SMLSIZE)
end

-- Vertical-center offset for a SMLSIZE row.
local function vcenter(ry, rh)
  return ry + math.floor((rh - fontH(SMLSIZE)) / 2)
end

-- Info grid (2 rows x 2 cols). Column 2 starts at the middle, or right of the
-- widest column-1 content on a narrow zone.
local GRID_A, GRID_B, GRID_B2 = "LEFT 0000 mAh", "CURRENT 00.0 A", "PER CELL 0.00 V"
local function gridW()
  return textW(GRID_A, SMLSIZE) + sx(4) + math.max(textW(GRID_B, SMLSIZE), textW(GRID_B2, SMLSIZE))
end
local function gridCol2(x0, W)
  return x0 + math.max(math.floor(W / 2), textW(GRID_A, SMLSIZE) + sx(4))
end
local function drawInfoRow1(x0, W, y, m)
  drawKV(x0, y, "PACK ", m.packText, m.vColor)
  drawKV(gridCol2(x0, W), y, "PER CELL ", m.cellText, m.vColor)
end
local function drawInfoGrid(x0, W, r1y, r2y, m)
  drawInfoRow1(x0, W, r1y, m)
  drawKV(x0, r2y, "LEFT ", m.leftText, m.leftColor)
  drawKV(gridCol2(x0, W), r2y, "CURRENT ", m.currText)
end

-- Caption on the percent baseline: the flight time right-aligned (priority),
-- the label after the percent degrading REMAINING -> REMAIN -> dropped as the
-- row tightens, so it never collides with the time.
local function drawPctCaption(x0, W, pctBottom, labelX, m)
  local capY = pctBottom - fontH(SMLSIZE)
  local tX   = x0 + W
  if m.timeLabel then
    tX = tX - (textW(m.timeLabel, SMLSIZE) + textW(m.timeValue, SMLSIZE))
    drawKV(tX, capY, m.timeLabel, m.timeValue, m.timeColor)
  end
  local avail = tX - sx(4) - labelX
  local lbl   = "REMAINING"
  if textW(lbl, SMLSIZE) > avail then lbl = "REMAIN" end
  if textW(lbl, SMLSIZE) <= avail then dtext(labelX, capY, lbl, COLORS.muted, SMLSIZE) end
end

-- Percent row for MEDIUM/SMALL: "value %" one size, caption on its baseline.
-- Returns the y just below the percent (the top of the bar slot).
local function drawPctRow(x0, W, top, maxH, m)
  local pctTxt  = m.pctText .. " %"
  local numFlag = pickFont("100 %", W * 0.5, maxH, MIDSIZE)
  dtext(x0, top, pctTxt, m.pctColor, numFlag)
  local pctBottom = top + fontH(numFlag)
  drawPctCaption(x0, W, pctBottom, x0 + textW(pctTxt, numFlag) + sx(6), m)
  return pctBottom
end

local function drawBar(x, y, w, h, m)
  drawThresholdBar(x, y, w, h, m.restPct, m.warn, m.crit)
end

-- FULL tier geometry for a zone of inner height H: percent block below the
-- header, the 2 info rows below it (each at least one line tall so they never
-- crowd up into the bar) and the bar height. Bar takes ~42% of the block, capped
-- so the band above always fits a MIDSIZE number. The preflight page reuses the
-- bar height so both pages show the same bar.
local function fullGeometry(H)
  local smlH     = fontH(SMLSIZE)
  local rest     = H - smlH - sx(1)
  local hInfoRow = math.max(math.floor(rest * 0.20), smlH)
  local hPct     = rest - 2 * hInfoRow - sx(3)
  local barH     = math.max(sx(10), math.min(math.floor(hPct * 0.42), hPct - fontH(MIDSIZE) - sx(3)))
  return hPct, hInfoRow, barH
end

-- FULL tier: header, percent block (big % + threshold bar) and the 2x2 info grid.
local function drawConnectedFull(W, H, x0, y0, m)
  drawHeaderLabel(x0, y0, m.label)
  local top      = y0 + fontH(SMLSIZE) + sx(1)
  local infoGap  = sx(3)
  local hPct, hInfoRow, barH = fullGeometry(H)
  local barY  = top + hPct - barH
  local bandH = barY - sx(1) - top
  -- Big percent anchored to the top, sized from "100" so "1" isn't bigger.
  local numFlag = pickFont("100", W * 0.5, bandH, MIDSIZE)
  local pctW    = drawValueUnit(x0, top, m.pctText, "%", m.pctColor, numFlag, smallerFont(numFlag))
  drawPctCaption(x0, W, top + fontH(numFlag), x0 + pctW + sx(6), m)
  drawBar(x0, barY, W, barH, m)
  local gy = top + hPct + infoGap
  drawInfoGrid(x0, W, vcenter(gy, hInfoRow), vcenter(gy + hInfoRow, hInfoRow), m)
end

-- MEDIUM tier: header and 4 rows evenly spread (%, bar, 2 info rows); on a short
-- zone the pitch is floored so the last row sits at the bottom pad.
local function drawConnectedMedium(W, H, x0, y0, m)
  drawHeaderLabel(x0, y0, m.label)
  local smlH    = fontH(SMLSIZE)
  local span    = H - smlH
  local minSpan = 4 * (smlH - sx(5))   -- the pitch connectedFitsMedium allows
  if span < minSpan then span = minSpan end
  local function rowY(i) return y0 + math.floor(i * span / 4 + 0.5) end
  local top, row1Y = rowY(1), rowY(3)
  drawInfoGrid(x0, W, row1Y, rowY(4), m)
  local barTop = drawPctRow(x0, W, top, math.floor((row1Y - sx(2) - top) * 0.5), m)
  drawBar(x0, barTop, W, math.max(sx(8), (row1Y - sx(1)) - barTop), m)
end

-- SMALL tier, by the number of full-height rows that fit:
--   >= 3 rows : header + % row + bar (+ PACK/CELL row when a 4th fits)
--   2 rows    : header + the % row
--   <= 1 row  : just a large %
-- The % is coloured by the thresholds, so the colour still carries the state.
local function drawConnectedSmall(W, H, x0, y0, m)
  local smlH  = fontH(SMLSIZE)
  local gap   = sx(1)
  local nRows = math.floor((H + gap) / (smlH + gap))
  if nRows <= 2 then
    if nRows <= 1 then
      local txt = m.pctText .. " %"
      local f   = pickFont(txt, W, H)
      dtext(x0, y0 + math.floor((H - fontH(f)) / 2), txt, m.pctColor, f)
    else
      drawHeaderLabel(x0, y0, m.label)
      local restTop = y0 + smlH + gap
      drawPctRow(x0, W, restTop, (y0 + H) - restTop, m)
    end
    return
  end
  local nInfo   = (nRows >= 4) and 1 or 0
  local divisor = 2 + nInfo
  local span    = H - smlH
  local function rowY(i) return y0 + math.floor(i * span / divisor + 0.5) end
  drawHeaderLabel(x0, y0, m.label)
  local top   = rowY(1)
  local infoY = (nInfo >= 1) and rowY(3) or nil
  if infoY then drawInfoRow1(x0, W, infoY, m) end
  local barTop = drawPctRow(x0, W, top, math.floor(((infoY or (y0 + H)) - sx(2) - top) * 0.5), m)
  local barBot = (infoY and (infoY - sx(1))) or (y0 + H)
  drawBar(x0, barTop, W, math.max(sx(8), barBot - barTop), m)
end

-- Tier checks in absolute pixels (fonts don't scale with S, only positions do), on
-- the zone without its pad. FULL: header + gap, percent band + min bar, info gap +
-- two info rows. MEDIUM: header + four rows at a compressed pitch. Both need the
-- info grid's width.
local function connectedFitsFull(W, H)
  local smlH  = fontH(SMLSIZE)
  local needH = smlH + sx(1) + fontH(MIDSIZE) + sx(1) + sx(12) + sx(3) + 2 * smlH
  return W >= gridW() - TIER_TOL and H >= needH - TIER_TOL
end
local function connectedFitsMedium(W, H)
  local smlH = fontH(SMLSIZE)
  return W >= gridW() - TIER_TOL and H >= smlH + 4 * (smlH - sx(5)) - TIER_TOL
end

-- Live tile in flight: FULL, MEDIUM or SMALL by what fits the zone.
local function drawConnectedTile(ctx)
  local pad    = sx(4)
  local x0, y0 = pad, pad
  local W, H   = ctx.zone.w - 2 * pad, ctx.zone.h - 2 * pad
  local m      = connectedMetrics(ctx)
  m.timeLabel, m.timeValue, m.timeColor = flightTime(ctx, m)
  if connectedFitsFull(W, H) then
    drawConnectedFull(W, H, x0, y0, m)
  elseif connectedFitsMedium(W, H) then
    drawConnectedMedium(W, H, x0, y0, m)
  else
    drawConnectedSmall(W, H, x0, y0, m)
  end
end

-- ---------------------------------------------------------------------------
-- Message / text layout
-- ---------------------------------------------------------------------------

-- Message fonts, largest first: the default (STD) font when the lines fit, else
-- SMLSIZE. Two discrete steps only, so the per-line height stays predictable.
local MSG_FONT_STEPS = { 0, SMLSIZE }

-- Fixed line height for a message font: its text height plus a small gap.
local function msgLineH(flag)
  local th = fontH(flag)
  return th + sx(2)
end

-- Largest MSG_FONT_STEPS flag whose `lines` fit `availW` wide AND `availH` tall;
-- falls back to SMLSIZE. Returns the flag and its line height.
local function pickMsgFont(lines, availW, availH)
  for _, flag in ipairs(MSG_FONT_STEPS) do
    local lineH = msgLineH(flag)
    local fits  = #lines * lineH <= availH
    for _, t in ipairs(lines) do
      if textW(t, flag) > availW then fits = false break end
    end
    if fits then return flag, lineH end
  end
  return SMLSIZE, msgLineH(SMLSIZE)
end

-- Renders centred lines below `topY` (so a reserved header band isn't overlapped),
-- clamped to start at topY on zones too short to centre. Used by the error/info tiles.
local function drawCenteredLines(ctx, lines, topY, flag, lineH)
  local n = #lines
  if n == 0 then return end
  local w, h   = ctx.zone.w, ctx.zone.h
  local cx     = math.floor(w / 2)
  local startY = topY + math.floor(((h - topY) - n * lineH) / 2)
  if startY < topY then startY = topY end
  for i = 1, n do
    dtext(cx, startY + (i - 1) * lineH, lines[i], COLORS.fg, flag + CENTER)
  end
end

-- ---------------------------------------------------------------------------
-- WAITING tile
-- ---------------------------------------------------------------------------

-- Status line with 0-3 trailing dots. Centred as if all three dots were present,
-- with the dots drawn left-fixed after the base text so it never jitters.
local WAIT_BASE     = "No Battery connected"
local SETTLE_BASE   = "Calculating"
local USB_BASE      = "USB connected"
local DOT_INTERVAL  = 50   -- getTime units (1/100 s) per dot → ~2 s full cycle
local function drawWaitingStatus(cx, y, base)
  local n      = math.floor(getTime() / DOT_INTERVAL) % 4   -- 0..3
  local baseW  = textW(base, SMLSIZE)
  local fullW  = textW(base .. "...", SMLSIZE)
  local startX = cx - math.floor(fullW / 2)
  dtext(startX, y, base, COLORS.muted, SMLSIZE)
  if n > 0 then dtext(startX + baseW, y, string.rep(".", n), COLORS.muted, SMLSIZE) end
end

-- WAITING tile: "LIPO-NANNY" brand splash plus a status line, shown for every
-- idle/waiting state. Degrades on short zones to a single centered status line.
-- Title font sized to this fixed-width anchor (not the shorter real title) so
-- it stays consistent regardless of the actual status text length.
local TITLE_SIZE_REF = string.rep("M", 8)

local function drawWaitingTile(ctx)
  local w, h   = ctx.zone.w, ctx.zone.h
  local pad    = sx(4)
  local title  = "LIPO-NANNY"
  local cx     = math.floor(w / 2)
  -- The isOnline guard stops a dropped link from lingering on "Calculating"
  -- through the ENDED grace window.
  local base
  if core.isUsbConnected(ctx) then
    base = USB_BASE
  elseif core.isActive(ctx) and core.isOnline(ctx) then
    base = SETTLE_BASE
  else
    base = WAIT_BASE
  end

  -- Fit the anchor width, then render one font step smaller.
  local titleFlag = smallerFont(pickFont(TITLE_SIZE_REF, w * 0.95, math.floor(h * 0.5)))
  local titleH = fontH(titleFlag)
  local subH = fontH(SMLSIZE)
  local gap     = sx(4)
  local avail   = h - 2 * pad

  -- Status plus a reserved empty third line (sx(2) below it) for a 3-line layout.
  local lineGap = sx(2)
  local statusH = subH + lineGap + subH
  -- Drop order when the zone shrinks: title first, then the empty line.
  if avail >= titleH + gap + statusH then
    local top = math.floor((h - (titleH + gap + statusH)) / 2)
    dtext(cx, top, title, BRAND, titleFlag + CENTER)
    drawWaitingStatus(cx, top + titleH + gap, base)
  elseif avail >= statusH then
    drawWaitingStatus(cx, math.floor((h - statusH) / 2), base)
  else
    drawWaitingStatus(cx, math.floor((h - subH) / 2), base)
  end
end

-- ---------------------------------------------------------------------------
-- ENDED tile
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Preflight and end pages (flight phases PRE and ENDED), header and margins as
-- on the live tile.
-- ---------------------------------------------------------------------------

-- Seconds left on a page timer that started at `since` (the core's ms clock,
-- getTime() * 10) and runs `total` ms.
local function secsLeft(since, total)
  return math.max(0, math.ceil((total - (getTime() * 10 - since)) / 1000))
end

-- Countdown at the bottom right: the seconds left of a bar that runs empty.
local function drawCountdown(x0, W, y, secs, total)
  local smlH = fontH(SMLSIZE)
  local barH = math.max(3, sx(6))
  local barW = math.max(sx(30), math.floor(W * 0.26))
  local bx   = x0 + W - barW
  local by   = y + math.floor((smlH - barH) / 2)
  lcd.drawFilledRectangle(bx, by, barW, barH, COLORS.track)
  local fw = math.floor(barW * math.max(0, math.min(1, secs / total)))
  if fw > 0 then lcd.drawFilledRectangle(bx, by, fw, barH, COLORS.muted) end
  local txt = string.format("%d s", secs)
  dtext(bx - sx(6) - textW(txt, SMLSIZE), y, txt, COLORS.muted, SMLSIZE)
end

-- Status line: dot plus text in the level colour (PACK READY / BATTERY LOW).
local function statusLineW(st)
  return 2 * math.max(2, sx(4)) + sx(4) + textW(st.text, SMLSIZE)
end
local function drawStatusLine(x, y, st)
  local smlH = fontH(SMLSIZE)
  local r    = math.max(2, sx(4))
  local col  = levelColor(st.level)
  lcd.drawFilledCircle(x + r, y + math.floor(smlH / 2), r, col)
  dtext(x + 2 * r + sx(4), y, st.text, col, SMLSIZE)
  return statusLineW(st)
end

-- Rows evenly spread below the header (header = row 0, n rows, the last at the
-- bottom pad), as on the MEDIUM live tile; the pitch never drops below a
-- compressed line.
local function rowSpread(h, pad, n)
  local smlH = fontH(SMLSIZE)
  local span = h - 2 * pad - smlH
  if span < n * (smlH - sx(4)) then span = n * (smlH - sx(4)) end
  return function(i) return pad + math.floor(i * span / n + 0.5) end
end

-- Preflight page in the live tile's rows: per-cell voltage (check colour) with
-- PER CELL and PACK where the live tile has the %, the threshold bar, then
-- REMAINING / LEFT and the battery status with the countdown to the flight page
-- (seconds only) where the live tile has its info grid. Small zones drop
-- REMAINING / LEFT first, then the bar.
local function drawPreTile(ctx)
  local pad    = sx(4)
  local x0, y0 = pad, pad
  local W, H   = ctx.zone.w - 2 * pad, ctx.zone.h - 2 * pad
  local smlH   = fontH(SMLSIZE)
  local m      = connectedMetrics(ctx)
  local st     = core.preflight(m.restPct, m.warn, m.crit)
  local vLevel = lvl(core.voltageLevel, ctx)   -- PER CELL and PACK as on the live tile
  local col    = vLevel and levelColor(vLevel) or COLORS.fg
  local hasV   = ctx.voltage and ctx.cells and ctx.cells > 0
  local cell   = hasV and string.format("%.2f", ctx.voltage / ctx.cells) or "-.--"
  local total  = ctx.voltage and string.format("%.1f V", ctx.voltage) or "--.- V"
  local secs   = ctx.readySince and secsLeft(ctx.readySince, core.PRE_HOLD_T)
  local function statusRow(y)
    drawStatusLine(x0, y, st)
    if secs then drawCountdown(x0, W, y, secs, core.PRE_HOLD_T / 1000) end
  end
  local function infoRow(y)   -- LEFT right-aligned like TX on Link Sentinel
    local lx  = x0 + W - textW("LEFT " .. m.leftText, SMLSIZE)
    local pct = m.pctText .. " %"
    local lbl = textW("REMAINING " .. pct, SMLSIZE) <= lx - sx(6) - x0 and "REMAINING " or "REMAIN "
    drawKV(x0, y, lbl, pct, m.leftColor)
    drawKV(lx, y, "LEFT ", m.leftText, m.leftColor)
  end
  -- PER CELL after the value, PACK and the pack voltage right, on the value's baseline
  local function captions(valRight, bottom)   -- pack voltage in caption size, like MODE on Link Sentinel
    local totX = x0 + W - textW(total, SMLSIZE)
    dtext(totX, bottom - smlH, total, smallColor(vLevel), SMLSIZE)
    local capX = totX - textW("PACK ", SMLSIZE)
    dtext(capX, bottom - smlH, "PACK ", COLORS.muted, SMLSIZE)
    local pcX = valRight + sx(6)
    if pcX + textW("PER CELL", SMLSIZE) <= capX - sx(4) then
      dtext(pcX, bottom - smlH, "PER CELL", COLORS.muted, SMLSIZE)
    end
  end
  -- value row for MEDIUM/SMALL ("0.00 V" one size); returns the y below it.
  -- withStatus: the status right-aligned instead of the pack voltage (no row of its own).
  local function valueRow(top, maxH, withStatus)
    local txt = cell .. " V"
    local f   = pickFont("0.00 V", W * 0.5, maxH, MIDSIZE)
    dtext(x0, top, txt, col, f)
    local bottom = top + fontH(f)
    if withStatus then
      local sx0 = x0 + W - statusLineW(st)
      drawStatusLine(sx0, bottom - smlH, st)
      local pcX = x0 + textW(txt, f) + sx(6)
      if pcX + textW("PER CELL", SMLSIZE) <= sx0 - sx(6) then
        dtext(pcX, bottom - smlH, "PER CELL", COLORS.muted, SMLSIZE)
      end
    else
      captions(x0 + textW(txt, f), bottom)
    end
    return bottom
  end

  if connectedFitsFull(W, H) then   -- as drawConnectedFull
    drawHeaderLabel(x0, y0, m.label)
    local top   = y0 + smlH + sx(1)
    local hPct, hInfoRow, barH = fullGeometry(H)
    local barY  = top + hPct - barH
    local f     = pickFont("0.00", W * 0.5, barY - sx(1) - top, MIDSIZE)
    local vw    = drawValueUnit(x0, top, cell, "V", col, f, smallerFont(f))
    captions(x0 + vw, top + fontH(f))
    drawBar(x0, barY, W, barH, m)
    local gy = top + hPct + sx(3)
    infoRow(vcenter(gy, hInfoRow))
    statusRow(vcenter(gy + hInfoRow, hInfoRow))
  elseif connectedFitsMedium(W, H) then   -- as drawConnectedMedium
    drawHeaderLabel(x0, y0, m.label)
    local span    = H - smlH
    local minSpan = 4 * (smlH - sx(5))
    if span < minSpan then span = minSpan end
    local function rowY(i) return y0 + math.floor(i * span / 4 + 0.5) end
    local top, row1Y = rowY(1), rowY(3)
    infoRow(row1Y)
    statusRow(rowY(4))
    local barTop = valueRow(top, math.floor((row1Y - sx(2) - top) * 0.5))
    drawBar(x0, barTop, W, math.max(sx(8), (row1Y - sx(1)) - barTop), m)
  else   -- as drawConnectedSmall: header, value, bar and status as far as they fit
    local gap   = sx(1)
    local nRows = math.floor((H + gap) / (smlH + gap))
    if nRows <= 1 then
      local txt = cell .. " V"
      local f   = pickFont(txt, W, H)
      dtext(x0, y0 + math.floor((H - fontH(f)) / 2), txt, col, f)
      return
    end
    drawHeaderLabel(x0, y0, m.label)
    if nRows == 2 then valueRow(y0 + smlH + gap, (y0 + H) - (y0 + smlH + gap), true); return end
    local divisor = nRows >= 4 and 3 or 2
    local function rowY(i) return y0 + math.floor(i * (H - smlH) / divisor + 0.5) end
    local stY    = rowY(divisor)
    statusRow(stY)
    local barTop = valueRow(rowY(1), math.floor((stY - sx(2) - rowY(1)) * 0.5))
    if divisor == 3 then drawBar(x0, barTop, W, math.max(sx(8), (stY - sx(1)) - barTop), m) end
  end
end

-- Muted label left, value right-aligned at the row's end; `pre` (optional) is
-- drawn in the text colour right before the value (two-colour values).
-- label: text, or { long, short } (the short one when the long one does not fit
-- beside the value); a label that does not fit at all is left out, the value stays.
local function drawLR(x, w, y, label, value, col, pre)
  local vx   = x + w - textW(value, SMLSIZE)
  local room = vx - (pre and textW(pre, SMLSIZE) or 0) - sx(6) - x
  if type(label) == "table" then
    label = textW(label[1], SMLSIZE) <= room and label[1] or label[2]
  end
  if textW(label, SMLSIZE) <= room then dtext(x, y, label, COLORS.muted, SMLSIZE) end
  dtext(vx, y, value, col or COLORS.fg, SMLSIZE)
  if pre then dtext(vx - textW(pre, SMLSIZE), y, pre, COLORS.fg, SMLSIZE) end
end

-- End page: used mAh, the pack cycles, start and remaining charge in one row,
-- last voltage and highest current of the flight just ended, and the
-- countdown to the wait page. Rows are dropped from the end on short zones.
local function drawEndedTile(ctx)
  local w, h  = ctx.zone.w, ctx.zone.h
  local pad   = sx(4)
  local smlH  = fontH(SMLSIZE)
  local lf    = ctx.lastFlight or {}
  local warn, crit = core.getThresholds(ctx)
  local cap, off   = lf.effectiveCap, lf.startOffsetMah
  local start = (cap and cap > 0 and off) and math.floor(100 - off / cap * 100 + 0.5) or nil
  local left  = (cap and cap > 0 and off and lf.usedMah)
                and math.max(0, math.floor((cap - lf.usedMah - off) / cap * 100 + 0.5)) or nil
  local vpc   = lf.lastVoltagePerCell
  local lastV = vpc and string.format("%.2f V", vpc) or "--"
  local cycles = {}
  for _, inst in ipairs(lf.instances or {}) do cycles[#cycles + 1] = tostring(core.cyclesFor(ctx, inst.id)) end
  local restCol = smallColor(lvl(core.restLevel, left, warn, crit))
  local rows = {
    { { "USED CAPACITY", "USED CAP" }, fmtMah(lf.usedMah), restCol },
    { "PACK CYCLES", (#cycles > 0) and table.concat(cycles, ", ") or "--" },
    { "CHARGE", left and (left .. " %") or "--", restCol,
      (start and (start .. " %") or "--") .. " -> " },
    { { "LAST PER CELL", "LAST CELL" }, lastV, smallColor(lvl(core.lastVoltageLevel, ctx.selectedProfile and ctx.selectedProfile.chemistry, vpc)) },
    { { "MAX CURRENT", "MAX CURR" }, fmtAmps(ctx.maxCurrent) },
  }
  drawHeaderLabel(pad, pad, formatBatteryLabel(lf.profileName, lf.instances))
  local n    = math.floor((h - 2 * pad - smlH) / (smlH - sx(4)))
  if n < 2 then   -- header and the used capacity, no countdown
    drawLR(pad, w - 2 * pad, h - pad - smlH, rows[1][1], rows[1][2], rows[1][3])
    return
  end
  local k    = math.min(#rows, n - 1)
  local rowY = rowSpread(h, pad, k + 1)
  for i = 1, k do drawLR(pad, w - 2 * pad, rowY(i), rows[i][1], rows[i][2], rows[i][3], rows[i][4]) end
  drawCountdown(pad, w - 2 * pad, rowY(k + 1), secsLeft(ctx.endedAt or 0, core.ENDED_HOLD_T),
                core.ENDED_HOLD_T / 1000)
end

-- ---------------------------------------------------------------------------
-- Battery-selection popup
-- ---------------------------------------------------------------------------


-- Popup name marquee: a name too long for its row scrolls by one character per
-- MARQUEE_STEP, pausing MARQUEE_PAUSE steps at the start and the end. Scrolling by
-- whole characters (not pixels) because a widget can't clip text to a row.
local MARQUEE_STEP  = 30   -- 0.3 s (getTime units)
local MARQUEE_PAUSE = 3

-- True for a UTF-8 continuation byte (never the start of a character).
local function isContByte(s, i)
  local b = string.byte(s, i)
  return b ~= nil and b >= 128 and b < 192
end

-- Longest part of `s` from byte `first` on that fits `maxW` in SMLSIZE, never
-- ending inside a multi-byte character. Binary search: ~log2(#s) measurements.
local function fitFrom(s, first, maxW)
  local lo, hi = first - 1, #s   -- sub(first, lo) fits, sub(first, hi + 1) is past the end
  if lcd.sizeText(string.sub(s, first), SMLSIZE) <= maxW then return string.sub(s, first) end
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if lcd.sizeText(string.sub(s, first, mid), SMLSIZE) <= maxW then lo = mid else hi = mid end
  end
  while lo >= first and isContByte(s, lo + 1) do lo = lo - 1 end
  return string.sub(s, first, lo)
end

-- The part of `name` to show at time `t` (getTime units since the row got the cursor).
local function marqueeText(name, maxW, t)
  if lcd.sizeText(name, SMLSIZE) <= maxW then return name end
  local starts = {}
  for i = 1, #name do
    if not isContByte(name, i) then starts[#starts + 1] = i end
  end
  -- Scroll steps: the first start whose tail fits ends the run (binary search).
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if lcd.sizeText(string.sub(name, starts[mid]), SMLSIZE) <= maxW then hi = mid else lo = mid + 1 end
  end
  local steps = lo - 1
  local pos = math.floor(t / MARQUEE_STEP) % (steps + 2 * MARQUEE_PAUSE) - MARQUEE_PAUSE
  if pos < 0 then pos = 0 elseif pos > steps then pos = steps end
  return fitFrom(name, starts[pos + 1], maxW)
end

-- Renders the selection popup inside the widget zone (the traditional widget API
-- cannot draw outside its zone; on a full-screen widget this fills the screen).
local function drawSelectionPopup(ctx)
  local w, h  = ctx.zone.w, ctx.zone.h
  local pad   = sx(2)
  -- No own background: refresh() already painted it; palette colours track the theme.

  local title
  if ctx.parallel then
    title = "SELECT PACK SLOT " .. (ctx.popupSlot or 1)
  else
    title = "SELECT PACK"
  end
  dtext(math.floor(w / 2), pad, title, BRAND, CENTER + BOLD)

  local firstRow = pad + fontH(BOLD) + sx(2)   -- below the bold title
  local smlH  = fontH(SMLSIZE)
  local legendY  = h - pad - smlH          -- bottom line reserved for the SMLSIZE legend

  local list = core.activeSelectionList(ctx)
  if #list == 0 then
    dtext(pad, firstRow, "No profiles", COLORS.fg, SMLSIZE)
    return
  end

  -- Rows in the small font so more entries fit and long names plus the "(Nc)"
  -- cycle count aren't clipped.
  local availW  = w - 2 * pad
  local rowTextH = fontH(SMLSIZE)
  local rowH = rowTextH + sx(3)

  local cursor  = ctx.popupCursor or 1
  -- The marquee starts over whenever another row (or slot) gets the cursor.
  local marqueeKey = (ctx.popupSlot or 1) .. ":" .. cursor
  if ctx.marqueeKey ~= marqueeKey then
    ctx.marqueeKey, ctx.marqueeSince = marqueeKey, getTime()
  end
  -- Drop the legend when keeping it would leave room for only one battery row; that
  -- space then goes to the list instead.
  local showLegend = math.floor((legendY - firstRow) / rowH) >= 2
  local listBottom = showLegend and legendY or (h - pad)
  local maxRows    = math.max(1, math.floor((listBottom - firstRow) / rowH))

  -- Scrolling window: keep the cursor centred so neighbouring entries stay visible,
  -- clamped at both ends so no blank rows appear.
  local half  = math.floor((maxRows - 1) / 2)
  local start = cursor - half
  if start > #list - maxRows + 1 then start = #list - maxRows + 1 end
  if start < 1 then start = 1 end
  local last = math.min(#list, start + maxRows - 1)

  -- Confirm-hold progress (0..1): non-zero only during an active hold
  -- (core.pollSelectionSticks sets/clears ctx.confirmSince on hold/release).
  local confirmProgress = 0
  if ctx.confirmSince then
    confirmProgress = (getTime() - ctx.confirmSince) / CONFIRM_HOLD
    if confirmProgress > 1 then confirmProgress = 1 end
  end

  local y = firstRow
  for i = start, last do
    -- Hold-to-confirm fill: translucent brand-coloured bar grows left→right behind
    -- the cursor row as the aileron is held; the solid cursor text stays readable
    -- thanks to the reduced opacity.
    if i == cursor and confirmProgress > 0 then
      lcd.drawFilledRectangle(pad, y, math.floor(availW * confirmProgress), rowH - sx(1), BRAND, CONFIRM_FILL_OPACITY)
    end
    -- "#N (Xc)" always stays whole; only the name gives way: the cursor row
    -- scrolls it, the others show as much of it as fits.
    local item   = list[i]
    local name   = item.profile.name or "--"
    local suffix = " #" .. tostring(item.pos) .. " (" .. (item.cycles or 0) .. "c)"
    local prefix = (i == cursor) and "> " or "  "
    local nameW  = availW - textW(prefix, SMLSIZE) - textW(suffix, SMLSIZE)
    local shown
    if i == cursor then
      shown = marqueeText(name, nameW, getTime() - ctx.marqueeSince)
    else
      shown = fitFrom(name, 1, nameW)
    end
    -- the number sits fixed at the right edge, so it never jumps with the scrolling name
    local col = (i == cursor) and BRAND or COLORS.fg
    dtext(pad, y, prefix .. shown, col, SMLSIZE)
    dtext(pad + availW - textW(suffix, SMLSIZE), y, suffix, col, SMLSIZE)
    y = y + rowH
  end

  -- Gesture legend. ASCII only — the EdgeTX font has no arrow glyphs. Dropped on very
  -- short zones (see showLegend) so a battery row keeps priority.
  if showLegend then
    dtext(pad, legendY, "ele: up/dn  ail: hold >", COLORS.muted, SMLSIZE)
  end
end

-- ---------------------------------------------------------------------------
-- Brand heading + error / info tiles
-- ---------------------------------------------------------------------------

-- Decorative googly eyes drawn beside the brand heading.
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
    lcd.drawFilledCircle(cx, cy, r, EYE_RIM)
    lcd.drawFilledCircle(cx, cy, r - 1, EYE_WHITE)
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
  local hh, sq = fontH(SMLSIZE), sx(5)   -- accent square + title
  lcd.drawFilledRectangle(pad, pad + math.floor((hh - sq) / 2), sq, sq, BRAND)
  local tx = pad + sq + sx(3)
  dtext(tx, pad, "LIPO-NANNY", BRAND, SMLSIZE)
  drawMascotEyes(tx + textW("LIPO-NANNY", SMLSIZE) + sx(6), pad, sx(20), math.max(hh, sx(14)))
end

-- Height of the brand-heading band (top pad + the taller of text / mascot-eye
-- height), so callers can reserve it before centring text beneath.
local function headerBandH()
  local hh = fontH(SMLSIZE)
  return sx(4) + math.max(hh, sx(14)) + sx(2)
end

-- Trims `lines` to `maxLines`, keeping the first line (the problem) and filling
-- from the end backward (the action hint), so middle context drops first. Order
-- is preserved; always returns at least one line.
local function fitLines(lines, maxLines)
  if #lines <= maxLines then return lines end
  if maxLines <= 1 then return { lines[1] } end
  local keep = { lines[1] }
  for i = #lines - (maxLines - 1) + 1, #lines do keep[#keep + 1] = lines[i] end
  return keep
end

-- Brand heading with centred message lines below it. On a zone too short for both
-- (even at SMLSIZE), the heading is dropped and the message gets the full zone.
-- If even every line doesn't fit, trailing context is dropped (see fitLines).
local function drawHeadedMessage(ctx, lines)
  local w, h   = ctx.zone.w, ctx.zone.h
  local availW = w - 2 * sx(4)
  local hb     = headerBandH()
  if h - hb >= #lines * msgLineH(SMLSIZE) then
    drawBrandHeading(ctx)
    local flag, lineH = pickMsgFont(lines, availW, h - hb)
    drawCenteredLines(ctx, lines, hb, flag, lineH)
  else
    local maxLines    = math.max(1, math.floor(h / msgLineH(SMLSIZE)))
    local shown       = fitLines(lines, maxLines)
    local flag, lineH = pickMsgFont(shown, availW, h)
    drawCenteredLines(ctx, shown, 0, flag, lineH)
  end
end

-- Generic 2-line error tile.
local function drawErrorTile(ctx, line1, line2)
  drawHeadedMessage(ctx, { line1, line2 })
end

-- ---------------------------------------------------------------------------
-- Widget lifecycle (create / tick / draw / refresh)
-- ---------------------------------------------------------------------------

local function create(zone, options)
  -- Logic state lives on the core context; the widget owns only zone, options and
  -- the tick/error counters. With core missing, still return a usable ctx so
  -- drawTile() can render the error tile.
  local ctx = core and core.newContext() or {}
  ctx.zone = zone
  ctx.cfg  = options

  ctx.lastTick    = 0
  ctx.errorStreak = 0
  ctx.fatalError  = false

  if core then core.pollConfig(ctx) end
  return ctx
end

local function update(ctx, options)
  ctx.cfg = options
end

-- One data-processing cycle (no lcd.*): the core pipeline, then stick navigation
-- while a selection popup is open.
local function tickImpl(ctx)
  if core.tick(ctx) then core.pollSelectionSticks(ctx) end
end

-- Throttled, fault-tolerant wrapper called from both background() and refresh():
-- EdgeTX only runs background() while off-screen, so refresh() must drive it too
-- or the tile freezes on-screen. Throttled to TICK_INTERVAL regardless of caller.
-- tickImpl runs inside pcall; repeated failures flip the widget into a terminal
-- error state rather than crashing EdgeTX.
local function tick(ctx)
  if not core or ctx.fatalError then return end

  local now = getTime()
  if ctx.lastTick ~= 0 and (now - ctx.lastTick) < TICK_INTERVAL then
    return
  end
  ctx.lastTick = now

  if pcall(tickImpl, ctx) then
    ctx.errorStreak = 0
  else
    ctx.errorStreak = ctx.errorStreak + 1
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
  -- Popup closed: the next popup's marquee starts at the name start.
  if not ctx.pendingSelection then ctx.marqueeKey = nil end

  -- core.lua not installed / broken: same error-tile UI as every other problem.
  if not core then
    drawErrorTile(ctx, "Core missing", "Reinstall Lipo Nanny")
    return
  end

  -- Terminal error first — once set, nothing else is trustworthy.
  if ctx.fatalError then
    drawErrorTile(ctx, "Widget error", "Restart radio")
    return
  end

  -- Setup problems (settings, model, sensors, cell count): one tile, the details
  -- are listed in the settings tool.
  if #core.setupErrors(ctx) > 0 then
    drawErrorTile(ctx, "Configuration error", "Please check Tool Flight Bag")
    return
  end

  -- Battery-selection popup (0 or >1 plausible candidates). Driven by stick
  -- gestures in tick() (core.pollSelectionSticks); here we only render it. Commit
  -- clears pendingSelection, so the next frame falls through to the live tile.
  if ctx.pendingSelection then
    drawSelectionPopup(ctx)
    if core.isOnline(ctx) then drawHeartbeat(ctx) end   -- link is live during selection
    return
  end

  -- Tiles by flight phase: preflight page, live tile in flight, end page.
  if ctx.phase == "WAITING" then
    drawWaitingTile(ctx)
  elseif core.isActive(ctx) then
    -- Settle window: reuse the waiting tile instead of a live tile full of "--"
    -- (cellMismatch/popup handled above, so nil profile here means "still settling").
    if ctx.selectedProfile and ctx.phase == "PRE" then
      drawPreTile(ctx)
    elseif ctx.selectedProfile then
      drawConnectedTile(ctx)
    else
      drawWaitingTile(ctx)
    end
    if core.isOnline(ctx) then drawHeartbeat(ctx) end
  elseif ctx.phase == "ENDED" then
    drawEndedTile(ctx)
  end
end

local function refresh(ctx, event, touchEvent)
  tick(ctx)  -- Drive logic in the foreground too (background() won't run then; see tick()).

  -- Pick the palette from the "Theme" CHOICE option (1 = Dark, 2 = Light; anything
  -- else falls back to Dark). Module-global is safe since refresh() runs one
  -- instance's draw at a time.
  COLORS = (ctx.cfg and ctx.cfg.Theme == 2) and LIGHT or DARK

  -- Brand/heading colour for this frame (after the palette so the "Default" fallback
  -- picks up the active palette's accent). State colours stay on COLORS.accent.
  BRAND = brandColor(ctx.cfg and ctx.cfg.Accent, ctx.cfg and ctx.cfg.AccentColor)

  -- DARK paints its own panel so the tile looks the same on any radio theme; LIGHT
  -- leaves the background transparent so the radio theme shows through.
  if not COLORS.transparent then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLORS.panel)
  end

  -- Milky overlay (Light theme only): Transparency choice 1..6 = 0..100 % see-through
  -- -> opacity 0..15 (15 = invisible); anything else (e.g. a pre-choice value) = default.
  -- Drawn in a theme colour over the transparent background.
  local trans = ctx.cfg and ctx.cfg.Transparency
  if type(trans) ~= "number" or trans < 1 or trans > 6 then trans = 3 end
  if COLORS.transparent and trans < 6 then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLOR_THEME_PRIMARY2, 3 * (trans - 1))
  end

  -- A drawing fault must not leave a blank tile without a hint.
  if not pcall(drawTile, ctx) then
    dtext(sx(4), sx(4), "Widget error", COLORS.muted, SMLSIZE)
  end
end

-- ---------------------------------------------------------------------------
-- Widget registration
-- ---------------------------------------------------------------------------

return {
  name       = "Lipo Nanny",
  options    = {
    -- Theme dropdown (CHOICE value is the 1-based index; default 1 = "Dark";
    -- needs EdgeTX 2.11+). Transparency: see-through share of the milky overlay, Light theme only.
    { "Theme", CHOICE, 1, { "Dark", "Light" } },
    { "Transparency", CHOICE, 3, { "0%", "20%", "40%", "60%", "80%", "100%" } },
    -- Brand/heading colour: 1 Default (palette green), 2 Theme (COLOR_THEME_FOCUS),
    -- 3 Custom (AccentColor picker, default the original Dark lime).
    { "Accent", CHOICE, 1, { "Default", "Theme", "Custom" } },
    { "AccentColor", COLOR, lcd.RGB(124, 210, 48) },
  },
  create     = create,
  update     = update,
  background = background,
  refresh    = refresh,
}
