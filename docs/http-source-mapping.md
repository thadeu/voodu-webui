# External HTTP data source — mapping contract

A dashboard panel can be fed by an HTTP request to **any external API** instead of a
local source (logs/metrics/HEP3). You give it a URL, and a small JSON **mapping** that
tells voodu where to find your data in the response. The same panel type renders either
a **Table** or a **Chart** (Area / Number) depending on the mapping shape.

There is **no fixed response schema** — the mapping adapts to whatever your API returns.
The contract is only: *return JSON with an array somewhere; each element has the fields
the mapping points at.*

- Backend: [`DataTable::HttpSource`](../app/services/data_table/http_source.rb) (fetch +
  map), [`DataTable::HttpFetch`](../app/services/data_table/http_fetch.rb) (outbound
  request), [`JsonMap`](../app/services/json_map.rb) (dependency-free path resolver).
- Config (URL / headers / body / mapping) lives in the **panel JSON**, resolved
  server-side — the browser never carries the URL or auth headers.

## The Test loop

In the panel builder, hit **Test**. It fires the request server-side and shows the raw
**Response** next to the **Parsed** output, so you discover the shape and confirm the
mapping resolves *before* saving. Select the **Table** or **Area / Number** card first —
Test maps against whichever you picked.

---

## Table mapping

An array of objects with arbitrary fields; each `column` names a display `field` and the
dot-`path` to pull from each item.

```json
{
  "root": "items",
  "columns": [
    { "field": "ID",    "path": "id" },
    { "field": "Title", "path": "title" },
    { "field": "Done",  "path": "completed" }
  ]
}
```

matches:

```json
{ "items": [ { "id": 1, "title": "foo", "completed": false } ] }
```

- **`root`** — dot-path to the array (blank `""` = the response **is** the array).
- **`columns[].field`** — the column header (yours to name).
- **`columns[].path`** — dot-path into each item; nested + indexed access works
  (`user.name`, `items[0].id`).

---

## Chart mapping (Area / Number)

An array of time-series points; each has a timestamp and a numeric value.

```json
{ "root": "series", "ts": "t", "value": "v" }
```

matches:

```json
{
  "series": [
    { "t": "2026-07-02T15:00:00Z", "v": 12 },
    { "t": "2026-07-02T15:01:00Z", "v": 18 }
  ]
}
```

- **`root`** — dot-path to the array (blank `""` = the response is the array).
- **`ts`** — dot-path (per item) to the timestamp. Accepts **ISO 8601**
  (`"2026-07-02T15:00:00Z"`) **or epoch numeric** (seconds, or milliseconds when
  `> 1e12`). Unparseable → that point is dropped, not fatal.
- **`value`** — dot-path (per item) to a number (numeric strings are coerced). A `null`
  value drops the point.

Points are sorted by `ts`. **Number** panels headline the latest point.

> voodu does **not** bucket or aggregate — it plots exactly the points you return
> (1 → 1 dot, 500 → 500). Your API owns the timeline.

---

## What voodu sends to your API

Every request carries the page's active window as query params so your API can answer for
that range:

```
GET /your-endpoint?from=2026-07-02T14:00:00Z&until=2026-07-02T15:00:00Z&interval=60s&scope=…&label=…
```

| param | meaning |
|-------|---------|
| `from` / `until` | active range, absolute ISO 8601 |
| `interval` | concrete bucket width (e.g. `60s`), never `"auto"` |
| `scope` / `label` | panel context (optional, omitted when blank) |

For a chart, bucket by `interval` between `from` and `until` and return one point per
bucket. Static endpoints ignore these and return fixed data (fine for a Table; a static
list has no `ts`, so it can't drive a Chart).

## Reference endpoint ("just works")

The simplest thing to map (`root:""`, `ts:"ts"`, `value:"value"`):

```jsonc
// GET /metric?from=...&until=...&interval=60s  →
[
  { "ts": "2026-07-02T14:00:00Z", "value": 3 },
  { "ts": "2026-07-02T14:01:00Z", "value": 7 },
  { "ts": "2026-07-02T14:02:00Z", "value": 5 }
]
```

→ mapping `{ "root": "", "ts": "ts", "value": "value" }`.

## Notes & limits

- **Stateless (POC):** the response *is* the render — no warehouse, no history, no paging.
  Refresh re-fires the request.
- **Secrets stay server-side:** auth headers are applied by the backend; the client only
  passes `dashboard` + `panel_key`, and the server re-resolves the config.
- **Safety rails:** 10 s timeout, 5 MiB response cap, forced JSON parse. A failure surfaces
  the reason (timeout / HTTP 5xx / non-JSON) instead of a silent empty panel.
- **gzip:** handled transparently — do **not** set your own `Accept-Encoding`.
- **SSRF:** not yet hardened. Point panels only at trusted, operator-owned targets.
