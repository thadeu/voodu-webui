# frozen_string_literal: true

# Views::Servers::New — the "Add server" page.
#
# Was a modal over the servers list. A page instead, matching the licence and
# sign-in screens: this form is not a quick confirmation, it is four fields plus
# an endpoint and a token that people paste from a terminal in another window.
# A modal is the wrong container for that — it cannot be linked to or reloaded
# without losing what was typed, it traps the page behind a backdrop while
# someone goes to fetch a token, and it has nowhere to put a connection failure
# except on top of the fields that caused it.
#
# The route never changed: /:org_id/servers/new was always a real page that
# happened to draw a modal on top of the dashboard. Every entry point is a plain
# anchor, so nothing about navigation moved either.
#
# Onboarding contract: when the operator has zero servers registered
# DashboardController#redirect_to_default bounces "/" here. The sidebar shows
# its empty-servers state alongside; the operator's only meaningful action is
# the form. After save ServersController#create redirects to /<key>/.
class Views::Servers::New < Views::Base
  def initialize(current_path:, server:, orgs: [], servers: [], connection_error: nil)
    @current_path = current_path
    @servers = servers
    @server = server
    @orgs = orgs
    @connection_error = connection_error
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers,
      breadcrumb: [{label: "Servers", href: servers_path}, {label: "Add server"}]
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

  # page_head, not `header` — that is a Phlex HTML tag method.
  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Add server" }
      p(class: "text-[12.5px] text-voodu-muted") { "Connect a Docker host running the voodu agent" }
    end
  end

  def form_card
    render Components::UI::SectionCard.new(title: "Server") { form_body }
  end

  def form_body
    form(
      action: servers_path, method: "post",
      data: {turbo: false}, id: "add-server-form",
      class: "flex flex-col"
    ) do
      div(class: "flex flex-col gap-4 p-3.5") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

        connection_error_banner if @connection_error

        field(
          label: "Name",
          hint: "Display name shown in the sidebar.",
          error: @server.errors[:name].first
        ) do
          text_input(name: "server[name]", value: @server.name, placeholder: "prod-edge-02")
        end

        render Components::Orgs::Field.new(orgs: @orgs, selected_id: @server.org_id)

        field(
          label: "Server endpoint",
          hint: endpoint_hint,
          error: @server.errors[:endpoint].first
        ) do
          text_input(
            name: "server[endpoint]", value: @server.endpoint,
            placeholder: "https://edge-02.example.com:8687", mono: true,
            spellcheck: "false"
          )
        end

        field(
          label: "Personal access token",
          hint: pat_hint,
          error: @server.errors[:pat_ciphertext].first
        ) do
          pat_input
        end

        # Region + infra remain part of the model (topbar chips) but
        # they're operator metadata, not connection-critical. Tuck
        # them under a disclosure so the modal stays focused on the
        # required three.
        details(class: "group") do
          summary(class: "list-none cursor-pointer text-[12px] text-voodu-muted hover:text-voodu-text-2 inline-flex items-center gap-1.5 select-none") do
            render Icon::ChevronRightOutline.new(class: "w-3 h-3 transition-transform group-open:rotate-90")
            plain "Optional metadata (region · infra)"
          end
          div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3 mt-3") do
            field(label: "Region", hint: "fra1 · us-east-1 · homelab") do
              text_input(name: "server[region]", value: editable_region, placeholder: "fra1")
            end
            field(label: "Infra", hint: "hetzner · aws · bare-metal") do
              text_input(name: "server[infra]", value: @server.infra, placeholder: "hetzner")
            end
          end
        end

        # Hidden submit so Enter in any input submits the form (the
        # footer's "Add server" button is OUTSIDE the <form> — it
        # references it via form="add-server-form").
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
        render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
        span { "Add server" }
      end

      a(
        href: servers_path,
        class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border " \
               "bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium " \
               "hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) { "Cancel" }
    end
  end

  # field lives in Views::Base (shared by every modal form).

  def text_input(name:, value: nil, placeholder: nil, mono: false, spellcheck: nil)
    input(
      type: "text",
      name: name,
      value: value,
      placeholder: placeholder,
      autocomplete: "off",
      spellcheck: spellcheck,
      class: tokens(
        "w-full px-3 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none",
        "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line",
        "placeholder:text-voodu-muted-2",
        mono ? "font-voodu-mono text-[12.5px]" : "text-[13px]"
      )
    )
  end

  # pat_input — text field with a right-aligned show/hide toggle.
  # Stimulus controller `pat-reveal` swaps the input type between
  # password and text. Keeps the modal's mostly-stateless feel —
  # no separate component, just one inline action.
  def pat_input
    div(
      class: "relative",
      data: {controller: "pat-reveal"}
    ) do
      input(
        type: "password",
        name: "server[pat_ciphertext]",
        value: @server.pat,
        placeholder: "vd_live_••••••••••••••••",
        autocomplete: "off",
        spellcheck: "false",
        data: {pat_reveal_target: "input"},
        class: tokens(
          "w-full pl-3 pr-16 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none",
          "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line",
          "placeholder:text-voodu-muted-2 font-voodu-mono text-[12.5px]"
        )
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
      span(
        class: "inline-flex items-center justify-center w-3.5 h-3.5 mt-0.5 text-voodu-red shrink-0 font-bold"
      ) { "!" }
      div(class: "min-w-0") do
        div(class: "text-voodu-red font-semibold text-[12.5px] mb-0.5") { "Connection failed" }
        div(class: "text-voodu-text-2 text-[12px]") { @connection_error }
      end
    end
  end

  def endpoint_hint
    safe = "HTTP(S) URL of the voodu agent on the host. Default port is "
    span do
      plain safe
      span(class: "font-voodu-mono text-voodu-text-2") { "8687" }
      plain "."
    end
  end

  def pat_hint
    span do
      plain "Create one on the box with "
      span(class: "font-voodu-mono text-voodu-accent-2") { "vd pat create --scope=read,actions" }
      plain "."
    end
  end

  def editable_region
    return nil if @server.region.blank? || @server.region == "—"

    @server.region
  end
end
