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
    settings = { label = "Reset settings", ask = "Reset warnings and sounds to factory defaults? No data is lost.",
                 desc = "Warnings and sounds go back to factory settings. Batteries, models and statistics stay." },
    stats    = { label = "Reset statistics",
                 ask = "Reset all statistics? Cycle counts, Life mAh, Vmin, Last used and the archive are erased. Batteries and models stay.",
                 desc = "Cycle counts, total mAh used, lowest cell voltage, last used and the archive are erased. Batteries and models stay." },
    factory  = { label = "Factory reset",
                 ask = "Reset Lipo Nanny to factory settings? All batteries, models, statistics and settings are erased.",
                 desc = "All batteries, models, statistics and settings are erased." },
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
