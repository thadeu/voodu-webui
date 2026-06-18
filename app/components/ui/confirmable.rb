# frozen_string_literal: true

# Components::UI::Confirmable — wraps a destructive action in a
# styled confirmation modal.
#
# Replaces `data: { turbo_confirm: "Are you sure?" }` (which renders
# the native `window.confirm` browser dialog — ugly, can't be themed,
# operator gets used to mashing OK). Uses the same DS modal look as
# Add/Edit server.
#
# Anatomy:
#
#   <div data-controller="confirmable">
#     <form … data-confirmable-target="form"
#             data-action="submit->confirmable#prompt">
#       <button …>{block content}</button>
#     </form>
#     <div hidden data-confirmable-target="modal">
#       … backdrop + dialog + Cancel/Confirm …
#     </div>
#   </div>
#
# On submit the controller intercepts, shows the modal, locks body
# scroll, binds ESC. Confirm calls `form.requestSubmit()` (after
# clearing the intercept flag) so the form posts normally.
#
# Usage
#
#   render Components::UI::Confirmable.new(
#     title:         "Remove server",
#     message:       "Permanently remove \"debian\" from the registry?",
#     confirm_label: "Remove",
#     danger:        true,
#     icon:          :TrashOutline,
#     form: {
#       action: island_path(island),
#       method: :delete
#     },
#     trigger: {
#       class: "<button classes>",
#       title: "Remove server",
#       "aria-label": "Remove #{island.name}"
#     }
#   ) do
#     render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
#     span(class: "hidden vmd:inline") { "Remove" }
#   end
#
# `danger: true` swaps the confirm button to the red palette;
# leave false for benign actions (e.g. "Apply changes").
class Components::UI::Confirmable < Components::Base
  # id — stable identifier for the Turbo "permanent" wrapping. Same
  # rationale as Components::UI::Drawer: when this confirmable's host
  # frame is re-rendered (e.g. state_tick reloading the pod show
  # frame while the operator has the Restart modal open), Turbo
  # matches before/after by id and KEEPS the current node — modal
  # stays open, mid-confirmation state preserved.
  #
  # Default hashes the form action + method so two confirmables in
  # the same frame get distinct ids automatically. Pass `id:` for
  # readability when the call site has a natural identifier.
  # turbo_frame — when the confirmable lives INSIDE a turbo_frame and
  # its action redirects somewhere without that frame, pass "_top" so
  # the submit navigates the whole page (data-turbo:false is ignored
  # for a submit inside a frame → "Content missing" on the redirect).
  # Default nil keeps the native (data-turbo:false) submit used by
  # top-level confirmables (e.g. the Islands delete).
  def initialize(title:, message:, form:, trigger: {},
    id: nil,
    confirm_label: "Confirm", cancel_label: "Cancel",
    danger: false, icon: nil, turbo_frame: nil)
    @title = title
    @message = message
    @confirm_label = confirm_label
    @cancel_label = cancel_label
    @danger = danger
    @turbo_frame = turbo_frame
    @icon = icon || (danger ? :ExclamationTriangleOutline : :CheckOutline)

    @form_action = form.fetch(:action)
    @form_method = form.fetch(:method, :post).to_s.downcase
    @form_attrs = form.except(:action, :method)

    @trigger_attrs = trigger
    @id = id || "confirmable-#{Digest::SHA1.hexdigest("#{@form_action}-#{@form_method}")[0, 12]}"
  end

  def view_template(&trigger_body)
    div(
      # `data-turbo-permanent` + stable id → Turbo preserves THIS
      # node across frame reloads, so a state_tick mid-confirmation
      # doesn't close the modal under the operator's finger.
      id: @id,
      class: "inline-flex",
      data: {
        controller: "confirmable",
        turbo_permanent: true
      }
    ) do
      render_form(&trigger_body)
      render_modal
    end
  end

  private

  def render_form(&trigger_body)
    method_override = @form_method != "get" && @form_method != "post"
    html_method = method_override ? "post" : @form_method

    form(
      action: @form_action,
      method: html_method,
      data: {
        confirmable_target: "form",
        action: "submit->confirmable#prompt"
      }.merge(@turbo_frame ? {turbo_frame: @turbo_frame} : {turbo: false}),
      **@form_attrs
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: @form_method) if method_override

      button(type: "submit", **@trigger_attrs, &trigger_body)
    end
  end

  # Modal markup — visual parity with Components::UI::Modal, but
  # initially hidden + driven by confirmable controller (not the
  # generic modal controller, which is tuned for full-page modals
  # that mount visible). Backdrop + dialog use the same Tailwind
  # tokens as Components::UI::Modal so the look stays in lock-step
  # if either gets restyled.
  def render_modal
    div(hidden: true, data: {confirmable_target: "modal"}) do
      backdrop
      dialog
    end
  end

  def backdrop
    div(
      "aria-hidden": "true",
      data: {action: "click->confirmable#cancel"},
      class: "fixed inset-0 z-[65] bg-black/55 backdrop-blur-[3px]"
    )
  end

  def dialog
    div(
      role: "dialog",
      "aria-modal": "true",
      "aria-labelledby": "voodu-confirmable-title",
      data: {confirmable_target: "dialog"},
      class: tokens(
        "fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-[70]",
        "w-[min(420px,calc(100vw-24px))] max-h-[calc(100vh-48px)]",
        "flex flex-col",
        "bg-voodu-surface-2 border border-voodu-border-2",
        "shadow-[0_28px_56px_rgba(0,0,0,0.65),0_4px_12px_rgba(0,0,0,0.4)]"
      )
    ) do
      header_section
      body_section
      footer_section
    end
  end

  def header_section
    header(
      class: "flex items-center gap-2.5 px-4 py-3.5 border-b border-voodu-border bg-voodu-surface"
    ) do
      span(
        class: tokens(
          "inline-flex items-center justify-center w-[26px] h-[26px] shrink-0 border",
          @danger ? "bg-voodu-red-dim border-voodu-red/40 text-voodu-red"
                  : "bg-voodu-accent-dim border-voodu-accent-line text-voodu-accent-2"
        )
      ) do
        render Icon.const_get(@icon).new(class: "w-3.5 h-3.5")
      end

      h2(
        id: "voodu-confirmable-title",
        class: "m-0 text-[15px] font-semibold text-voodu-text leading-tight flex-1 min-w-0"
      ) { @title }

      button(
        type: "button",
        "aria-label": "Close",
        data: {action: "click->confirmable#cancel"},
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  def body_section
    div(class: "px-4 py-4 overflow-auto min-h-0") do
      p(class: "text-[13px] text-voodu-text-2 leading-relaxed m-0") { @message }
    end
  end

  def footer_section
    footer(
      class: "flex items-center gap-2 flex-wrap px-4 py-3 border-t border-voodu-border bg-voodu-bg-2"
    ) do
      div(class: "flex-1")

      button(
        type: "button",
        data: {action: "click->confirmable#cancel"},
        class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) { @cancel_label }

      button(
        type: "button",
        data: {action: "click->confirmable#confirm"},
        class: tokens(
          "inline-flex items-center gap-1.5 px-3 h-9 border text-voodu-on-accent text-[12.5px] font-medium",
          @danger ? "border-voodu-red/60 bg-voodu-red hover:bg-voodu-red/90"
                  : "border-voodu-accent-line bg-voodu-accent hover:bg-voodu-accent-2"
        )
      ) do
        render Icon.const_get(@icon).new(class: "w-3.5 h-3.5")
        span { @confirm_label }
      end
    end
  end
end
