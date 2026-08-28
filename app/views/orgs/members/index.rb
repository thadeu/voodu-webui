# frozen_string_literal: true

# Views::Org::Members::Index — who reaches this org, and which servers.
#
# Takes the whole dashboard context, not just current_path: without `servers:`
# the sidebar has no server to point its per-server links at, so it drops its
# entire nav — which left this page with no way back to anything.
class Views::Orgs::Members::Index < Views::Base
  def initialize(current_path:, org:, memberships:, servers:, current_server: nil, sidebar_servers: [])
    @current_path = current_path
    @org = org
    @memberships = memberships
    @servers = servers
    @current_server = current_server
    @sidebar_servers = sidebar_servers
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path,
      servers: @sidebar_servers,
      current_server: @current_server,
      breadcrumb: [{label: "Members"}]
    ) do
      div(class: "flex flex-col gap-5 p-4 vmd:p-6") do
        page_head
        invite_form
        render Components::Orgs::MembersTable.new(
          memberships: @memberships, servers: @servers, org: @org
        )
      end
    end
  end

  private

  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Members of #{@org.name}" }
      p(class: "text-[12.5px] text-voodu-muted") do
        "Admins reach every server in this org. Members reach only what you grant them."
      end
    end
  end

  def invite_form
    form(action: org_members_path(org_id: @org.short_id), method: "post",
      class: "flex flex-col vmd:flex-row gap-2.5 vmd:items-end") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

      div(class: "flex-1 min-w-0") do
        field(label: "Invite by email") do
          input(type: "email", name: "email", required: true,
            placeholder: "teammate@example.com", class: input_classes)
        end
      end

      div(class: "vmd:w-40") do
        field(label: "Role") do
          render Components::UI::Select.new(
            name: "role", selected: "member",
            options: [["member", "member"], ["admin", "admin"]]
          )
        end
      end

      # h-9 to match input_classes on the two fields beside it. The button's own
      # padding scale renders a few pixels shorter, which reads as misalignment
      # on a single row.
      render Components::UI::Button.new(type: "submit", variant: :primary, class: "h-9 shrink-0") do
        "Create invite"
      end
    end
  end
end
