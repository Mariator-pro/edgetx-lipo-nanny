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

-- Shared core module: all non-display logic (config I/O, telemetry, the flight
-- state machine, battery detection, warnings and the derived metrics) lives in
-- core.lua (SD path /SCRIPTS/LIPONY/core.lua). If it can't be loaded, `core` stays
-- nil and drawTile() renders a "core.lua missing" tile — the widget still loads so
-- the hint is visible instead of a blank tile or a hard script error.
local core
do
  local chunk = loadScript("/SCRIPTS/LIPONY/core.lua")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok then core = mod end
  end
end

-- Widget-only lifecycle constants (logic timings live in core.lua).
local TICK_INTERVAL = 10   -- 0.1 s; data-processing cadence (10 Hz)
local ERROR_LIMIT   = 5    -- consecutive tick failures before the widget gives up

-- Stick-gesture thresholds for the selection popup (getValue range -1024..+1024).
local STICK_STEP        = 500  -- deflection that counts as one cursor step
local STICK_DEADZONE    = 200  -- back inside this re-arms the next step (edge detection)
local CONFIRM_THRESHOLD = 700  -- aileron deflection (full right) that means "confirm"
local CONFIRM_HOLD      = 100  -- 1.0 s hold (hundredths of a second) before commit;
                               -- long enough for the fill-bar confirm animation to read
-- Opacity (0 invisible … 15 opaque) of the confirm-hold fill: drawn in the brand
-- colour but semi-transparent, so the solid-brand cursor text stays readable on top
-- whatever brand colour the pilot picked (no separate dim shade to maintain).
local CONFIRM_FILL_OPACITY = 8

-- Display scaling: pixel constants are relative to a 480 px reference width,
-- matching EdgeTX's own LVGL 480-baseline. Wider screens scale up by S = LCD_W/480
-- (an 800 px screen → S ≈ 1.67; a 480 px screen → S = 1.0).
local REF_W = 480
local S     = (LCD_W or REF_W) / REF_W
local TH    = math.floor(18 * S + 0.5)  -- standard line height for default font
local function sx(v) return math.floor(v * S + 0.5) end

-- Slack on the FULL/MEDIUM height thresholds (connectedFitsFull / drawConnectedTile):
-- a zone whose height lands a pixel or two above a tier boundary (e.g. 112 px vs
-- needH 111) would otherwise flip tier on a minor font-metric change. The
-- tolerance just widens the margin — it doesn't move any measured zone to a new tier.
local TIER_TOL = sx(4)

-- Uniform vertical gap between the FULL tier's stacked rows (header→big number→
-- caption→value→sub-line). Kept tight (sx(1)) so the four metric rows fit a short
-- quarter-page tile (215×112) at FULL without shrinking the %/V readouts. Used by
-- drawConnectedFull, drawMetricBlock and the connectedFitsFull height check, which
-- must all agree or the glyph/tier maths drift apart.
local METRIC_GAP = sx(1)

-- Two palettes, picked per frame by the "Theme" option (see refresh()). DARK paints
-- its own near-black panel; LIGHT stays transparent (radio theme shows through) with
-- black text. `accent` is the OK/"good"-state green (%/bar/glyph/voltage); the
-- yellow/red escalation colours are identical in both themes. The brand/heading
-- colour is a SEPARATE variable (BRAND, below) so the Accent option can recolour
-- the marque without ever touching these state colours.
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
-- option. Kept apart from COLORS.accent on purpose: sharing one variable would let
-- the option bleed into the bar/%/voltage state colours. Default is the active
-- palette's accent green, so each theme keeps its own green when set to "Default".
local BRAND = DARK.accent

-- Resolve the brand text colour from the Accent option: "Theme" pulls the active
-- EdgeTX theme's focus colour, "Custom" the AccentColor picker value. lcd.getColor
-- normalises either to a real RGB (the picker value may be a theme index, not raw
-- RGB). Falls back to the palette accent (Default) if unavailable.
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

-- Font flags from largest to smallest. XXLSIZE/DBLSIZE/MIDSIZE/SMLSIZE are EdgeTX
-- globals; 0 is the default font. Used by pickFont() to scale to the zone.
local FONT_STEPS = { XXLSIZE, DBLSIZE, MIDSIZE, 0, SMLSIZE }

-- Largest font flag whose rendered text fits within maxW×maxH, plus its measured
-- width/height. Falls back to the smallest font if nothing fits.
local function pickFont(text, maxW, maxH)
  for _, flag in ipairs(FONT_STEPS) do
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
-- CONNECTED tile: large readouts, a segmented battery glyph and a threshold bar.
-- One responsive layout that scales down through FULL → MEDIUM → SMALL tiers by
-- zone size.
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

-- Horizontal threshold bar: track, threshold-coloured fill up to `pct`, yellow/red
-- tick marks at the warn/crit positions and, when `withLabels`, the WARN caption
-- ABOVE the bar and the CRIT caption BELOW it — so the two never collide even when
-- the thresholds sit close together. Caller must leave one text line above and
-- below the bar.
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
    local _, lh = lcd.sizeText("0", SMLSIZE)
    local function label(thr, txt, col, ly)
      local tw = lcd.sizeText(txt, SMLSIZE)
      local lx = x + math.floor(w * thr / 100) - math.floor(tw / 2)
      if lx < x then lx = x elseif lx + tw > x + w then lx = x + w - tw end
      dtext(lx, ly, txt, col, SMLSIZE)
    end
    label(warn, string.format("WARN %d %%", warn), WARN_COL, y - lh - sx(1))  -- above
    label(crit, string.format("CRIT %d %%", crit), CRIT_COL,    y + h + sx(2))   -- below
  end
end

-- A metric column: big number+unit (in `bigFlag`, bottom-aligned to `bigBottom`),
-- then a small caption, a value line and a small sub-line. Both columns share the
-- same `bigBottom`, so their caption/value/sub rows line up across the tile even
-- when the two big numbers use different font sizes.
local function drawMetricBlock(x, bigBottom, big, unit, bigColor, capLine, valLine, subLine, bigFlag, colW)
  local _, bigH = lcd.sizeText(big .. unit, bigFlag)
  drawValueUnit(x, bigBottom - bigH, big, unit, bigColor, bigFlag, smallerFont(bigFlag))
  -- Caption / value / sub-line separated by ONE uniform gap, each placed using its
  -- own measured height — not a fixed TH = 18*S line-height approximation, which
  -- drifts from the real font on larger/smaller screens and looks uneven.
  local gap     = METRIC_GAP
  local _, capH = lcd.sizeText(capLine, SMLSIZE)
  -- The value line is the only block element in a real font (caption/sub are
  -- already SMLSIZE), so shrink it to the column on narrow tiles (e.g. a quarter
  -- page) instead of letting "1500 mAh" spill into the next column.
  local valFlag = fitWidth(valLine, 0, colW)
  local _, valH = lcd.sizeText(valLine, valFlag)
  local y = bigBottom + gap
  dtext(x, y, capLine, COLORS.muted, SMLSIZE)
  y = y + capH + gap
  dtext(x, y, valLine, COLORS.fg, valFlag)
  y = y + valH + gap
  dtext(x, y, subLine, COLORS.muted, SMLSIZE)
end

-- Colour for the live voltage readout: green/yellow/red from the chemistry's
-- per-cell loaded-voltage thresholds (voltageWarn/voltageCrit). The green end is the
-- theme accent (lime in Dark, darker green in Light); yellow/red are fixed. Falls
-- back to the accent green when voltage/cells/chemistry are unavailable.
local function voltageColor(ctx)
  local profile = ctx.selectedProfile
  local chem    = profile and core.CHEMISTRIES[profile.chemistry]
  if not chem or not chem.voltageWarn or not ctx.voltage or not ctx.cells or ctx.cells <= 0 then
    return COLORS.accent
  end
  local vpc = ctx.voltage / ctx.cells
  if vpc >= chem.voltageWarn then return COLORS.accent end
  if vpc >= chem.voltageCrit then return WARN_COL   end
  return CRIT_COL
end

-- Builds the display strings/colours once for the active CONNECTED metrics.
local function connectedMetrics(ctx)
  local restPct    = core.calculateRestPct(ctx)
  local warn, crit = core.getThresholds(ctx)
  local effective  = core.effectiveCapacityMah(ctx)
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
-- is added at the bottom only when there is enough free height below the content
-- (so it appears on roomy half/full-page tiles but not on short/cramped ones).
local function drawConnectedFull(w, h, m)
  local pad        = sx(4)
  drawHeaderLabel(pad, pad, m.label)
  local _, hdrH    = lcd.sizeText(m.label, SMLSIZE)   -- actual header height (SMLSIZE)
  local midTop     = pad + hdrH + METRIC_GAP
  local contentBot = h - pad
  local midH       = contentBot - midTop
  local colW, gW, colGap = fullColumns(w)
  local gX         = w - pad - gW
  local maxBigH    = math.floor(midH * 0.5)
  -- Size the % from a fixed "100%" reference so a single-digit reading ("1%") isn't
  -- bigger than "100%". V is one step smaller (shrunk further only if it overflows).
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
  local _, smlH    = lcd.sizeText("0", SMLSIZE)
  local _, valH    = lcd.sizeText("0", 0)   -- value row (default font)
  -- Mirror drawMetricBlock's uniform-gap stack: bottom of the CONSUMED/"of … mAh" line.
  local textBottom = bigBottom + METRIC_GAP + smlH + METRIC_GAP + valH + METRIC_GAP + smlH
  -- Threshold bar pinned to the bottom, only if it fits below the content. With
  -- labels it reserves one line above (WARN) and one below (CRIT). Resolved BEFORE
  -- the glyph so the glyph knows whether anything sits below it.
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
  local pad           = sx(4)   -- same edge inset as FULL/ENDED so the header
  drawHeaderLabel(pad, pad, m.label)  -- doesn't shift when the tier changes
  local _, smlH       = lcd.sizeText("0", SMLSIZE)
  -- 5 rows (header + 4 data) spread evenly between top and bottom pad. Each row's y
  -- comes DIRECTLY from the total span (rounded), not an accumulated floored `lead`
  -- whose dropped fractions pile onto the bottom edge as an uneven gap. So the last
  -- row always lands at h-pad (bottom margin == top pad); `span` floored to avoid overlap.
  local span          = h - 2 * pad - smlH
  if span < 4 * (smlH - 4) then span = 4 * (smlH - 4) end
  local function rowY(i) return pad + math.floor(i * span / 4 + 0.5) end
  -- Slim glyph (≈12% width) on the right, with the FULL tier's sx(4) margins.
  local gm            = sx(4)
  local glyphGap      = sx(4)   -- text→glyph gap, scaled like the other insets
  local gW            = math.floor(w * 0.12)
  local colW          = math.floor((w - 2 * pad - glyphGap - gW - gm) / 2)
  local leftX, rightX = pad, pad + colW + pad
  -- Glyph top at the first metric row; bottom with the same fixed inset (gm = sx(4))
  -- as the right edge, so the gap to the bottom matches the gap to the right side.
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

-- SMALL tier: like MID (rows evenly spread, no glyph) but with an adaptive row count;
-- all SMLSIZE except the %/V row, which scales to the row height (the whole zone when
-- it's the only row). Rows kept by priority as height allows: %/V, header, the
-- REMAINING/V-cell labels, then mAh values and of-X/CONSUMED (which drop first).
local function drawConnectedSmall(w, h, m)
  local pad     = sx(4)   -- match FULL/MEDIUM/ENDED edge inset (consistent header)
  local gap     = 2
  local _, smlH = lcd.sizeText("0", SMLSIZE)
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
  local bigRef    = (lcd.sizeText(pctS, SMLSIZE) >= lcd.sizeText(vS, SMLSIZE)) and pctS or vS
  local bigFlag   = pickFont(bigRef, colW, math.min(smlH + extra, 2 * smlH))
  local _, bigH   = lcd.sizeText(bigRef, bigFlag)

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

-- Blinking red "receiving" dot in the top-right corner: shown while the link is
-- up, toggling at 0.5 Hz so the pilot can see fresh telemetry is arriving (and
-- that the script is running). It stops the instant packets stop (isOnline → false).
local HEARTBEAT_HALF = 100  -- 1 s on / 1 s off → 0.5 Hz (getTime units, 1/100 s)
local function drawHeartbeat(ctx)
  if not core.isOnline(ctx) then return end
  if math.floor(getTime() / HEARTBEAT_HALF) % 2 ~= 0 then return end
  local r = sx(3)
  lcd.drawFilledCircle(ctx.zone.w - sx(4) - r, sx(4) + r, r, CRIT_COL)
end

-- True when the FULL two-column layout fits the zone. Both checks are in absolute
-- pixels because the fonts do NOT scale with S (only positions do): each column
-- must be wide enough for its longest fixed (SMLSIZE) line, and the zone tall
-- enough for header + a MIDSIZE big number + the three sub-rows. Measuring the
-- real font metrics makes this self-tuning across screen sizes (a quarter page is
-- wider in pixels on an 800 px screen than a 480 px one) instead of a magic constant.
local function connectedFitsFull(w, h)
  if fullColumns(w) < minColW() - TIER_TOL then return false end   -- same px slack as the height check
  local pad     = sx(4)
  local _, hdrH = lcd.sizeText("0", SMLSIZE)
  local _, bigH = lcd.sizeText("0", MIDSIZE)
  local _, smlH = lcd.sizeText("0", SMLSIZE)
  local _, valH = lcd.sizeText("0", 0)   -- value row uses the default font
  -- Mirror drawMetricBlock's uniform-gap stack: header, big number, caption, value,
  -- sub-line — each gap METRIC_GAP, each row at its real height (smlH/valH/MIDSIZE).
  local needH   = pad + hdrH + METRIC_GAP + bigH + METRIC_GAP + smlH + METRIC_GAP + valH + METRIC_GAP + smlH + pad
  return h >= needH - TIER_TOL
end

-- Picks the tier by what fits the zone. FULL is used whenever its content fits;
-- the bar's WARN/CRIT labels and the time-left block degrade on their own inside
-- FULL when the height is tight, so a quarter page shows the same layout as a
-- full page, just with smaller fonts. Shorter/narrower zones fall back to the
-- compact MEDIUM/SMALL tiers.
local function drawConnectedTile(ctx)
  local w, h = ctx.zone.w, ctx.zone.h
  local m    = connectedMetrics(ctx)
  -- MID only when its 5 SMLSIZE rows fit (pad=2, min pitch smlH-4); else SMALL.
  -- Constants must match drawConnectedMedium / drawConnectedSmall.
  local _, smlH    = lcd.sizeText("0", SMLSIZE)
  local fiveRowMin = 2 * 2 + smlH + 4 * (smlH - 4)
  if connectedFitsFull(w, h) then
    drawConnectedFull(w, h, m)
  elseif h >= fiveRowMin - TIER_TOL then
    drawConnectedMedium(w, h, m)
  else
    drawConnectedSmall(w, h, m)
  end
end

-- Message fonts, largest first: the default (STD) font when the lines fit, else
-- SMLSIZE. Two discrete steps only, so the per-line height stays predictable.
local MSG_FONT_STEPS = { 0, SMLSIZE }

-- Fixed line height for a message font: its text height plus a small gap.
local function msgLineH(flag)
  local _, th = lcd.sizeText("0", flag)
  return th + sx(2)
end

-- Largest MSG_FONT_STEPS flag whose `lines` fit `availW` wide AND `availH` tall;
-- falls back to SMLSIZE. Returns the flag and its line height.
local function pickMsgFont(lines, availW, availH)
  for _, flag in ipairs(MSG_FONT_STEPS) do
    local lineH = msgLineH(flag)
    local fits  = #lines * lineH <= availH
    for _, t in ipairs(lines) do
      if lcd.sizeText(t, flag) > availW then fits = false break end
    end
    if fits then return flag, lineH end
  end
  return SMLSIZE, msgLineH(SMLSIZE)
end

-- Renders a list of strings as horizontally-centered lines, vertically centred in
-- the area BELOW `topY` so a reserved header band isn't overlapped. Clamped: on a
-- zone too short the text starts at topY rather than above it. `flag`/`lineH` set
-- the (fixed) font. Used by the error / informational tiles.
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

-- Status line with 0–3 trailing dots that build up slowly. The base text depends on
-- the link: "No Battery connected" while waiting for telemetry, "Calculate" once the
-- link is up and we're settling. The line is centred as if all three dots were
-- present and the dots are drawn left-fixed after the base text, so the base never
-- jitters as the dots appear.
local WAIT_BASE     = "No Battery connected"
local SETTLE_BASE   = "Calculating"
local USB_BASE      = "USB connected"
local DOT_INTERVAL  = 50   -- getTime units (1/100 s) per dot → ~2 s full cycle
local function drawWaitingStatus(cx, y, base)
  local n      = math.floor(getTime() / DOT_INTERVAL) % 4   -- 0..3
  local baseW  = lcd.sizeText(base, SMLSIZE)
  local fullW  = lcd.sizeText(base .. "...", SMLSIZE)
  local startX = cx - math.floor(fullW / 2)
  dtext(startX, y, base, COLORS.muted, SMLSIZE)
  if n > 0 then dtext(startX + baseW, y, string.rep(".", n), COLORS.muted, SMLSIZE) end
end

-- WAITING tile: a small branding splash — "LIPO-NANNY" in accent and the status
-- line. Shown for every idle/waiting state (true WAITING, the post-connect settle
-- window, the popup/flight-end timeouts). Degrades on short zones to a single
-- centered status line.
-- Title font sized to this fixed-width anchor instead of the shorter own title,
-- so the splash matches a same-sized neighbouring splash. Widen/narrow the count
-- to shrink/grow the title by a font step.
local TITLE_SIZE_REF = string.rep("M", 8)

local function drawWaitingTile(ctx)
  local w, h   = ctx.zone.w, ctx.zone.h
  local pad    = sx(4)
  local title  = "LIPO-NANNY"
  local cx     = math.floor(w / 2)
  -- "USB connected" when the link is up but no battery; "Calculating" while
  -- genuinely online and settling; else "No Battery connected". The isOnline guard
  -- stops a dropped link from lingering on "Calculating" through the ENDED grace.
  local base
  if core.isUsbConnected(ctx) then
    base = USB_BASE
  elseif ctx.state == core.STATE_CONNECTED and core.isOnline(ctx) then
    base = SETTLE_BASE
  else
    base = WAIT_BASE
  end

  -- Fit the anchor width, then render one font step smaller.
  local titleFlag = smallerFont(pickFont(TITLE_SIZE_REF, w * 0.95, math.floor(h * 0.5)))
  local _, titleH = lcd.sizeText(title, titleFlag)
  local _, subH = lcd.sizeText(base, SMLSIZE)
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

-- ENDED tile: summary of the just-finished flight. All SMLSIZE, top-down with a
-- fixed row pitch (smlH + sx(3), same as the battery-selection list). Rows drop by
-- priority when the height runs out (kept longest → dropped first): header, Used,
-- cycles, Last, then "Flight ended" (decorative), which drops first.
local function drawEndedTile(ctx)
  local pad     = sx(4)
  local h       = ctx.zone.h
  local lf      = ctx.lastFlight or {}
  local label   = formatBatteryLabel(lf.profileName, lf.instances)
  local _, smlH = lcd.sizeText("0", SMLSIZE)
  local rowH    = smlH + sx(3)

  -- Used X mAh (Y%) — Y% includes the start offset.
  local usedText
  if lf.usedMah then
    local pctStr = ""
    if lf.effectiveCap and lf.effectiveCap > 0 then
      local effectiveUsed = lf.usedMah + (lf.startOffsetMah or 0)
      local pct = math.floor(effectiveUsed / lf.effectiveCap * 100 + 0.5)
      pctStr = string.format(" (%d %%)", pct)
    end
    usedText = string.format("Used %d mAh%s", lf.usedMah, pctStr)
  else
    usedText = "Used --"
  end

  local lastText
  if lf.lastVoltagePerCell then
    lastText = string.format("Last: %.2f V/cell", lf.lastVoltagePerCell)
  else
    lastText = "Last: --.- V/cell"
  end

  -- Total cycles of the flown pack(s). finalizeFlight already added this flight's +1
  -- to the config, so just read the stored count. Parallel shows both, e.g. "(16, 8)".
  local cyclesStr = "--"
  if lf.instances and #lf.instances > 0 then
    local parts = {}
    for _, inst in ipairs(lf.instances) do
      parts[#parts + 1] = tostring(core.cyclesFor(ctx, inst.id))
    end
    cyclesStr = table.concat(parts, ", ")
  end

  local nRows = math.floor((h - 2 * pad - smlH) / rowH) + 1
  if nRows < 1 then nRows = 1 end
  if nRows > 5 then nRows = 5 end

  -- Candidates in PRIORITY order; `ord` is the on-screen position (top = 1).
  -- "Flight ended" (ord 2) is decorative and drops first.
  local cand = {
    { ord = 1, draw = function(y) drawHeaderLabel(pad, y, label) end },
    { ord = 3, draw = function(y) dtext(pad, y, usedText, COLORS.fg, SMLSIZE) end },
    { ord = 5, draw = function(y) dtext(pad, y, "Total pack cycles (" .. cyclesStr .. ")", COLORS.muted, SMLSIZE) end },
    { ord = 4, draw = function(y) dtext(pad, y, lastText, COLORS.muted, SMLSIZE) end },
    { ord = 2, draw = function(y) dtext(pad, y, "Flight ended", BRAND, SMLSIZE) end },
  }
  local rows = {}
  for i = 1, nRows do rows[i] = cand[i] end
  table.sort(rows, function(a, b) return a.ord < b.ord end)

  local y = pad
  for i = 1, #rows do
    rows[i].draw(y)
    y = y + rowH
  end
end


-- Stick-gesture control for the selection popup, polled every tick — works in the
-- normal tile without fullscreen, unlike key events. Elevator up/down moves the
-- cursor (one step per deflection, re-armed in the dead-zone); aileron held full-
-- right with elevator centred commits. Flip the signs if a direction feels inverted.
local function pollSelectionSticks(ctx)
  if not ctx.pendingSelection then return end

  -- Resolve any slot that has a single candidate before reading the sticks.
  if ctx.parallel and core.autoSelectSlot(ctx) then return end

  local list = core.activeSelectionList(ctx)
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
      core.commitSlot(ctx, list[cursor])
    end
  else
    ctx.confirmSince = nil          -- released or elevator moved → reset hold timer
  end
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

  local firstRow = pad + TH
  local _, smlH  = lcd.sizeText("0", SMLSIZE)
  local legendY  = h - pad - smlH          -- bottom line reserved for the SMLSIZE legend

  local list = core.activeSelectionList(ctx)
  if #list == 0 then
    dtext(pad, firstRow, "No profiles", COLORS.fg, SMLSIZE)
    return
  end

  -- Rows in the small font so more entries fit and long names plus the "(Nc)"
  -- cycle count aren't clipped.
  local availW  = w - 2 * pad
  local _, rowTextH = lcd.sizeText("0", SMLSIZE)
  local rowH = rowTextH + sx(3)

  local cursor  = ctx.popupCursor or 1
  -- Drop the legend when keeping it would leave room for only one battery row; that
  -- space then goes to the list instead.
  local showLegend = math.floor((legendY - firstRow) / rowH) >= 2
  local listBottom = showLegend and legendY or (h - pad)
  local maxRows    = math.max(1, math.floor((listBottom - firstRow) / rowH))

  -- Scrolling window: keep the cursor centred so neighbouring entries stay
  -- visible (you can always tell there are more), the list scrolls underneath.
  -- Clamped at both ends so no blank rows appear.
  local half  = math.floor((maxRows - 1) / 2)
  local start = cursor - half
  if start > #list - maxRows + 1 then start = #list - maxRows + 1 end
  if start < 1 then start = 1 end
  local last = math.min(#list, start + maxRows - 1)

  -- Confirm-hold progress (0..1): non-zero only during an active hold
  -- (pollSelectionSticks sets/clears ctx.confirmSince on hold/release).
  local confirmProgress = 0
  if ctx.confirmSince then
    confirmProgress = (getTime() - ctx.confirmSince) / CONFIRM_HOLD
    if confirmProgress > 1 then confirmProgress = 1 end
  end

  local y = firstRow
  for i = start, last do
    -- Hold-to-confirm fill: a translucent brand-coloured bar grows left→right behind
    -- the cursor row as the aileron is held, completing when the commit fires. Drawn
    -- in BRAND so it matches the recoloured cursor text; the solid text over it stays
    -- readable thanks to the reduced opacity.
    if i == cursor and confirmProgress > 0 then
      lcd.drawFilledRectangle(pad, y, math.floor(availW * confirmProgress), rowH - sx(1), BRAND, CONFIRM_FILL_OPACITY)
    end
    local item   = list[i]
    local row    = formatBatteryLabel(item.profile.name, { { pos = item.pos } })
                   .. " (" .. (item.cycles or 0) .. "c)"
    local prefix = (i == cursor) and "> " or "  "
    dtext(pad, y, prefix .. row, (i == cursor) and BRAND or COLORS.fg, SMLSIZE)
    y = y + rowH
  end

  -- Gesture legend. ASCII only — the EdgeTX font has no arrow glyphs. Dropped on very
  -- short zones (see showLegend) so a battery row keeps priority.
  if showLegend then
    dtext(pad, legendY, "ele: up/dn  ail: hold >", COLORS.muted, SMLSIZE)
  end
end

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
  dtext(pad, pad, "LIPO-NANNY", BRAND, SMLSIZE)
  local hw, hh = lcd.sizeText("LIPO-NANNY", SMLSIZE)
  drawMascotEyes(pad + hw + sx(6), pad, sx(20), math.max(hh, sx(14)))
end

-- Height of the brand-heading band (top pad + the taller of text / mascot-eye
-- height), so callers can reserve it before centring text beneath.
local function headerBandH()
  local _, hh = lcd.sizeText("LIPO-NANNY", SMLSIZE)
  return sx(4) + math.max(hh, sx(14)) + sx(2)
end

-- Trims `lines` to at most `maxLines`, keeping the first line (the problem) and
-- then filling from the END backward (the action hint), so a 3-line message on a
-- 2-line zone keeps "what's wrong" + "what to do" and drops the middle context
-- (e.g. the model name). Order is preserved; always returns at least one line.
local function fitLines(lines, maxLines)
  if #lines <= maxLines then return lines end
  if maxLines <= 1 then return { lines[1] } end
  local keep = { lines[1] }
  for i = #lines - (maxLines - 1) + 1, #lines do keep[#keep + 1] = lines[i] end
  return keep
end

-- Brand heading with centred message lines below it. Reserves the header band so
-- the text never rides up into it; on a zone too short for both header and text
-- (even at the SMLSIZE floor), the heading is dropped and the message gets the
-- full zone. The message font scales between SMLSIZE and STD with the free space.
-- On a zone too short even for every message line, trailing context is dropped
-- (problem + action kept) so the essentials never spill off the tile.
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

local function create(zone, options)
  -- Logic state lives on the core context; the widget owns only its display zone,
  -- options and the tick throttle / error-recovery counters. With core missing we
  -- still return a usable ctx so refresh()/drawTile() can render the error tile.
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
  -- Called when the pilot changes the widget settings.
  ctx.cfg = options
end

-- One data-processing cycle (no lcd.*). Bails out early on a config error or a
-- missing required sensor so it never computes on absent values.
local function tickImpl(ctx)
  core.pollConfig(ctx)
  if ctx.configError then return end
  core.checkSensors(ctx)
  if not ctx.hasRxBt or not ctx.hasCapa then return end  -- required sensors absent
  core.readTelemetry(ctx)
  core.updateStateMachine(ctx)
  if ctx.state == core.STATE_CONNECTED then
    core.detectBattery(ctx)        -- auto-select for 1 candidate; else sets pendingSelection
    pollSelectionSticks(ctx)  -- stick navigation while a selection popup is open
    core.evaluateWarnings(ctx)
    core.refreshTimeLeft(ctx)      -- snapshot the displayed time-left every 2 s
  end
end

-- Throttled, fault-tolerant wrapper. Called from BOTH background() and refresh():
-- EdgeTX only runs background() while the widget is off-screen, so refresh() must
-- drive it too or the visible tile freezes until a menu round-trip. Throttled to
-- TICK_INTERVAL (10 Hz) so the sample cadence is the same regardless of caller
-- (refresh ~20 Hz). tickImpl runs inside pcall: repeated failures flip the
-- widget into a terminal error state rather than crashing EdgeTX.
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
  -- core.lua not installed / broken: same error-tile UI as every other problem.
  if not core then
    drawErrorTile(ctx, "core.lua missing", "Install on SD card")
    return
  end

  -- Terminal error first — once set, nothing else is trustworthy.
  if ctx.fatalError then
    drawErrorTile(ctx, "Widget error", "Re-add or restart")
    return
  end

  -- Config / model setup problems.
  if ctx.configError == "missing" then
    drawErrorTile(ctx, "Setup required", "Open Tools/Lipo Nanny")
    return
  end
  if ctx.configError == "parse" or ctx.configError == "schema" then
    drawErrorTile(ctx, "Config invalid", "Open Tools/Lipo Nanny")
    return
  end
  if ctx.modelError == "missing" then
    drawHeadedMessage(ctx, {
      "Model not configured",
      '"' .. (core.activeModelName() or core.modelFilename() or "?") .. '"',
      "Open Tools/Lipo Nanny",
    })
    return
  end
  if ctx.modelError == "no_batteries" then
    drawErrorTile(ctx, "No batteries assigned", "Open Tools/Lipo Nanny")
    return
  end

  -- Telemetry setup problems.
  if not ctx.hasRxBt or not ctx.hasCapa then
    drawErrorTile(ctx, "Sensor missing", "Discover in EdgeTX")
    return
  end
  if ctx.cellMismatch then
    drawErrorTile(ctx, "Cell count mismatch", "Open Tools/Lipo Nanny")
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
  if ctx.state == core.STATE_WAITING then
    drawWaitingTile(ctx)
  elseif ctx.state == core.STATE_CONNECTED then
    -- Settle window: no resting voltage / battery yet. Reuse the waiting tile instead
    -- of a CONNECTED tile full of "--" (cellMismatch + popup are handled above, so a
    -- nil profile here always means "still settling"). Heartbeat still shows the link.
    if ctx.selectedProfile then
      drawConnectedTile(ctx)
    else
      drawWaitingTile(ctx)
    end
    drawHeartbeat(ctx)
  elseif ctx.state == core.STATE_ENDED then
    drawEndedTile(ctx)
  end
end

local function refresh(ctx, event, touchEvent)
  tick(ctx)  -- Drive logic in the foreground too (background() won't run then; see tick()).

  -- Pick the palette for this frame from the "Theme" CHOICE option (1-based: Dark = 1,
  -- Light = 2). refresh() is the only draw path and runs one instance at a time, so the
  -- module-global palette is safe. Anything but 2 (incl. unset) falls back to Dark.
  COLORS = (ctx.cfg and ctx.cfg.Theme == 2) and LIGHT or DARK

  -- Brand/heading colour for this frame (after the palette so the "Default" fallback
  -- picks up the active palette's accent). State colours stay on COLORS.accent.
  BRAND = brandColor(ctx.cfg and ctx.cfg.Accent, ctx.cfg and ctx.cfg.AccentColor)

  -- DARK paints its own panel so the tile looks the same on any radio theme; LIGHT
  -- leaves the background transparent so the radio theme shows through.
  if not COLORS.transparent then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLORS.panel)
  end

  -- Optional milky overlay (Light theme only): pilot sets 0–5, ×3 → alpha 0..15
  -- (0 = invisible). Drawn in a theme colour over the transparent Light background.
  local trans = ctx.cfg and ctx.cfg.Transparency or 0
  if COLORS.transparent and trans > 0 then
    pcall(lcd.drawFilledRectangle, 0, 0, ctx.zone.w, ctx.zone.h, COLOR_THEME_PRIMARY2, 3 * trans)
  end

  pcall(drawTile, ctx)
end

return {
  name       = "Lipo Nanny",
  options    = {
    -- Theme dropdown (CHOICE labels are a nested table; the value is the 1-based
    -- index, so default 1 = "Dark"; needs EdgeTX 2.11+). Transparency = milky overlay
    -- 0–5 (default 2), applied in the Light theme only (Dark stays solid black).
    { "Theme", CHOICE, 1, { "Dark", "Light" } },
    { "Transparency", VALUE, 2, 0, 5 },
    -- Brand/heading colour. Accent: 1 Default (per-palette green), 2 Theme
    -- (COLOR_THEME_FOCUS), 3 Custom (AccentColor). AccentColor shows the native colour
    -- picker; only used when Accent = Custom, default = the original Dark lime.
    { "Accent", CHOICE, 1, { "Default", "Theme", "Custom" } },
    { "AccentColor", COLOR, lcd.RGB(124, 210, 48) },
  },
  create     = create,
  update     = update,
  background = background,
  refresh    = refresh,
}
