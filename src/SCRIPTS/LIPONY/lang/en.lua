-- =====================================================================
-- lang/en.lua  --  English texts of Lipo Nanny in the Flight Bag tool
-- =====================================================================
-- SD card path: /SCRIPTS/LIPONY/lang/en.lua
-- Every text by area and id; the complete set and the fallback of the
-- other languages. {name} is a placeholder. Plain quotes and dots only:
-- the radio's font has no typographic ones.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return {
  fields = {
    warnPct        = { label = "Battery low", hint = "Warning when less than {v} capacity is left" },
    critPct        = { label = "Battery critical", hint = "Critical warning when less than {v} capacity is left" },
    audio          = { label = "Sounds", hint = "Off silences every announcement, vibration stays" },
    haptic         = { label = "Vibration" },
    hapticStrength = { label = "Strength", choices = { "Soft", "Normal", "Strong" } },
    flightTime     = { label = "Flight time", hint = "Time shown beside the battery % in flight",
                       choices = { timer = "EdgeTX Timer 1", timeleft = "Remaining Timer" } },
    language       = { label = "Language", hint = "Language of Flight Bag",
                       choices = { en = "English", de = "Deutsch" } },
  },
  sounds = {
    warn   = { label = "Battery low", hint = "At the Battery low threshold" },
    crit   = { label = "Battery critical", hint = "At the Battery critical threshold" },
    charge = { label = "Battery not charged", hint = "Pack already below Battery low when plugged in" },
  },
  resets = {
    settings = { label = "Reset settings", ask = "Reset Lipo Nanny's settings? Batteries, models and statistics stay.",
                 desc = "Warnings and alert sounds go back to their defaults. Batteries, models and statistics stay, and so do the settings for all apps (Sounds, Vibration, Flight time, Language)." },
    stats    = { label = "Clear statistics",
                 ask = "Clear Lipo Nanny's statistics? Cycle counts, Life mAh, Vmin, Last used and the archive are erased. Batteries and models stay.",
                 desc = "Cycle counts, total mAh used, lowest cell voltage, last used and the archive are erased. Batteries and models stay." },
    factory  = { label = "Erase everything",
                 ask = "Erase everything in Lipo Nanny? Batteries, models and statistics are erased, settings are reset.",
                 desc = "All batteries, models, statistics and the archive are erased, and the settings go back to their defaults. The settings for all apps (Sounds, Vibration, Flight time, Language) stay." },
  },
  setup = {
    noConfig       = "No settings file yet",
    damaged        = "Settings file damaged",
    modelNotSetUp  = "Model not set up",
    noBatteries    = "No batteries assigned to this model",
    noCellMatch    = "No assigned battery has {cells} cells",
    missingSensors = "Missing sensors: {sensors}",
    checkSensors   = "Check sensors config",
  },
  rules = {
    lowAboveCritical = "Battery low must be above Battery critical",
  },
  files = { core = "Core", config = "Config", widget = "Widget", sounds = "Sounds" },
}
