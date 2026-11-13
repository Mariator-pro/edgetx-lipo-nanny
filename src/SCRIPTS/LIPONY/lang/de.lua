-- =====================================================================
-- lang/de.lua  --  German texts of Lipo Nanny in the Flight Bag tool
-- =====================================================================
-- SD card path: /SCRIPTS/LIPONY/lang/de.lua
-- Same areas and ids as lang/en.lua; a text missing here is shown in
-- English. {name} is a placeholder. Plain quotes and dots only: the
-- radio's font has no typographic ones.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return {
  fields = {
    warnPct        = { label = "Akku niedrig", hint = "Warnung, wenn weniger als {v} Kapazität übrig sind" },
    critPct        = { label = "Akku kritisch", hint = "Kritische Warnung, wenn weniger als {v} Kapazität übrig sind" },
    audio          = { label = "Töne", hint = "Aus schaltet alle Ansagen stumm, die Vibration bleibt" },
    haptic         = { label = "Vibration" },
    hapticStrength = { label = "Stärke", choices = { "Schwach", "Normal", "Stark" } },
    flightTime     = { label = "Flugzeit", hint = "Zeit neben dem Akku-% im Flug",
                       choices = { timer = "EdgeTX-Timer 1", timeleft = "Restzeit-Timer" } },
    language       = { label = "Sprache", hint = "Sprache von Flight Bag" },
  },
  sounds = {
    warn   = { label = "Akku niedrig", hint = 'Bei der Schwelle "Akku niedrig"' },
    crit   = { label = "Akku kritisch", hint = 'Bei der Schwelle "Akku kritisch"' },
    charge = { label = "Akku nicht geladen", hint = 'Pack beim Anstecken schon unter "Akku niedrig"' },
  },
  resets = {
    settings = { label = "Einstellungen zurücksetzen",
                 ask = "Einstellungen von Lipo Nanny zurücksetzen? Akkus, Modelle und Statistiken bleiben.",
                 desc = "Warnungen und Warntöne bekommen wieder ihre Vorgaben. Akkus, Modelle und Statistiken bleiben, ebenso die Einstellungen für alle Apps (Töne, Vibration, Flugzeit, Sprache)." },
    stats    = { label = "Statistiken löschen",
                 ask = "Statistiken von Lipo Nanny löschen? Zyklen, mAh gesamt, Vmin, Zuletzt genutzt und das Archiv werden gelöscht. Akkus und Modelle bleiben.",
                 desc = 'Zyklen, verbrauchte mAh gesamt, niedrigste Zellspannung, "zuletzt genutzt" und das Archiv werden gelöscht. Akkus und Modelle bleiben.' },
    factory  = { label = "Alles löschen",
                 ask = "Alles in Lipo Nanny löschen? Akkus, Modelle und Statistiken werden gelöscht, die Einstellungen zurückgesetzt.",
                 desc = "Alle Akkus, Modelle, Statistiken und das Archiv werden gelöscht, die Einstellungen bekommen ihre Vorgaben. Die Einstellungen für alle Apps (Töne, Vibration, Flugzeit, Sprache) bleiben." },
  },
  setup = {
    noConfig       = "Noch keine Einstellungsdatei",
    damaged        = "Einstellungsdatei beschädigt",
    modelNotSetUp  = "Modell nicht eingerichtet",
    noBatteries    = "Diesem Modell ist kein Akku zugeordnet",
    noCellMatch    = "Kein zugeordneter Akku hat {cells} Zellen",
    missingSensors = "Sensoren fehlen: {sensors}",
    checkSensors   = "Sensoren des Modells prüfen",
  },
  rules = {
    lowAboveCritical = '"Akku niedrig" muss über "Akku kritisch" liegen',
  },
  files = { core = "Core", config = "Einstellungen", widget = "Widget", sounds = "Töne" },
}
