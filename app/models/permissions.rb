# frozen_string_literal: true

# Permissions — what each role may do, in one table.
#
# Roles are ordered (member < admin < owner) and every capability names the
# LOWEST role that holds it, so a check is a comparison rather than a list of
# roles repeated at each call site. Anything not listed is denied.
#
# The split, in one line each:
#   member — reads the servers they were granted. Changes nothing.
#   admin  — runs the org day to day: servers, PATs, alerts, dashboards, and
#            who may see which server.
#   owner  — the irreversible and the contractual: people, the org itself, the
#            account, and deleting a server (which takes its history with it).
#
# Enforced in controllers (Authorization#require_permission!) and read by views
# to decide what to render. Both matter: a button that disappears while the
# endpoint still honours the request is not authorization.
class Permissions
  ORDER = {member: 0, admin: 1, owner: 2}.freeze

  RULES = {
    # Overview, pods, logs and metrics FOR A GRANTED SERVER. Which servers
    # those are is not a capability question — see ApplicationController
    # #authorized_servers.
    read: :member,

    # Org-level surfaces. A member holds a per-server grant, but alert rules,
    # saved dashboards and the command palette are org-wide objects that name
    # every server in the org — including ones the member was not granted. Kept
    # at admin rather than filtered, deliberately: filtering them is real work
    # with no single chokepoint, and "the person who operates one box does not
    # need the org's alert inventory" is a defensible line.
    read_org_surfaces: :admin,

    manage_servers: :admin,
    reveal_pat: :admin,
    manage_alerts: :admin,
    manage_dashboards: :admin,
    grant_server: :admin,

    delete_server: :owner,
    # Contractual, not day-to-day, so it sits with the owner beside the rest
    # of "people". It was :admin, which let an invited admin invite further
    # admins — each one able to reveal every PAT in the org — without the owner
    # who is paying for the seats being involved at any point. An admin can
    # still run everything the org does; adding people to it is not that.
    invite_member: :owner,
    manage_members: :owner,
    manage_org: :owner,
    manage_account: :owner
  }.freeze

  # No membership (or an unknown capability) is a denial, never a default-allow.
  def self.allow?(role, capability)
    minimum = RULES[capability]
    return false if minimum.nil?

    held = ORDER[role&.to_sym]
    return false if held.nil?

    held >= ORDER.fetch(minimum)
  end

  # For the message a refusal shows: "You need admin access to …".
  def self.minimum_role(capability)
    RULES[capability]
  end
end
