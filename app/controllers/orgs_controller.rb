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
    # Measured against the account the org will LAND in, which is not the one
    # `entitlements` resolves. That helper follows the org in the URL, so an
    # admin invited into another company had their new org counted against
    # THAT company's plan while being written into their own: refused when the
    # host was full even though they had room, and allowed past their own cap
    # when the host had space. Two accounts, one decision.
    unless Entitlements.for(plan_account).room_for_another_org?
      return render(
        turbo_stream: turbo_stream.replace("org-manager-panel", panel(error: org_limit_message)),
        status: :unprocessable_entity
      )
    end

    # plan_account — the account this person OWNS, which is where their orgs
    # go. Deliberately not ApplicationController#current_account, which follows
    # the org in the URL: an admin invited into another company would otherwise
    # create orgs inside THEIR account.
    #
    # This used to be a private `current_account` right here, shadowing the
    # parent's method of the same name with a different meaning. Same
    # behaviour, one name per idea.
    @org = Org.new(org_params.merge(account: plan_account))

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

  def org_limit_message
    limit = Entitlements.for(plan_account).limit(:orgs)

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
      error: error,
      # The same account `create` puts the org in, so the note on the form and
      # the row that appears afterwards cannot disagree.
      destination_account: plan_account
    )
  end

  def dom_option_id(org)
    "org-opt-#{org.id}"
  end

  def org_params
    params.require(:org).permit(:name, :description, :timezone)
  end
end
