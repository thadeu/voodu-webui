# frozen_string_literal: true

class Org
  # Org::MembersController — who may reach this org, and which servers.
  #
  # An invitation IS a membership with status: invited — no second table, no
  # token column, nothing that can disagree with the membership about who
  # someone is. The admin copies a signed link out of this screen; there is no
  # SMTP anywhere in this app, and making a self-hosted install configure one
  # before it can add a teammate is friction we are not imposing.
  class MembersController < ApplicationController
    skip_before_action :require_server!

    before_action :require_org!
    before_action :set_membership, only: [:update, :destroy, :grant, :revoke]

    authorize :invite_member, only: [:index, :create]
    authorize :grant_server, only: [:grant, :revoke]
    authorize :manage_members, only: [:update, :destroy]

    def index
      render Views::Orgs::Members::Index.new(
        current_path: current_path, org: current_org, memberships: memberships,
        servers: org_servers,
        # The sidebar needs a server to point its per-server links at. This
        # route has no :server_key, so hand it the ones this person reaches in
        # this org and let it fall back to the first — otherwise the nav
        # disappears and the page is a dead end.
        sidebar_servers: all_servers, current_server: all_servers.first
      )
    end

    # The row is created `invited` and grants nothing until the person follows
    # the link and proves they are that row — see InvitesController.
    def create
      email = params[:email].to_s.strip.downcase
      role = %w[member admin].include?(params[:role]) ? params[:role] : "member"

      user = User.find_or_create_by!(email: email)
      membership = current_org.memberships.find_or_initialize_by(user: user)

      if membership.persisted?
        return redirect_to(org_members_path, alert: "#{email} is already #{membership.status} here.")
      end

      membership.update!(
        role: role, status: :invited, invited_at: Time.current, invited_by: Current.user
      )

      redirect_to org_members_path, notice: "Invitation ready for #{email} — copy the link on their row."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to org_members_path, alert: e.record.errors.full_messages.to_sentence
    end

    def update
      role = params[:role].to_s

      # owner is not something an edit hands out: it is the account principal,
      # set at signup. Same ceiling as the invite form.
      return redirect_to(org_members_path, alert: "Pick member or admin.") unless %w[member admin].include?(role)

      if @membership.update(role: role)
        redirect_to org_members_path, notice: "Role updated."
      else
        redirect_to org_members_path, alert: @membership.errors.full_messages.to_sentence
      end
    end

    def destroy
      user = @membership.user

      if @membership.destroy
        # Best effort, and after the fact: the removal itself is what denies
        # access (the scope is re-read every request). This just stops their
        # Clowk session outliving it. Never blocks the removal.
        ClowkSessionRevoker.revoke_for(user)

        redirect_to org_members_path, notice: "Access removed."
      else
        redirect_to org_members_path, alert: @membership.errors.full_messages.to_sentence
      end
    end

    # BOTH sides scoped through the current org — the membership and the
    # server. Scoping one and not the other is exactly how a grant ends up
    # pairing this org's member with another org's server.
    def grant
      server = current_org.servers.find_by(id: params[:server_id])
      return redirect_to(org_members_path, alert: "Unknown server.") if server.nil?

      @membership.server_accesses.find_or_create_by!(server: server, org: current_org)

      redirect_to org_members_path, notice: "Access granted to #{server.name}."
    end

    def revoke
      @membership.server_accesses.where(server_id: params[:server_id]).destroy_all

      redirect_to org_members_path, notice: "Access revoked."
    end

    private

    def memberships
      current_org.memberships.includes(:user, :server_accesses).order(:created_at)
    end

    def org_servers
      current_org.servers.order(:name)
    end

    def set_membership
      @membership = current_org.memberships.find(params[:id])
    end

    def require_org!
      redirect_to root_path(org_id: nil, server_key: nil) if current_org.nil?
    end
  end
end
