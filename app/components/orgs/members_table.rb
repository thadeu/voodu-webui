# frozen_string_literal: true

# Components::Org::MembersTable — everyone who reaches this org, one row each.
#
# Same shape as Alerts::RulesTable: flex rows rather than a <table>, so the
# columns stack cleanly at 360px instead of forcing a horizontal scroll.
#
# Under Components::Orgs (plural), like every other component here — a
# singular `Components::Org` shadows the ::Org MODEL for every component in the
# tree, and the first thing to break was Components::Orgs::Panel doing `Org.new`.
#
# The filter is `kv-filter` (the one Pods::EnvCard uses) — client side, no
# round-trip. A members list is a handful of rows held entirely in the DOM;
# wiring it through DataTable::Registry would mean a new warehouse-shaped
# source and a rows endpoint to page over twenty records.
class Components::Orgs::MembersTable < Components::Base
  def initialize(memberships:, servers:, org:)
    @memberships = memberships
    @servers = servers
    @org = org
  end

  def view_template
    div(data: {controller: "kv-filter"}, class: "border border-voodu-border bg-voodu-surface") do
      filter_bar
      div(data: {kv_filter_target: "list"}) do
        @memberships.each { |membership| member_row(membership) }
      end
      empty_row
    end
  end

  private

  def filter_bar
    div(class: "flex items-center gap-2 px-3.5 h-9 border-b border-voodu-border") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      input(
        type: "search",
        placeholder: "filter by name, email or role…",
        data: {kv_filter_target: "input", action: "input->kv-filter#filter"},
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] " \
               "text-voodu-text placeholder:text-voodu-muted-2"
      )
      span(class: "text-[11px] text-voodu-muted tabular-nums shrink-0") { @memberships.size.to_s }
    end
  end

  def empty_row
    div(
      hidden: true, data: {kv_filter_target: "empty"},
      class: "px-3.5 py-4 text-[12.5px] text-voodu-muted text-center"
    ) { "No members match." }
  end

  # data-key / data-value are what kv-filter matches on, pre-lowercased here so
  # the controller stays a plain `.includes()`.
  def member_row(membership)
    user = membership.user

    div(
      data: {
        kv_filter_target: "row",
        key: "#{user.display_name} #{user.email}".downcase,
        value: "#{membership.role} #{membership.status}".downcase
      },
      class: "flex flex-col border-b border-voodu-border-2 last:border-b-0"
    ) do
      div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-4 px-3.5 py-3") do
        identity(user)
        role_and_status(membership)
        remove_button(membership)
      end

      granted_servers(membership) if membership.member?
      invite_link(membership) if membership.invited?
    end
  end

  def identity(user)
    div(class: "flex items-center gap-2.5 flex-1 min-w-0") do
      render Components::UI::Avatar.new(url: user.avatar_url, name: user.display_name, size: :sm)

      div(class: "flex flex-col min-w-0") do
        span(class: "text-[13px] text-voodu-text truncate") { user.display_name }
        span(class: "text-[11.5px] text-voodu-muted font-mono truncate") { user.email }
      end
    end
  end

  def role_and_status(membership)
    div(class: "flex items-center gap-2.5 shrink-0") do
      span(class: "text-[11px] uppercase tracking-[0.06em] text-voodu-text-2") { membership.role }
      span(class: "text-[11px] #{membership.active? ? "text-voodu-green" : "text-voodu-amber"}") do
        membership.status
      end
    end
  end

  # The owner is the account principal and cannot be removed — drawing the
  # button would be offering an action the model refuses.
  def remove_button(membership)
    return if membership.owner?

    form(action: org_member_path(org_id: @org.short_id, id: membership.id), method: "post",
      class: "shrink-0") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "delete")

      button(type: "submit", class: "text-[11.5px] text-voodu-red hover:underline") { "Remove" }
    end
  end

  def granted_servers(membership)
    return if @servers.empty?

    granted = membership.server_accesses.map(&:server_id)

    div(class: "flex flex-wrap items-center gap-1.5 px-3.5 pb-3") do
      span(class: "text-[11px] text-voodu-muted mr-0.5") { "Servers" }
      @servers.each { |server| server_toggle(membership, server, granted.include?(server.id)) }
    end
  end

  def server_toggle(membership, server, granted)
    path = granted ? revoke_org_member_path(org_id: @org.short_id, id: membership.id)
                   : grant_org_member_path(org_id: @org.short_id, id: membership.id)

    form(action: path, method: "post", class: "inline") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: granted ? "delete" : "post")
      input(type: "hidden", name: "server_id", value: server.id)

      button(
        type: "submit",
        class: tokens(
          "px-2 h-6 text-[11px] font-mono border transition-colors",
          granted ? "border-voodu-accent-line text-voodu-accent-2 bg-voodu-accent-dim"
                  : "border-voodu-border text-voodu-muted hover:text-voodu-text-2"
        )
      ) { server.name }
    end
  end

  # A pending invitation is an unfinished task: someone has to send that link
  # before the person can get in. So it reads as one — an amber strip with the
  # action as a labelled button, not a 22px icon glued to a sentence, which is
  # what the first version was and nobody spotted it.
  #
  # The URL itself stays out: the token is a signed id, three lines of base64
  # that wrap across the row and bury every other control on it.
  def invite_link(membership)
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2.5 mx-3.5 mb-3 p-2.5 " \
               "border border-voodu-amber/30 bg-voodu-amber/5") do
      div(class: "flex flex-col gap-0.5 flex-1 min-w-0") do
        span(class: "text-[12px] text-voodu-amber") { "Waiting to be accepted" }
        span(class: "text-[11px] text-voodu-muted") do
          "Send this link to #{membership.user.email} — only they can accept it, and it expires in 30 days."
        end
        invited_by_line(membership)
      end

      copy_invite_button(invite_url(membership.invite_token))
    end
  end

  # "Who let them in" is the first question when an unexpected person turns up
  # in an org, so the row answers it without anyone having to open a console.
  def invited_by_line(membership)
    inviter = membership.invited_by
    return if inviter.nil?

    span(class: "text-[11px] text-voodu-muted-2") { "Invited by #{inviter.display_name}" }
  end

  # A labelled Button rather than Components::UI::CopyButton: the clipboard
  # controller only needs the idle/done targets, and this is the primary action
  # on the row — it has to look like one.
  def copy_invite_button(url)
    render Components::UI::Button.new(
      variant: :secondary, size: :sm, class: "h-8 shrink-0",
      data: {
        controller: "clipboard", clipboard_value_value: url,
        action: "click->clipboard#copy"
      }
    ) do
      span(data: {clipboard_target: "idle"}, class: "inline-flex items-center gap-1.5") do
        render Icon::DocumentDuplicateOutline.new(class: "w-3.5 h-3.5")
        plain "Copy invite link"
      end
      span(data: {clipboard_target: "done"}, hidden: true,
        class: "inline-flex items-center gap-1.5 text-voodu-green") do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        plain "Copied"
      end
    end
  end
end
