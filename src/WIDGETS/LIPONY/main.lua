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

-- Uniform vertical gap between the FULL tier's stacked rows (header/big number/
-- caption/value/sub-line), kept tight so a quarter-page tile still fits at FULL.
-- Used by drawConnectedFull, drawMetricBlock and connectedFitsFull — all three
-- must agree or the tier maths drift apart.
local METRIC_GAP = sx(1)

-- Two palettes, picked per frame by the "Theme" option (see refresh()). DARK paints
-- a near-black panel; LIGHT stays transparent so the radio theme shows through.
-- `accent` is the "good"-state green (%/bar/glyph/voltage); warn/crit colours are
-- theme-independent. Brand/heading colour is separate (BRAND, below) so the Accent
-- option never touches these state colours.
local DARK = {
  panel   = lcd.RGB( 18,  20,  18),   -- near-black background
  accent  = lcd.RGB(124, 210,  48),   -- lime green (% / V / bar / glyph "ok" state)
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


-- Bar-fill color (only the bar changes color, text stays neutral).
local function getBarColor(restPct, warnPct, critPct)
  if restPct > warnPct then return COLORS.accent end   -- green (theme accent)
  if restPct > critPct then return WARN_COL      end
  return CRIT_COL
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
-- Live tile (PRE and FLIGHT): readouts, battery glyph and threshold bar, scaling down through
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
  while flag ~= SMLSIZE and textW(text, flag) > maxW do
    flag = smallerFont(flag)
  end
  return flag
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

-- Vertical battery glyph: a cap, an outlined body and `nSeg` segments filled from
-- the bottom up to `pct`, in `color`; the empty part stays on the track colour.
local function drawBatteryGlyph(x, y, w, h, pct, color, nSeg)
  nSeg = nSeg or 10                        -- segment count (FULL: 10, MID: 5)
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

-- Horizontal threshold bar: track, coloured fill, yellow/red tick marks at
-- warn/crit, and (if withLabels) the WARN caption above / CRIT caption below the
-- bar so close thresholds never collide. Caller must leave one text line above
-- and below the bar.
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
  tick(warn, WARN_COL)
  tick(crit, CRIT_COL)
  if withLabels then
    local lh = fontH(SMLSIZE)
    local function label(thr, txt, col, ly)
      local tw = textW(txt, SMLSIZE)
      local lx = x + math.floor(w * thr / 100) - math.floor(tw / 2)
      if lx < x then lx = x elseif lx + tw > x + w then lx = x + w - tw end
      dtext(lx, ly, txt, col, SMLSIZE)
    end
    label(warn, string.format("WARN %d %%", warn), WARN_COL, y - lh - sx(1))  -- above
    label(crit, string.format("CRIT %d %%", crit), CRIT_COL,    y + h + sx(2))   -- below
  end
end

-- A metric column: big number+unit (bottom-aligned to `bigBottom`), then caption,
-- value and sub-line. Both columns share `bigBottom` so their rows line up even
-- when the two big numbers use different font sizes.
local function drawMetricBlock(x, bigBottom, big, unit, bigColor, capLine, valLine, subLine, bigFlag, colW)
  local bigH = fontH(bigFlag)
  drawValueUnit(x, bigBottom - bigH, big, unit, bigColor, bigFlag, smallerFont(bigFlag))
  -- Caption / value / sub-line separated by one uniform gap, each placed at its
  -- own measured height (a fixed line height would drift across screens).
  local gap     = METRIC_GAP
  local capH = fontH(SMLSIZE)
  -- Value line is the only element in a real (non-SMLSIZE) font, so shrink it to
  -- the column width instead of letting e.g. "1500 mAh" spill over.
  local valFlag = fitWidth(valLine, 0, colW)
  local valH = fontH(valFlag)
  local y = bigBottom + gap
  dtext(x, y, capLine, COLORS.muted, SMLSIZE)
  y = y + capH + gap
  dtext(x, y, valLine, COLORS.fg, valFlag)
  y = y + valH + gap
  dtext(x, y, subLine, COLORS.muted, SMLSIZE)
end

-- Colour for the live voltage readout: green/yellow/red from the chemistry's
-- per-cell voltage thresholds. Falls back to the accent green when
-- voltage/cells/chemistry are unavailable.
local function voltageColor(ctx)
  local lvl = core.voltageLevel(ctx)
  if lvl == nil then return COLORS.fg end   -- missing value: neutral, not OK
  return (lvl == 0 and COLORS.accent) or (lvl == 1 and WARN_COL) or CRIT_COL
end

-- Builds the display strings/colours once for the live tile metrics.
local function connectedMetrics(ctx)
  local restPct    = core.calculateRestPct(ctx)
  local warn, crit = core.getThresholds(ctx)
  local effective  = core.effectiveCapacityMah(ctx)
  -- `used` includes the pre-flight start offset (drives remaining %/mAh); the
  -- CONSUMED display shows only ctx.capacity, the in-flight telemetry value.
  local used       = (ctx.capacity and ctx.startOffsetMah) and (ctx.capacity + ctx.startOffsetMah) or nil
  local remaining  = (effective and used) and math.max(0, effective - used) or nil
  local profile    = ctx.selectedProfile and ctx.selectedProfile.name or nil
  return {
    restPct  = restPct,
    warn     = warn,
    crit     = crit,
    pctColor = restPct and getBarColor(restPct, warn, crit) or COLORS.fg,   -- missing: neutral
    vColor   = voltageColor(ctx),
    label    = formatBatteryLabel(profile, ctx.selectedInstances),
    pctText  = restPct and string.format("%d", math.floor(restPct + 0.5)) or "--",
    vText    = ctx.voltage and string.format("%.1f", ctx.voltage) or "--.-",
    vCell    = (ctx.voltage and ctx.cells and ctx.cells > 0)
               and string.format("%.2f V/cell", ctx.voltage / ctx.cells) or "--.- V/cell",
    remText  = remaining and string.format("%d mAh", math.floor(remaining + 0.5)) or "-- mAh",
    ofText   = effective and string.format("of %d mAh", math.floor(effective + 0.5)) or "",
    consText = ctx.capacity and string.format("%d mAh", math.floor(ctx.capacity + 0.5)) or "-- mAh",
    timeLeft = ctx.timeLeftStr or core.formatTimeLeft(ctx),  -- 2 s-throttled snapshot
  }
end

-- Remaining-flight-time mini-block: a centred "TIME LEFT" caption above the mm:ss
-- value. flightTimeBlockH() returns its total height (and the caption height) so
-- the caller can decide whether it fits and where to centre it.
local TIME_VAL_FLAG = MIDSIZE
local function flightTimeBlockH()
  local capH = fontH(SMLSIZE)
  local valH = fontH(TIME_VAL_FLAG)
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
  return math.max(textW("of 0000 mAh", SMLSIZE),
                  textW("0.00 V/cell", SMLSIZE))
end

-- FULL-tier column geometry: glyph is a fixed 19% of width `w`, the two text columns
-- split the rest. Returns (colW, glyphW, colGap); shared by renderer and tier picker.
local function fullColumns(w)
  local pad      = sx(4)
  local colGap   = sx(6)
  local gW       = math.floor(w * 0.19)
  local colW     = math.floor((w - 2 * pad - gW - 2 * colGap) / 2)
  return colW, gW, colGap
end

-- FULL tier: header, two metric columns and the battery glyph. The threshold bar
-- is added only if there's enough free height below the content.
local function drawConnectedFull(w, h, m)
  local pad        = sx(4)
  drawHeaderLabel(pad, pad, m.label)
  local hdrH    = fontH(SMLSIZE)   -- actual header height (SMLSIZE)
  local midTop     = pad + hdrH + METRIC_GAP
  local contentBot = h - pad
  local midH       = contentBot - midTop
  local colW, gW, colGap = fullColumns(w)
  local gX         = w - pad - gW
  local maxBigH    = math.floor(midH * 0.5)
  -- Size % from a fixed "100%" reference so "1%" isn't bigger than "100%"; V is
  -- one step smaller (shrunk further only if it overflows).
  local pctFlag    = pickFont("100%", colW, maxBigH, MIDSIZE)   -- at most MIDSIZE, like Link Sentinel's %
  local vFlag      = fitWidth(m.vText .. "V", smallerFont(pctFlag), colW)
  -- Shared bottom edge for both big numbers (= the taller, % one) so the rows
  -- beneath them align across the two columns.
  local pctH    = fontH(pctFlag)
  local bigBottom  = midTop + pctH
  drawMetricBlock(pad, bigBottom, m.pctText, "%", m.pctColor,
                  "REMAINING", m.remText, m.ofText, pctFlag, colW)
  drawMetricBlock(pad + colW + colGap, bigBottom, m.vText, "V", m.vColor,
                  m.vCell, m.consText, "CONSUMED", vFlag, colW)
  local smlH    = fontH(SMLSIZE)
  local valH    = fontH(0)   -- value row (default font)
  -- Mirror drawMetricBlock's uniform-gap stack: bottom of the CONSUMED/"of … mAh" line.
  local textBottom = bigBottom + METRIC_GAP + smlH + METRIC_GAP + valH + METRIC_GAP + smlH
  -- Threshold bar pinned to the bottom if it fits below the content (with labels,
  -- one line above/below for WARN/CRIT). Resolved before the glyph so the glyph
  -- knows whether anything sits below it.
  local barH       = sx(8)
  local roomBelow  = contentBot - textBottom
  local hasBar     = roomBelow >= barH + sx(4)
  local withLabels = hasBar and roomBelow >= barH + 2 * smlH + sx(4)
  local barY, barTop = nil, contentBot   -- barTop = bottom of the time-block area
  if hasBar then
    barY   = contentBot - (withLabels and smlH or 0) - barH
    barTop = barY - (withLabels and smlH or 0)   -- top of the bar block (incl. WARN label)
  end
  local tlH        = flightTimeBlockH()
  local hasTime    = (barTop - textBottom) >= tlH
  -- Glyph bottom = same inset (pad) as the right edge (ends at h-pad), unless the bar
  -- or flight-time block sits below — then it ends at the text so it doesn't overlap.
  local gBottom    = (hasBar or hasTime) and textBottom or contentBot
  if gW > 0 then
    drawBatteryGlyph(gX, midTop, gW, gBottom - midTop, m.restPct, m.pctColor)
  end
  if hasBar then
    drawThresholdBar(pad, barY, w - 2 * pad, barH, m.restPct, m.warn, m.crit, withLabels)
  end
  -- Remaining flight time, centred in the gap between the content and the bar.
  if hasTime then
    local ty = textBottom + math.floor(((barTop - textBottom) - tlH) / 2)
    drawFlightTimeBlock(math.floor(w / 2), ty, m.timeLeft)
  end
end

-- MEDIUM tier: the FULL two-column content (header, %/V, labels, mAh, of-X/CONSUMED)
-- all at SMLSIZE with a slim glyph, so 5 rows fit a short 1/6 tile.
local function drawConnectedMedium(w, h, m)
  local pad           = sx(4)   -- same edge inset as FULL/ENDED so the header doesn't shift on tier change
  drawHeaderLabel(pad, pad, m.label)
  local smlH       = fontH(SMLSIZE)
  -- 5 rows spread evenly between top/bottom pad; each row's y is computed directly
  -- from the total span (not accumulated) so rounding never piles onto the last row.
  local span          = h - 2 * pad - smlH
  if span < 4 * (smlH - 4) then span = 4 * (smlH - 4) end
  local function rowY(i) return pad + math.floor(i * span / 4 + 0.5) end
  -- Slim glyph (~12% width) on the right, same sx(4) margins as FULL.
  local gm            = sx(4)
  local glyphGap      = sx(4)
  local gW            = math.floor(w * 0.12)
  local colW          = math.floor((w - 2 * pad - glyphGap - gW - gm) / 2)
  local leftX, rightX = pad, pad + colW + pad
  -- Glyph top at the first metric row; bottom uses the same inset as the right edge.
  local gTop          = rowY(1)
  drawBatteryGlyph(w - gm - gW, gTop, gW, (h - gm) - gTop, m.restPct, m.pctColor, 5)
  dtext(leftX,  rowY(1), m.pctText .. " %", m.pctColor, SMLSIZE)
  dtext(rightX, rowY(1), m.vText .. " V",   m.vColor,   SMLSIZE)
  dtext(leftX,  rowY(2), "REMAINING", COLORS.muted, SMLSIZE)
  dtext(rightX, rowY(2), m.vCell,     COLORS.muted, SMLSIZE)
  dtext(leftX,  rowY(3), m.remText,  COLORS.fg, SMLSIZE)
  dtext(rightX, rowY(3), m.consText, COLORS.fg, SMLSIZE)
  dtext(leftX,  rowY(4), m.ofText,   COLORS.muted, SMLSIZE)
  dtext(rightX, rowY(4), "CONSUMED",  COLORS.muted, SMLSIZE)
end

-- SMALL tier: like MEDIUM but with an adaptive row count (no glyph); all SMLSIZE
-- except %/V, which scales to the row height. Rows kept by priority: %/V, header,
-- REMAINING/V-cell, mAh values, of-X/CONSUMED (dropped first).
local function drawConnectedSmall(w, h, m)
  local pad     = sx(4)   -- match FULL/MEDIUM/ENDED edge inset (consistent header)
  local gap     = 2
  local smlH = fontH(SMLSIZE)
  local avail   = h - 2 * pad
  local colW          = math.floor((w - 3 * pad) / 2)   -- full width, no glyph column
  local leftX, rightX = pad, pad + colW + pad

  -- Rows are counted as if every row were smlH tall, so the header (priority 2)
  -- survives on short zones instead of being crowded out by a large %/V line.
  local nRows = math.floor((avail + gap) / (smlH + gap))
  if nRows < 1 then nRows = 1 end
  if nRows > 5 then nRows = 5 end

  -- %/V line absorbs the leftover height (capped to ~2 lines) so it grows on taller
  -- tiles without displacing other rows. Both share one size so % and V match.
  local rowsBaseH = nRows * smlH + (nRows - 1) * gap
  local extra     = math.max(0, avail - rowsBaseH)
  local pctS, vS  = m.pctText .. " %", m.vText .. " V"
  local bigRef    = (textW(pctS, SMLSIZE) >= textW(vS, SMLSIZE)) and pctS or vS
  local bigFlag   = pickFont(bigRef, colW, math.min(smlH + extra, 2 * smlH))
  local bigH   = fontH(bigFlag)

  local function pairDraw(lt, lc, rt, rc)
    return function(y)
      dtext(leftX,  y, lt, lc, SMLSIZE)
      dtext(rightX, y, rt, rc, SMLSIZE)
    end
  end
  -- Candidates in PRIORITY order; `ord` is the on-screen position (top = 1). Each
  -- carries its own height `h` so the block stacks compactly (bigPair is taller).
  local cand = {
    { ord = 2, h = bigH, draw = function(y)
        dtext(leftX,  y, pctS, m.pctColor, bigFlag)
        dtext(rightX, y, vS,   m.vColor,   bigFlag)
        -- without the REMAINING row the caption sits beside the % (short LEFT), when it fits
        local capX = leftX + textW(pctS, bigFlag) + sx(6)
        if nRows < 3 then
          local cap = "REMAINING"
          if capX + textW(cap, SMLSIZE) > rightX - sx(4) then cap = "LEFT" end
          if capX + textW(cap, SMLSIZE) <= rightX - sx(4) then
            dtext(capX, y + bigH - smlH, cap, COLORS.muted, SMLSIZE)
          end
        end
      end },
    { ord = 1, h = smlH, draw = function(y) drawHeaderLabel(pad, y, m.label) end },
    { ord = 3, h = smlH, draw = pairDraw("REMAINING", COLORS.muted, m.vCell, COLORS.muted) },
    { ord = 4, h = smlH, draw = pairDraw(m.remText, COLORS.fg, m.consText, COLORS.fg) },
    { ord = 5, h = smlH, draw = pairDraw(m.ofText, COLORS.muted, "CONSUMED", COLORS.muted) },
  }
  local rows = {}
  for i = 1, nRows do rows[i] = cand[i] end        -- keep the top nRows by priority
  table.sort(rows, function(a, b) return a.ord < b.ord end)

  -- Header (ord 1, if present) pins to the top edge; the remaining rows form a
  -- compact block centred below it, so the readout never sticks to the bottom edge.
  local first = 1
  local topY  = pad
  if rows[1] and rows[1].ord == 1 then
    rows[1].draw(pad)
    topY  = pad + rows[1].h + gap
    first = 2
  end
  local restH = 0
  for i = first, #rows do
    restH = restH + rows[i].h + (i > first and gap or 0)
  end
  local y = topY + math.max(0, math.floor(((h - pad - topY) - restH) / 2))
  for i = first, #rows do
    rows[i].draw(y)
    y = y + rows[i].h + gap
  end
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

-- True when the FULL two-column layout fits the zone. Checked in absolute pixels
-- because fonts don't scale with S (only positions do): each column must fit its
-- longest fixed (SMLSIZE) line, and the zone must be tall enough for header +
-- MIDSIZE big number + three sub-rows. Using real font metrics keeps this
-- self-tuning across screen sizes instead of a magic constant.
local function connectedFitsFull(w, h)
  if fullColumns(w) < minColW() - TIER_TOL then return false end   -- same px slack as the height check
  local pad     = sx(4)
  local hdrH = fontH(SMLSIZE)
  local bigH = fontH(MIDSIZE)
  local smlH = fontH(SMLSIZE)
  local valH = fontH(0)   -- value row uses the default font
  -- Mirror drawMetricBlock's uniform-gap stack: header, big number, caption, value,
  -- sub-line — each gap METRIC_GAP, each row at its real height (smlH/valH/MIDSIZE).
  local needH   = pad + hdrH + METRIC_GAP + bigH + METRIC_GAP + smlH + METRIC_GAP + valH + METRIC_GAP + smlH + pad
  return h >= needH - TIER_TOL
end

-- Picks the tier by what fits the zone. FULL is used whenever its content fits
-- (its bar labels/time-left block degrade on their own when height is tight);
-- shorter/narrower zones fall back to MEDIUM/SMALL.
local function drawConnectedTile(ctx)
  local w, h = ctx.zone.w, ctx.zone.h
  local m    = connectedMetrics(ctx)
  -- MID only when its 5 SMLSIZE rows fit (pad=2, min pitch smlH-4); else SMALL.
  -- Constants must match drawConnectedMedium / drawConnectedSmall.
  local smlH    = fontH(SMLSIZE)
  local fiveRowMin = 2 * 2 + smlH + 4 * (smlH - 4)
  if connectedFitsFull(w, h) then
    drawConnectedFull(w, h, m)
  elseif h >= fiveRowMin - TIER_TOL then
    drawConnectedMedium(w, h, m)
  else
    drawConnectedSmall(w, h, m)
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
-- Preflight and end pages (flight phases PRE and ENDED): the content of Flight
-- Wingman's battery column, header and margins as on the live tile.
-- ---------------------------------------------------------------------------

-- Colour of a check level: 0 accent, 1 yellow, 2 red.
local function levelColor(level)
  if level == 2 then return CRIT_COL end
  if level == 1 then return WARN_COL end
  return COLORS.accent
end

-- Seconds left on a page timer that started at `since` (the core's ms clock,
-- getTime() * 10) and runs `total` ms.
local function secsLeft(since, total)
  return math.max(0, math.ceil((total - (getTime() * 10 - since)) / 1000))
end

-- Countdown at the bottom right: text left of a bar that runs empty. The text
-- shrinks to the seconds when the row is too narrow.
local function drawCountdown(x0, W, y, secs, total, label)
  local smlH = fontH(SMLSIZE)
  local barH = math.max(3, sx(6))
  local barW = math.max(sx(30), math.floor(W * 0.35))
  local bx   = x0 + W - barW
  local by   = y + math.floor((smlH - barH) / 2)
  lcd.drawFilledRectangle(bx, by, barW, barH, COLORS.track)
  local fw = math.floor(barW * math.max(0, math.min(1, secs / total)))
  if fw > 0 then lcd.drawFilledRectangle(bx, by, fw, barH, COLORS.muted) end
  local txt = string.format("%s in %d s", label, secs)
  if textW(txt, SMLSIZE) > bx - sx(6) - x0 then txt = string.format("%d s", secs) end
  dtext(bx - sx(6) - textW(txt, SMLSIZE), y, txt, COLORS.muted, SMLSIZE)
end

-- Status line: dot plus text in the level colour (PACK READY / BATTERY LOW).
local function drawStatusLine(x, y, st)
  local smlH = fontH(SMLSIZE)
  local r    = math.max(2, sx(4))
  local col  = levelColor(st.level)
  lcd.drawFilledCircle(x + r, y + math.floor(smlH / 2), r, col)
  dtext(x + 2 * r + sx(4), y, st.text, col, SMLSIZE)
  return 2 * r + sx(4) + textW(st.text, SMLSIZE)
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

-- Preflight page: per-cell voltage (big, check colour) with the pack total,
-- the threshold bar, the battery status and the countdown to the flight page
-- while the check is met. Status and countdown rows are fixed, the countdown
-- row stays empty while it does not run, so nothing moves. Zones below FULL
-- keep header, a voltage row, status and countdown as far as they fit.
local function drawPreTile(ctx)
  local w, h   = ctx.zone.w, ctx.zone.h
  local pad    = sx(4)
  local smlH   = fontH(SMLSIZE)
  local m      = connectedMetrics(ctx)
  local st     = core.preflight(m.restPct, m.warn, m.crit)
  local col    = levelColor(st.level)
  local hasV   = ctx.voltage and ctx.cells and ctx.cells > 0
  local cell   = hasV and string.format("%.2f", ctx.voltage / ctx.cells) or "-.--"
  local total  = ctx.voltage and string.format("%.1f V", ctx.voltage) or "--.- V"
  local secs   = ctx.readySince and secsLeft(ctx.readySince, core.PRE_HOLD_T)
  drawHeaderLabel(pad, pad, m.label)
  local bottomY = h - pad - smlH
  local function countdown(y)
    if secs then drawCountdown(pad, w - 2 * pad, y, secs, core.PRE_HOLD_T / 1000, "Flight page") end
  end

  if not connectedFitsFull(w, h) then
    local n    = math.floor((h - 2 * pad - smlH) / (smlH - sx(4)))
    -- rows as on Link Sentinel and GPS Homer: voltage, bar, status, countdown; with
    -- three rows the countdown joins the status line, with two the bar goes too
    local k    = math.max(1, math.min(4, n))
    local rowY = rowSpread(h, pad, k)
    local bar  = k >= 3 and 1 or 0
    -- value row as on Link Sentinel: value + unit coloured (up to MIDSIZE),
    -- PER CELL muted beside it, TOTAL muted before the pack voltage on the right
    local top    = rowY(1)
    local valTxt = cell .. " V"
    local numF   = SMLSIZE
    local maxH   = k >= 2 and (rowY(2) - sx(2) - top) or (h - pad - top)
    for _, f in ipairs({ MIDSIZE, 0 }) do
      if textW(valTxt, f) <= (w - 2 * pad) * 0.5 and fontH(f) <= maxH then numF = f; break end
    end
    dtext(pad, top, valTxt, col, numF)
    local capY = top + fontH(numF) - smlH
    local totX = w - pad - textW("TOTAL ", SMLSIZE) - textW(total, SMLSIZE)
    dtext(totX, capY, "TOTAL ", COLORS.muted, SMLSIZE)
    dtext(totX + textW("TOTAL ", SMLSIZE), capY, total, COLORS.fg, SMLSIZE)
    local capX = pad + textW(valTxt, numF) + sx(6)
    if capX + textW("PER CELL", SMLSIZE) <= totX - sx(4) then
      dtext(capX, capY, "PER CELL", COLORS.muted, SMLSIZE)
    end
    if bar == 1 then
      local barH = sx(8)
      drawThresholdBar(pad, rowY(2) + math.floor((smlH - barH) / 2), w - 2 * pad, barH, m.restPct, m.warn, m.crit, false)
    end
    if k >= 4 then
      drawStatusLine(pad, rowY(3), st)
      countdown(rowY(4))
    elseif k >= 2 then   -- no row of its own: the countdown joins the status line
      local cx = pad + drawStatusLine(pad, rowY(k), st) + sx(8)
      if secs then drawCountdown(cx, w - pad - cx, rowY(k), secs, core.PRE_HOLD_T / 1000, "Flight page") end
    end
    return
  end

  -- FULL: big per-cell value with the caption beside it, TOTAL right, then the threshold bar
  -- (WARN/CRIT captions when there is room), the status and the bottom row;
  -- the spare height is shared out evenly between the blocks.
  local top     = pad + smlH + METRIC_GAP
  local bigFlag = pickFont("0.00V", math.floor((w - 2 * pad) * 0.5), math.floor((bottomY - top) * 0.4))
  local bigH    = fontH(bigFlag)
  local barH    = sx(8)
  local fixed   = bigH + barH + smlH
  local labels  = (bottomY - top - fixed) >= 2 * smlH + sx(3) + 3 * sx(4)
  -- at least one text row high, so the status line sits where the sibling widgets put it
  local barBlk  = math.max(smlH, barH + (labels and (2 * smlH + sx(3)) or 0))
  local gap     = math.max(0, math.floor((bottomY - top - (fixed - barH + barBlk)) / 3))
  local vw      = drawValueUnit(pad, top, cell, "V", col, bigFlag, smallerFont(bigFlag))
  local tw      = textW(total, 0)
  -- TOTAL above the value only when it clears the heartbeat dot, else beside it
  local tcapY   = top + bigH - fontH(0) - smlH
  local stacked = tcapY >= sx(12)
  local rightW  = stacked and math.max(tw, textW("TOTAL", SMLSIZE)) or (textW("TOTAL", SMLSIZE) + sx(4) + tw)
  local capX    = pad + vw + sx(6)
  if capX + textW("PER CELL", SMLSIZE) <= w - pad - rightW - sx(4) then
    dtext(capX, top + bigH - smlH, "PER CELL", COLORS.muted, SMLSIZE)
  end
  dtext(w - pad - tw, top + bigH - fontH(0), total, COLORS.fg, 0)
  if stacked then
    dtext(w - pad - textW("TOTAL", SMLSIZE), tcapY, "TOTAL", COLORS.muted, SMLSIZE)
  else
    dtext(w - pad - rightW, top + bigH - smlH, "TOTAL", COLORS.muted, SMLSIZE)
  end
  local blkY    = top + bigH + gap
  local barY    = blkY + (labels and (smlH + sx(1)) or math.floor((barBlk - barH) / 2))
  drawThresholdBar(pad, barY, w - 2 * pad, barH, m.restPct, m.warn, m.crit, labels)
  drawStatusLine(pad, blkY + barBlk + gap, st)
  countdown(bottomY)
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
  local lastV = (vpc and ctx.cells) and string.format("%.1f V  %.2f V/c", vpc * ctx.cells, vpc) or "--"
  local cycles = {}
  for _, inst in ipairs(lf.instances or {}) do cycles[#cycles + 1] = tostring(core.cyclesFor(ctx, inst.id)) end
  local rows = {
    { { "USED CAPACITY", "USED CAP" }, lf.usedMah and string.format("%d mAh", math.floor(lf.usedMah + 0.5)) or "--" },
    { "PACK CYCLES", (#cycles > 0) and table.concat(cycles, ", ") or "--" },
    { "CHARGE", left and (left .. " %") or "--", left and getBarColor(left, warn, crit),
      (start and (start .. " %") or "--") .. " -> " },
    { { "LAST VOLTAGE", "LAST V" }, lastV },
    { { "MAX CURRENT", "MAX CURR" }, ctx.maxCurrent and string.format("%.1f A", ctx.maxCurrent) or "--" },
  }
  drawHeaderLabel(pad, pad, formatBatteryLabel(lf.profileName, lf.instances))
  local n    = math.floor((h - 2 * pad - smlH) / (smlH - sx(4)))
  local k    = math.max(0, math.min(#rows, n - 1))
  local rowY = rowSpread(h, pad, k + 1)
  for i = 1, k do drawLR(pad, w - 2 * pad, rowY(i), rows[i][1], rows[i][2], rows[i][3], rows[i][4]) end
  drawCountdown(pad, w - 2 * pad, rowY(k + 1), secsLeft(ctx.endedAt or 0, core.ENDED_HOLD_T),
                core.ENDED_HOLD_T / 1000, "Wait page")
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
  local hh, sq = fontH(SMLSIZE), sx(5)   -- accent square + title as on GPS Homer
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
