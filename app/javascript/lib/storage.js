// storage — best-effort JSON persistence over Web Storage. Every browser
// storage call can throw (disabled by the user, private mode, quota full), and
// the value can be malformed, so these NEVER throw: a failed read returns the
// fallback and a failed write is a silent no-op. Callers treat storage as a
// cache / UI-pref convenience, never a source of truth.

// readJSON — read + JSON-parse `key` from `store`. Returns `fallback` (default
// null) on a missing key, malformed JSON, disabled storage, or a failed
// `validate(value)` check.
export function readJSON(store, key, { fallback = null, validate = null } = {}) {
  try {
    const raw = store.getItem(key)

    if (raw == null) return fallback

    const value = JSON.parse(raw)

    if (validate && !validate(value)) return fallback

    return value
  } catch {
    return fallback
  }
}

// writeJSON — JSON-stringify + write `value` to `key`. Swallows quota/disabled
// errors so a full or unavailable store never breaks the feature (it just
// won't persist). Returns whether the write landed.
export function writeJSON(store, key, value) {
  try {
    store.setItem(key, JSON.stringify(value))

    return true
  } catch {
    return false
  }
}
