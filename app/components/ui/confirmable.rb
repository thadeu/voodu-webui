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

  # Modal markup lives in Components::UI::ConfirmDialog (shared with the
  # standalone-form case, e.g. the dashboard builder's Save confirm). The
  # confirmable controller drives it via its modal/dialog targets.
  def render_modal
    render Components::UI::ConfirmDialog.new(
      title: @title,
      message: @message,
      confirm_label: @confirm_label,
      cancel_label: @cancel_label,
      danger: @danger,
      icon: @icon
    )
  end
end
