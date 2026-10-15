# 04 — Actions (reloadxml, reloadacl, hupall, kill call)

Status: ready-for-agent
Blocked by: 02

## Scope

- Show an action only when BOTH:
  1. the server's PAT has the `actions` scope — reuse `ServerPats`
     (`GET /api/pat/v1/pats` answers 403 for a read-only PAT), cached;
  2. the plugin lists the action as enabled (`GET /api/pat/v1/fswapi/actions`).
- Page toolbar: Reload XML, Reload ACL, Hang up all (destructive).
- Calls table: per-row Kill (`POST /calls/{uuid}/kill`, destructive).
- Destructive actions: confirm modal (`Components::UI::Modal`) that names the
  effect ("hangs up N active calls").
- Map answers: 200 → flash ok; 403 → "disabled in the plugin or PAT without
  actions"; 422 → the FreeSWITCH reply; 429 → rate limited; 502 → ESL down.
- Record the action in the WebUI activity/audit trail if one exists for
  operator actions.

## Acceptance

- A read-only PAT never shows an action button.
- Toolbar buttons hide labels on mobile (3+ buttons).
- Tests: gating matrix (scope × enabled), each status mapping.
