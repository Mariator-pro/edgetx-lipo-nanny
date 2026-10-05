-- =====================================================================
-- manifest.lua  --  Lipo Nanny as seen by the Flight Bag settings tool
-- =====================================================================
-- SD card path: /SCRIPTS/LIPONY/manifest.lua
-- Loaded only by the settings tool. Labels and hints live here; ranges,
-- defaults, sound slots and the config file live in core.lua.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(core)
  local L, D = core.LIMITS, core.DEFAULTS
  return {
    name  = "Lipo Nanny",
    url   = "github.com/Mariator-pro/edgetx-lipo-nanny",
    paths = {
      { "Core",   "/SCRIPTS/LIPONY/core.lua" },
      { "Config", core.CONFIG_PATH },
      { "Widget", "/WIDGETS/LIPONY/main.lua" },
      { "Sounds", core.SOUND_DIR },
    },

    fields = {
      { key = "warnPct", page = "warnings", label = "Low",
        min = L.warnPct.min, max = L.warnPct.max, step = L.warnPct.step,
        default = D.warnPct, unit = "%",
        hint = "Warn below %v left (battery profiles can override)" },
      { key = "critPct", page = "warnings", label = "Critical",
        min = L.critPct.min, max = L.critPct.max, step = L.critPct.step,
        default = D.critPct, unit = "%",
        hint = "Critical alert below %v left" },
      { key = "audio", page = "alerts", label = "Sounds", shared = true,
        type = "bool", default = D.audio, hint = "Off silences every announcement, vibration stays" },
      { key = "haptic", page = "alerts", label = "Vibration", shared = true,
        type = "bool", default = D.haptic },
      { key = "hapticStrength", page = "alerts", label = "Strength", shared = true,
        type = "choice", choices = { 1, 2, 3 }, labels = { "Soft", "Normal", "Strong" },
        default = D.hapticStrength },
    },

    -- Rows on the Alerts page, in core.SOUND_KEYS order
    sounds = {
      warn = { label = "Low",      hint = "Battery at the Low threshold" },
      crit = { label = "Critical", hint = "Battery at the Critical threshold" },
    },

    check = function(v)
      if v.warnPct <= v.critPct then return "Low must be above Critical" end
    end,

    resets = {
      { label = "Reset settings", ask = "Reset warnings and sounds to factory defaults? No data is lost.",
        run = core.resetSettings },
      { label = "Reset stats", ask = "Reset all statistics? Cycle counts, life mAh, Vmin and the archive are erased. Batteries and models stay.",
        run = core.resetStats },
      { label = "Factory reset", ask = "Factory reset? All batteries, models, statistics and settings are erased.",
        run = core.factoryReset },
    },
  }
end
