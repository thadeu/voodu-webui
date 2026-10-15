# 05 — HEP3 call-flow link + alerts

Status: ready-for-agent
Blocked by: 02, 03

## Scope

- Calls table row action "SIP flow" → existing `Hep3::CallFlowModal` by
  Call-ID; shown only when hep3 is also installed on that server.
- Alerts on the warehouse series: gateway DOWN, registrations drop, ESL
  unreachable for N minutes. Reuse the alerts evaluation jobs.

## Open questions

- Is the FreeSWITCH call UUID or the SIP Call-ID the join key with HEP3
  messages? (`show calls as json` has both legs' UUIDs; HEP3 indexes
  `call_id`.)

## Comments

2026-10-15 — Partly done (voodu-webui, uncommitted at the time of writing):
- HEP3 link: each live leg has a SIP-flow button; the Call-ID comes from voodu-fswapi v0.1.3
  `GET /channels/{uuid}/sip_call_id` (asked on click only). Join key answered: the leg's SIP Call-ID,
  folded by x_cid in HEP3.
- Alerts A + B: kinds fs_down (sync records fs_up 0 on a 502), fs_calls ≥ N, fs_idle_cpu ≤ X%.
- LEFT: alert C — gateway DOWN (sync would also read /sofia every 15s and store a count).
