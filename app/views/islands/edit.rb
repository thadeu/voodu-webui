# frozen_string_literal: true

# Views::Islands::Edit — the "Edit server" modal.
#
# Same shell as Views::Islands::New (modal + form), wired to PATCH
# /islands/:id. PAT field is blank on render — submitting blank
# keeps the stored value (see IslandsController#update). That way
# the operator can change name/endpoint/region without re-typing
# the PAT.
class Views::Islands::Edit < Views::Base
  # return_to: — caller-supplied path the modal close + post-save
  # redirect should land on (Settings page uses this to keep the
  # operator's flow on Settings instead of bouncing them back to
  # the /islands registry).
  def initialize(current_path:, island:, connection_error: nil, return_to: nil)
    @current_path     = current_path
    @island           = island
    @connection_error = connection_error
    @return_to        = return_to
  end

  def view_template
    render Components::Layouts::Dashboard.new(current_path: @current_path) do
      render(modal) { form_body }
    end
  end

  private

  def modal
    Components::UI::Modal.new(
      title:    "Edit server",
      subtitle: "Update name, endpoint, or rotate the PAT",
      icon:     :PencilSquareOutline,
      size:     :md,
      close_to: close_destination
    ).with_footer { footer_actions }
  end

  # close_destination — where the X / Cancel sends the operator.
  # Honors return_to when the caller passed one (Settings → close
  # goes back to Settings); falls back to /islands so the registry
  # surface stays the default landing.
  def close_destination
    @return_to.presence || islands_path
  end

  def form_body
    form(
      action: island_path(@island), method: "post",
      data: { turbo: false }, id: "edit-server-form",
      class: "flex flex-col gap-4 px-5 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch")
      # return_to rides along so the post-save redirect honours
      # the page the operator came from (Settings vs /islands).
      input(type: "hidden", name: "return_to", value: @return_to) if @return_to.present?

      connection_error_banner if @connection_error

      field(label: "Name", error: @island.errors[:name].first) do
        text_input(name: "island[name]", value: @island.name)
      end

      field(label: "Server endpoint", error: @island.errors[:endpoint].first) do
        text_input(
          name: "island[endpoint]", value: @island.endpoint,
          mono: true, spellcheck: "false"
        )
      end

      field(
        label: "Personal access token",
        hint:  "Leave blank to keep the current token.",
        error: @island.errors[:pat_ciphertext].first
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
            text_input(name: "island[region]", value: editable_region, placeholder: "fra1")
          end
          field(label: "Infra") do
            text_input(name: "island[infra]", value: @island.infra, placeholder: "hetzner")
          end
        end
      end

      input(type: "submit", class: "hidden", "aria-hidden": "true")
    end
  end

  # Shared with Views::Islands::New conceptually — both ship the
  # same modal layout. Duplicated rather than abstracted because
  # extracting a shared "ServerForm" component would couple two
  # otherwise-independent surfaces (new is wizard-y, edit is
  # rotate-y). Drift between the two is welcome.

  def field(label:, hint: nil, error: nil)
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

  def pat_input
    div(class: "relative", data: { controller: "pat-reveal" }) do
      input(
        type: "password",
        name: "island[pat_ciphertext]",
        value: nil,
        placeholder: "Leave blank to keep current",
        autocomplete: "off", spellcheck: "false",
        data: { pat_reveal_target: "input" },
        class: "w-full pl-3 pr-16 h-9 bg-voodu-surface border border-voodu-border text-voodu-text outline-none focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line placeholder:text-voodu-muted-2 font-voodu-mono text-[12.5px]"
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
      span(class: "inline-flex items-center justify-center w-3.5 h-3.5 mt-0.5 text-voodu-red shrink-0 font-bold") { "!" }
      div(class: "min-w-0") do
        div(class: "text-voodu-red font-semibold text-[12.5px] mb-0.5") { "Connection failed" }
        div(class: "text-voodu-text-2 text-[12px]") { @connection_error }
      end
    end
  end

  def footer_actions
    div(class: "flex-1")

    a(
      href: close_destination,
      class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { "Cancel" }

    button(
      type: "submit", form: "edit-server-form",
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12.5px] font-medium hover:bg-voodu-accent-2"
    ) do
      render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
      span { "Save changes" }
    end
  end

  def editable_region
    return nil if @island.region.blank? || @island.region == "—"

    @island.region
  end
end
