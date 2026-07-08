import { readJSON, writeJSON } from "./storage"

// panel_prefs — per-viewer, per-panel display preferences for the /metrics grid
// (e.g. "show dots" on a Line chart). Lives in sessionStorage so it survives
// reloads + realtime stream refreshes but stays a browser-local convenience,
// never touching the shared dashboard. Same home + spirit as the Settings
// drawer's visibility/order prefs (voodu:metrics:display).
//
// Shape: { "<panelKey>": { "dots": false, ... } }. Default-valued prefs are
// dropped so the store only holds real overrides.

const STORE_KEY = "voodu:metrics:panel-options"

// panelPref — read one boolean pref for a panel, or `fallback` when unset.
export function panelPref(panelKey, name, fallback) {
  const all   = readJSON(sessionStorage, STORE_KEY, { fallback: {} }) || {}
  const entry = all[panelKey]

  return entry && name in entry ? entry[name] : fallback
}

// setPanelPref — write one pref. Pass `null` to clear it (back to default). An
// emptied panel entry is removed so the store doesn't accrete keys.
export function setPanelPref(panelKey, name, value) {
  const all   = readJSON(sessionStorage, STORE_KEY, { fallback: {} }) || {}
  const entry = { ...(all[panelKey] || {}) }

  if (value === null || value === undefined) delete entry[name]
  else entry[name] = value

  if (Object.keys(entry).length) all[panelKey] = entry
  else delete all[panelKey]

  writeJSON(sessionStorage, STORE_KEY, all)
}
