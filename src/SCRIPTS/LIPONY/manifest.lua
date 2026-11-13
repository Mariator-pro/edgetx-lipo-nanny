-- =====================================================================
-- manifest.lua  --  Lipo Nanny as seen by the Flight Bag settings tool
-- =====================================================================
-- SD card path: /SCRIPTS/LIPONY/manifest.lua
-- Loaded only by the settings tool. Fields, sounds, resets, rules and files
-- by id; their texts come from lang/<code>.lua (lang: "en" when left out).
-- Ranges, defaults, choices, sound slots and the config file live in core.lua.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
-- =====================================================================

return function(core, lang)
  local L, D = core.LIMITS, core.DEFAULTS
  local T = core.texts(lang)
  local man = {
    name    = "Lipo Nanny",
    author  = "Mariator-pro",
    license = "GPL-2.0",
    url     = "github.com/Mariator-pro/edgetx-lipo-nanny",
    -- ids never change once released: other programs recognise an entry by it
    paths = {
      { id = "core",   path = "/SCRIPTS/LIPONY/core.lua" },
      { id = "config", path = core.CONFIG_PATH },
      { id = "widget", path = "/WIDGETS/LIPONY/main.lua" },
      { id = "sounds", path = core.SOUND_DIR },
    },

    fields = {
      { key = "warnPct", page = "warnings",
        min = L.warnPct.min, max = L.warnPct.max, step = L.warnPct.step,
        default = D.warnPct, unit = "%" },
      { key = "critPct", page = "warnings",
        min = L.critPct.min, max = L.critPct.max, step = L.critPct.step,
        default = D.critPct, unit = "%" },
      { key = "audio", page = "alerts", shared = true, type = "bool", default = D.audio },
      { key = "haptic", page = "alerts", shared = true, type = "bool", default = D.haptic },
      { key = "hapticStrength", page = "alerts", shared = true,
        type = "choice", choices = { 1, 2, 3 }, default = D.hapticStrength },
      { key = "flightTime", page = "display", shared = true, type = "choice",
        choices = core.FLIGHT_TIMES, default = D.flightTime },
      { key = "language", page = "display", shared = true,
        type = "choice", choices = core.LANGUAGES, default = D.language },
    },

    -- Rows on the Alerts page, in core.SOUND_KEYS order
    sounds = {},

    resets = {
      { id = "settings", run = core.resetSettings },
      { id = "stats",    run = core.resetStats },
      { id = "factory",  run = core.factoryReset },
    },
  }

  -- The rule the values `v` break, as { id = ... }, or nil.
  function man.rule(v)
    if v.warnPct <= v.critPct then return { id = "lowAboveCritical" } end
  end
  -- The same as a sentence.
  function man.check(v)
    local r = man.rule(v)
    return r and core.fillText(T("rules", r.id) or r.id, r) or nil
  end

  -- The texts, in the shape the settings tool reads: a file as { label, path },
  -- a field's label, hint (%v: its value) and labels of its choices.
  for _, p in ipairs(man.paths) do p[1], p[2] = T("files", p.id) or p.id, p.path end
  for _, f in ipairs(man.fields) do
    f.label = T("fields", f.key, "label") or f.key
    local hint = T("fields", f.key, "hint")
    if hint then f.hint = string.gsub(hint, "{v}", "%%v") end
    if f.choices then
      f.labels = {}
      for i, c in ipairs(f.choices) do f.labels[i] = T("fields", f.key, "choices", c) or tostring(c) end
    end
  end
  for _, key in ipairs(core.SOUND_KEYS) do
    man.sounds[key] = { label = T("sounds", key, "label") or key, hint = T("sounds", key, "hint") }
  end
  for _, r in ipairs(man.resets) do
    r.label = T("resets", r.id, "label") or r.id
    r.ask, r.desc = T("resets", r.id, "ask"), T("resets", r.id, "desc")
  end
  return man
end
