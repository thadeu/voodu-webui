# 05 — HEP3 call-flow link + alerts

Status: needs-triage
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
