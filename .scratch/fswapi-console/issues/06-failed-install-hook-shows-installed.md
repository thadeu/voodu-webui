# 06 — A failed install hook still lists the plugin as "installed"

Status: ready-for-agent
Priority: P3
Repo: clowk-voodu
Blocked by: —

## Problem

`Installer#Install` leaves the plugin directory in place when the install
hook fails (on purpose: a manual re-run can finish it). The PAT plugin list
reports any directory as `installed`; the failure only shows for
`pluginJobRetention` (10 min). After that the card says "installed" for a
plugin whose hook never finished.

Seen on fsw02 (controller 0.18.32): voodu-fswapi built its image, stopped at
"controller too old", and the WebUI showed it installed with no pod.

## Proposal

- On hook failure, write `<plugin dir>/.install-error` with the message;
  remove it on a successful install.
- `handlePATPluginList` (and `vd plugins:list`): a plugin with the marker is
  `failed` + its error, for as long as the marker exists.
- Optional (P4): `requires_voodu: ">= x.y.z"` in plugin.yml, checked before
  the hook runs — only helps on controllers that know the field.
