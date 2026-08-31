# frozen_string_literal: true

# Views::Servers::Edit — the "Edit server" modal.
#
# Same shell as Views::Servers::New (modal + form), wired to PATCH
# /servers/:id. PAT field is blank on render — submitting blank
# keeps the stored value (see ServersController#update). That way
# the operator can change name/endpoint/region without re-typing
# the PAT.
class Views::Servers::Edit < Views::Base
  # return_to: — caller-supplied path the modal close + post-save
  # redirect should land on (Settings page uses this to keep the
  # operator's flow on Settings instead of bouncing them back to
  # the /servers registry).
  def initialize(current_path:, server:, orgs: [], servers: [], connection_error: nil, return_to: nil)
    @current_path = current_path
    @servers = servers
    @server = server
    @orgs = orgs
    @connection_error = connection_error
    @return_to = return_to
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers,
      breadcrumb: [{label: "Servers", href: servers_path}, {label: "Edit server"}]
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_head
        div(class: "max-w-3xl") do
          # The org-manager controller wraps the card + the overlay (siblings) so
          # the "New org" trigger inside the form reaches it, and the overlay's
          # own CRUD forms are not nested inside this one.
          div(data: {controller: "org-manager"}) do
            form_card
            render Components::Orgs::Overlay.new(orgs: @orgs)
          end
        end
      end
    end
  end

  private

  # Where Cancel goes. `return_to` is how Settings sends someone here and gets
  # them back to the page they were reading, rather than to the servers list
  # they never visited.
  def close_destination
    @return_to.presence || servers_path
  end

  # page_head, not `header` — that is a Phlex HTML tag method.
  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Edit server" }
      p(class: "text-[12.5px] text-voodu-muted") { "Update name, endpoint, or rotate the PAT" }
    end
  end

  def form_card
    render Components::UI::SectionCard.new(title: @server.name.presence || "Server") { form_body }
  end

  def form_body
    form(
      action: server_path(@server), method: "post",
      data: {turbo: false}, id: "edit-server-form",
      class: "flex flex-col"
    ) do
      div(class: "flex flex-col gap-4 p-3.5") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        input(type: "hidden", name: "_method", value: "patch")
        # return_to rides along so the post-save redirect honours
        # the page the operator came from (Settings vs /servers).
        input(type: "hidden", name: "return_to", value: @return_to) if @return_to.present?

        connection_error_banner if @connection_error

        field(label: "Name", error: @server.errors[:name].first) do
          text_input(name: "server[name]", value: @server.name)
        end

        org_row

        field(label: "Server endpoint", error: @server.errors[:endpoint].first) do
          text_input(
            name: "server[endpoint]", value: @server.endpoint,
            mono: true, spellcheck: "false"
          )
        end

        field(
          label: "Personal access token",
          hint: "Leave blank to keep the current token.",
          error: @server.errors[:pat_ciphertext].first
        ) do
          pat_input
        end

        details(class: "group") do
          summary(class: "list-none cursor-pointer text-[12px] text-voodu-muted hover:text-voodu-text-2 inline-flex items-center gap-1.5 select-none") do
            render Icon::ChevronRightOutline.new(class: "w-3 h-3 transition-transform group-open:rotate-90")
            plain "Optional metadata (region · infra)"
          end
          div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3 mt-3") do
            field(label: "Region") do
              text_input(name: "server[region]", value: editable_region, placeholder: "fra1")
            end
            field(label: "Infra") do
              text_input(name: "server[infra]", value: @server.infra, placeholder: "hetzner")
            end
          end
        end
      end

      form_actions
    end
  end

  # Inside the form now. In the modal these lived in a footer OUTSIDE it, which
  # is why the submit carried a `form:` attribute and a hidden submit input had
  # to exist so Enter still worked. On a page neither is needed.
  def form_actions
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 p-3.5 " \
               "border-t border-voodu-border") do
      button(
        type: "submit",
        class: "inline-flex items-center justify-center gap-1.5 px-3 h-9 border " \
               "border-voodu-accent-line bg-voodu-btn-accent text-voodu-on-accent " \
               "text-[12.5px] font-medium hover:bg-voodu-btn-accent-hover"
      ) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        span { "Save changes" }
      end

      a(
        href: close_destination,
        class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border " \
               "bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium " \
               "hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) { "Cancel" }
    end
  end

  # Shared with Views::Servers::New conceptually — both ship the
  # same modal layout. Duplicated rather than abstracted because
  # extracting a shared "ServerForm" component would couple two
  # otherwise-independent surfaces (new is wizard-y, edit is
  # rotate-y). Drift between the two is welcome.

  # field lives in Views::Base (shared by every modal form).

  def text_input(name:, value: nil, placeholder: nil, mono: false, spellcheck: nil)
    input(
      type: "text", name: name, value: value, placeholder: placeholder,
      autocomplete: "off", spellcheck: spellcheck,
      class: tokens(
        "w-full px-3 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none",
        "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line",
        "placeholder:text-voodu-muted-2",
        mono ? "font-voodu-mono text-[12.5px]" : "text-[13px]"
      )
    )
  end

  # Read-only on edit. ServersController#server_params stops permitting
  # :org_id outside registration — moving a server between orgs would carry
  # its whole warehouse history and its PAT along with it — so an editable
  # selector here would be a control that silently does nothing.
  def org_row
    field(label: "Org", hint: "Set at registration.") do
      div(class: "text-[13px] text-voodu-text-2") { @server.org&.name.to_s }
    end
  end

  def pat_input
    div(class: "relative", data: {controller: "pat-reveal"}) do
      input(
        type: "password",
        name: "server[pat_ciphertext]",
        value: nil,
        placeholder: "Leave blank to keep current",
        autocomplete: "off", spellcheck: "false",
        data: {pat_reveal_target: "input"},
        class: "w-full pl-3 pr-16 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line placeholder:text-voodu-muted-2 font-voodu-mono text-[12.5px]"
      )
      button(
        type: "button",
        data: {action: "click->pat-reveal#toggle", pat_reveal_target: "btn"},
        class: "absolute right-[1px] top-[1px] bottom-[1px] px-3 text-[11px] text-voodu-muted hover:text-voodu-text border-l border-voodu-border bg-voodu-surface"
      ) { "show" }
    end
  end

  def connection_error_banner
    div(
      role: "alert",
      class: "px-3 py-2.5 border border-voodu-red/45 bg-voodu-red-dim border-l-[3px] border-l-voodu-red flex items-start gap-2.5"
    ) do
      span(class: "inline-flex items-center justify-center w-3.5 h-3.5 mt-0.5 text-voodu-red shrink-0 font-bold") { "!" }
      div(class: "min-w-0") do
        div(class: "text-voodu-red font-semibold text-[12.5px] mb-0.5") { "Connection failed" }
        div(class: "text-voodu-text-2 text-[12px]") { @connection_error }
      end
    end
  end

  def editable_region
    return nil if @server.region.blank? || @server.region == "—"

    @server.region
  end
end
