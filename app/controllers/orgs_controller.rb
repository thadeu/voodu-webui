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

  def create
    @org = Org.new(org_params)

    if @org.save
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

  def set_org
    @org = Org.find_by!(short_id: params[:id])
  end

  # panel — the re-renderable manager body. Fresh org list + a create form,
  # optionally carrying a rejected create/edit org (to show inline errors) or
  # a top-level error (e.g. delete blocked).
  def panel(create_org: Org.new, edit_org: nil, error: nil)
    Components::Orgs::Panel.new(
      orgs: Org.order(:name).to_a,
      create_org: create_org,
      edit_org: edit_org,
      error: error
    )
  end

  def dom_option_id(org)
    "org-opt-#{org.id}"
  end

  def org_params
    params.require(:org).permit(:name, :description)
  end
end
