# frozen_string_literal: true

# OrgsController — CRUD for the Org (server/grouping) layer above servers.
#
# Lives OUTSIDE the server scope (same as ServersController): an org is
# created from the server-registration form, before any `:server_key` exists.
#
# Every action answers turbo_stream so the two live surfaces update in place,
# no page reload:
#
#   - `#org-options`      — the org <select> in the server form (granular
#                           append / replace / remove of one <option>, so the
#                           operator's current selection is preserved).
#   - `#org-manager-panel`— the manager overlay's body (create form + list),
#                           re-rendered wholesale (small N, keeps it simple).
#
# Cross-tab realtime (Solid Cable broadcast) is a later add; same-tab
# turbo_stream already gives the "create org → dropdown updates" flow.
class OrgsController < ApplicationController
  skip_before_action :require_server!

  before_action :set_org, only: [:update, :destroy]

  # Same reason as ServersController: /orgs carries no :org_id segment, so
  # Current.role is nil here and the macro would refuse the org's own owner.
  # The role that decides is the one held IN the org being edited.
  before_action :require_org_management!, only: [:update, :destroy]

  def create
    # The free tier is one org. Refusing CREATION is the whole enforcement —
    # nothing existing is touched, so a licence that lapses leaves every org
    # readable and only stops the next one. That asymmetry is deliberate: an
    # entitlement that could remove access would be a way to lock a customer
    # out of their own dashboard.
    unless entitlements.room_for_another_org?
      return render(
        turbo_stream: turbo_stream.replace("org-manager-panel", panel(error: org_limit_message)),
        status: :unprocessable_entity
      )
    end

    @org = Org.new(org_params.merge(account: current_account))

    # The creator gets an owner membership in the same transaction — membership
    # is the only source of access, so an org saved without one is an org
    # nobody can reach, holding servers nobody can turn off.
    if @org.save && grant_creator_ownership
      render turbo_stream: [
        turbo_stream.append("org-options", Components::Orgs::Option.new(org: @org)),
        turbo_stream.replace("org-manager-panel", panel)
      ]
    else
      render turbo_stream: turbo_stream.replace("org-manager-panel", panel(create_org: @org)),
        status: :unprocessable_entity
    end
  end

  def update
    if @org.update(org_params)
      render turbo_stream: [
        turbo_stream.replace(dom_option_id(@org), Components::Orgs::Option.new(org: @org)),
        turbo_stream.replace("org-manager-panel", panel)
      ]
    else
      render turbo_stream: turbo_stream.replace("org-manager-panel", panel(edit_org: @org)),
        status: :unprocessable_entity
    end
  end

  def destroy
    # restrict_with_error: an org that still owns servers can't be deleted —
    # destroy returns false and stamps errors[:base]. Surface it in the panel.
    if @org.destroy
      render turbo_stream: [
        turbo_stream.remove(dom_option_id(@org)),
        turbo_stream.replace("org-manager-panel", panel)
      ]
    else
      render turbo_stream: turbo_stream.replace("org-manager-panel", panel(error: @org.errors[:base].first)),
        status: :unprocessable_entity
    end
  end

  private

  # The account new orgs land in: the one this operator owns. Onboarding
  # guarantees it exists before any org-creating screen is reachable.
  def current_account
    Current.user&.owned_accounts&.order(:created_at)&.first
  end

  def org_limit_message
    limit = entitlements.limit(:orgs)

    "This installation is licensed for #{limit} #{"org".pluralize(limit)}. " \
      "An Enterprise licence lifts the limit."
  end

  def grant_creator_ownership
    @org.memberships.create!(user: Current.user, role: :owner, status: :active)
    true
  end

  # Through the user's active memberships, not Org.find_by!: a bare lookup made
  # every org in the install renameable and deletable by anyone signed in.
  def require_org_management!
    return if Permissions.allow?(role_in(@org), :manage_org)

    refuse(:manage_org)
  end

  def set_org
    @org = Current.user.active_orgs.find_by!(short_id: params[:id])
  end

  # panel — the re-renderable manager body. Fresh org list + a create form,
  # optionally carrying a rejected create/edit org (to show inline errors) or
  # a top-level error (e.g. delete blocked).
  def panel(create_org: Org.new, edit_org: nil, error: nil)
    Components::Orgs::Panel.new(
      orgs: all_orgs,
      create_org: create_org,
      edit_org: edit_org,
      error: error
    )
  end

  def dom_option_id(org)
    "org-opt-#{org.id}"
  end

  def org_params
    params.require(:org).permit(:name, :description, :timezone)
  end
end
