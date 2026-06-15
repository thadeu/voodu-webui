# frozen_string_literal: true

# Views::Islands::New — the "Add server" modal.
#
# Mirrors design-webui-inspiration/modal-add-server.jsx layout
# (header avatar + title + close X, body fields, footer Cancel +
# primary action). Component is Components::UI::Modal — every modal
# in the app shares its backdrop/blur/ESC/scroll-lock plumbing.
#
# Onboarding contract: when the operator has zero islands registered
# DashboardController#redirect_to_default bounces "/" here. The
# sidebar behind shows the empty-servers state, the backdrop blurs
# it; the operator's only meaningful action is the form. After save
# IslandsController#create redirects to /<key>/.
class Views::Islands::New < Views::Base
  def initialize(current_path:, island:, connection_error: nil)
    @current_path     = current_path
    @island           = island
    @connection_error = connection_error
  end

  def view_template
    render Components::Layouts::Dashboard.new(current_path: @current_path, breadcrumb: [{ label: "Servers" }]) do
      render(modal) { form_body }
    end
  end

  private

  def modal
    Components::UI::Modal.new(
      title:    "Add server",
      subtitle: "Connect a Docker host running the voodu agent",
      icon:     :PlusOutline,
      size:     :md,
      close_to: islands_path
    ).with_footer { footer_actions }
  end

  def form_body
    form(
      action: islands_path, method: "post",
      data: { turbo: false }, id: "add-server-form",
      class: "flex flex-col gap-4 px-5 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

      connection_error_banner if @connection_error

      field(
        label: "Name",
        hint:  "Display name shown in the sidebar.",
        error: @island.errors[:name].first
      ) do
        text_input(name: "island[name]", value: @island.name, placeholder: "prod-edge-02")
      end

      field(
        label: "Server endpoint",
        hint:  endpoint_hint,
        error: @island.errors[:endpoint].first
      ) do
        text_input(
          name: "island[endpoint]", value: @island.endpoint,
          placeholder: "https://edge-02.example.com:8687", mono: true,
          spellcheck: "false"
        )
      end

      field(
        label: "Personal access token",
        hint:  pat_hint,
        error: @island.errors[:pat_ciphertext].first
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
            text_input(name: "island[region]", value: editable_region, placeholder: "fra1")
          end
          field(label: "Infra", hint: "hetzner · aws · bare-metal") do
            text_input(name: "island[infra]", value: @island.infra, placeholder: "hetzner")
          end
        end
      end

      # Hidden submit so Enter in any input submits the form (the
      # footer's "Add server" button is OUTSIDE the <form> — it
      # references it via form="add-server-form").
      input(type: "submit", class: "hidden", "aria-hidden": "true")
    end
  end

  def field(label:, hint: nil, error: nil, &body)
    div(class: "flex flex-col gap-1.5") do
      label_el = label
      span(
        class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2"
      ) { label_el }

      yield

      if error
        div(class: "text-[11.5px] text-voodu-red inline-flex items-center gap-1.5") do
          span(class: "inline-block w-[5px] h-[5px] rounded-full bg-voodu-red", "aria-hidden": "true")
          span { error }
        end
      elsif hint
        div(class: "text-[11.5px] text-voodu-muted") { hint }
      end
    end
  end

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
      data: { controller: "pat-reveal" }
    ) do
      input(
        type: "password",
        name: "island[pat_ciphertext]",
        value: @island.pat,
        placeholder: "vd_live_••••••••••••••••",
        autocomplete: "off",
        spellcheck: "false",
        data: { pat_reveal_target: "input" },
        class: tokens(
          "w-full pl-3 pr-16 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none",
          "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line",
          "placeholder:text-voodu-muted-2 font-voodu-mono text-[12.5px]"
        )
      )
      button(
        type: "button",
        data: { action: "click->pat-reveal#toggle", pat_reveal_target: "btn" },
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

  def footer_actions
    span(class: "text-[11.5px] text-voodu-muted hidden vmd:inline") do
      plain "Need help? See "
      a(href: "#", class: "text-voodu-link hover:underline") { "docs" }
      plain "."
    end

    div(class: "flex-1")

    a(
      href: islands_path,
      class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { "Cancel" }

    button(
      type: "submit",
      form: "add-server-form",
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12.5px] font-medium hover:bg-voodu-accent-2"
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span { "Add server" }
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
    return nil if @island.region.blank? || @island.region == "—"

    @island.region
  end
end
