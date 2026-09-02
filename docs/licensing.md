# Licensing: tiers, plans and who gets in

Two questions, two answers, and keeping them apart is what lets one model serve
a laptop, a customer's own datacentre and a hosted service.

- **The tier says what the BOX is.** It comes from the installation's licence,
  and it decides how many accounts fit and whether the control plane may be
  Postgres.
- **The plan says what an ACCOUNT bought.** It decides orgs, invited people and
  how far back the interface will search.

Postgres sits with the box on purpose: whoever deployed it chose the database,
and it is not something a customer of a hosted service can pick. Everything
else is per-account, so a limit means the same thing whether one customer or a
hundred share the installation.

## The four shapes

| installation | tier | plan | accounts | orgs | invites | searchable | Postgres |
|---|---|---|---|---|---|---|---|
| **OSS** (no licence) | `free` | free | 1 | 1 | 0 | 3 days | — |
| **Enterprise** | `enterprise` | pro | 1 | ∞ | ∞ | 90 days | ✓ |
| **Hosted** · free | `unlimited` | free | ∞ | 1 | 0 | 3 days | ✓ |
| **Hosted** · pro | `unlimited` | pro | ∞ | ∞ | ∞ | 90 days | ✓ |

Where each plan comes from:

- **OSS** — no licence at all, so the free plan.
- **Enterprise** — the licence on the box IS that account's pro plan. Buying
  Enterprise means "run it on my own infrastructure, without the org limit"; it
  is one account, not a licence to operate a service of your own on top of
  Voodu. The cap is a default, so a licence carrying `ent.accounts` explicitly
  can still sell more.
- **Hosted** — every account carries its own plan licence, bound to that
  account. See [Plan licences](#plan-licences-hosted-only).

Counting is always per account. `accounts` is the exception and cannot be
otherwise: "how many accounts exist on this box" has no per-account version.

## Who gets in

Signing in proves who somebody is. It says nothing about whether they belong
here — so a second question is asked, **before any user row is created**.

Four reasons to be admitted:

| reason | who |
|---|---|
| `member` | already has an active membership |
| `invited` | somebody with the authority invited this address |
| `claiming_workspace` | the anonymous → Clowk handover named them |
| `open_signup` | the installation has room for another account |

The last one reuses the predicate that governs onboarding, so the two doors
cannot drift into disagreeing about who may start a workspace. It is also what
keeps the model from bricking: without it a freshly installed box with sign-in
already on would admit nobody, including the operator who just installed it,
and a hosted service could never take its first customer.

In practice:

| installation | a stranger with a valid Clowk identity |
|---|---|
| OSS / Enterprise, **no account yet** | admitted — onboards and becomes owner |
| OSS / Enterprise, **account already exists** | **refused**, 403, no row created |
| Hosted | admitted — creates their own account |

A refused person gets a page that names the address to have invited and offers
a way to sign out, not a blank wall. Nothing is written to the database:
admission is checked before provisioning, so identities that do not belong here
leave nothing behind. This matters because a user row in no org reaches nothing
— membership is the only source of access — but appears on no screen either,
which is exactly how thousands of them accumulate unnoticed.

An **unverified** address never matches an invitation. An unproven address is
an assertion, and matching on one would let anybody who can get a provider to
echo an address walk into the org that address was invited to.

## Arriving on the hosted service

On `tier=unlimited` — and **only** there — everybody who is admitted receives a
free account with one org, created on the spot. There is no onboarding form to
fill in and nothing to ask for.

This exists because being invited into somebody else's org used to be the end
of the road. A membership answers "do you belong to an org?", and that was the
question guarding onboarding — so a consultant invited into one customer's org
could never have a workspace of their own. Nobody decided that; two different
questions shared one answer.

Creating the workspace on arrival settles it without a second question:

- an invitation **adds** to what somebody already has;
- somebody removed from the org they were invited to still has their own;
- and an existing member with no workspace is given one on their next request,
  so nothing has to be backfilled by hand.

Self-hosted gets none of this, and the rule is the **tier**, not the count. OSS
and Enterprise hold one account, and provisioning it automatically would spend
it on whoever authenticated first — the opposite of what the cap is for. A
fresh box with room to spare still provisions nothing, so the operator names
their own account and org. `test/services/personal_workspace_test.rb` pins both
halves, so the hosted behaviour cannot leak into a self-hosted release.

## Expiry

Expiry is a slope, not a cliff.

| | orgs | invites | searchable | Postgres |
|---|---|---|---|---|
| valid | ∞ | ∞ | 90 days | ✓ |
| **within 30 days of expiry** (grace) | ∞ | ∞ | 90 days | ✓ |
| **lapsed** | 1 | 0 | 3 days | — |

Nothing is deleted and nothing is disconnected. The orgs and servers already
registered stay, and stay usable; what stops is creating more. A Postgres
control plane keeps being read — losing a licence must never be a data-loss
event — and the screen says the entitlement has gone. Telemetry stays on the
volume under the operator's own retention setting; only the window the
interface will SEARCH shrinks, so renewing brings it back.

Grace applies to a hosted customer's plan the same way: a renewal that lands
late does not take somebody's orgs away overnight.

## Issuing licences

The private key never leaves the machine that issues. `config/license/` holds
the public half, which ships in the image and is what verifies; the private
half is gitignored by pattern, excluded from the image, and
`test/architecture/no_private_keys_test.rb` fails the build if one is ever
committed. The rake task being in the repository is harmless — signing needs
the key, not the code.

### Installation licences

```sh
# Enterprise, one year
bundle exec rake 'license:issue[acme-corp,365]' > acme-corp.jwt

# with specific entitlements
bundle exec rake 'license:issue[acme-corp,365,retention_days=180 orgs=5]'

# the hosted service's own licence
bundle exec rake 'license:issue[voodu-hosted,365,tier=unlimited]' > hosted.jwt
```

The customer pastes it into **License**, or the operator supplies it as
`VOODU_LICENSE` / `VOODU_LICENSE_FILE`. Precedence is by issue date: the newer
licence wins wherever it came from, which is what makes renewal work when the
original came from the environment.

The hosted tier is the one exception — there the installation's licence belongs
to whoever operates the box, so that form is not offered to customers.

### Plan licences (hosted only)

```sh
bundle exec rake 'license:pro[<account short_id>,365]'
```

Bound to one account. Without that binding a pro licence would be a file that
circulates by email — one customer's, pasted into another customer's account.
The short_id is looked up rather than merely accepted, so a typo fails at issue
time instead of when the customer pastes it. Activation refuses a licence whose
subject is not the account activating it, and so does every subsequent read: a
row written straight to the database grants nothing either.

### Inspecting

```sh
bundle exec rake 'license:inspect[eyJhbGciOi…]'
```

Reports status, tier, customer, expiry and the effective entitlements — the
same resolution the application performs, so what it prints is what the app
will do.

## One licence, one server

There is no technical enforcement of this, and there cannot be: an offline
licence does not know where it runs, and any identifier the box could generate
travels with a copy of the box. What the licence can do is record the term, so
misuse is a verifiable breach of contract rather than a technical bypass.

Stating that plainly is deliberate. A control that is described as technical
and is not is worse than no control, because it stops people from putting the
real one — the agreement — in place.
