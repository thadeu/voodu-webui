# Single sign-on

By default this installation asks for no credentials and trusts its perimeter
(see [self-hosted.md](self-hosted.md)). Turn on SSO when you want per-person
identity: several people, each reaching only what a membership grants them.

Clowk is the provider today. The route, the model and the schema are
provider-neutral, so adding another needs no migration.

## Turning it on

Two ways, and the second is why this page exists.

**In the environment**, which needs a restart:

```sh
CLOWK_ENABLED=1
CLOWK_PUBLISHABLE_KEY=pk_live_…
CLOWK_SUBDOMAIN_URL=https://auth.company.com   # optional, custom domains
CLOWK_SECRET_KEY=sk_live_…                     # optional, see below
```

**Or from `/ops/sso`**, if you decided you wanted it after already running.
Paste the publishable key and the address you will sign in with. The next
request asks for authentication.

## The handover, and why it is two steps

An installation that has been running anonymously holds everything under one
local operator. A Clowk sign-in provisions by subject, so the first real login
is a stranger to that row — without a handover it would create a new user with
no membership, land on onboarding, and leave every server and PAT in an org
nobody could reach.

So turning SSO on **moves nothing**. It records which address may claim the
workspace. Then:

1. You sign in through Clowk.
2. If the credentials were right, you land on a confirmation screen naming what
   is being handed over — how many orgs, how many servers, to which address.
3. You confirm. Memberships and account ownership move to your identity.

Only the address you named is offered this, and only once it is verified. An
unproven address is not identity: a provider that lets someone assert an
arbitrary email would otherwise hand over an entire installation.

## The way out

**The environment always wins.** If `CLOWK_ENABLED` or `CLOWK_PUBLISHABLE_KEY`
is set, whatever is stored is ignored — which is the recovery path, not a
preference. A wrong key saved through the UI would send every request to a Clowk
instance that does not know you, with no UI left to fix it from.

```sh
CLOWK_ENABLED=0    # restart, and you are anonymous again
```

Nothing is lost by that: until you confirm the handover, the workspace is
exactly where it was. There is also a **Turn off sign-in** button on `/ops/sso`,
usable while you still have a session.

## Optional settings

`CLOWK_SECRET_KEY` is not needed to verify tokens — Clowk signs with RS256 and
the app checks the published key set. Supply it for tokens minted before Clowk's
RS256 migration, or for the management API used to end someone's session when
you remove them.

`CLOWK_SUBDOMAIN_URL` skips a lookup through `api.clowk.dev` on the path that
authenticates every request. Optional; the gem derives it from the publishable
key when unset.

## Who sees what, once sign-in is on

| role | reaches |
|---|---|
| `owner` | the account principal: people, the org itself, deleting a server |
| `admin` | every server in the org: PATs, alerts, dashboards, invites, grants |
| `member` | only the servers granted to them. No PATs, no settings |

A membership is the only thing that grants access — an account groups and bills,
it never authorizes. That is what lets someone be invited into another company's
org with no exception anywhere.

Invitations are a signed link the admin copies and sends; there is no SMTP in
this app. Only the person it was addressed to can accept, and it expires in 30
days.
