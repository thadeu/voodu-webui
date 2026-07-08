# frozen_string_literal: true

# Components::UI::Switch — a macOS-style toggle.
#
# A visually-hidden (`sr-only`) checkbox is the real control + source of truth
# (keyboard-focusable, form-serializable, a11y-correct); a Tailwind `peer-checked`
# track + knob paint the switch on top. Drop-in replacement for a raw checkbox:
# pass `checked:` plus any input attributes (data:, name:, id:, aria-label:,
# disabled:, …) and they flow straight through to the <input>.
#
#   render Components::UI::Switch.new(
#     checked: true,
#     data: { panel_options_target: "dots", action: "change->panel-options#toggleDots" }
#   )
class Components::UI::Switch < Components::Base
  def initialize(checked: false, **attrs)
    @checked = checked
    @attrs = attrs
  end

  def view_template
    span(class: "relative inline-flex items-center shrink-0 w-[34px] h-[20px]") do
      input(
        type: "checkbox", checked: @checked, class: "peer sr-only",
        # type/checked/class are owned by the switch — everything else (data,
        # name, aria, disabled) passes through to the control.
        **@attrs.except(:type, :checked, :class)
      )
      span(class: "absolute inset-0 rounded-full bg-voodu-border transition-colors peer-checked:bg-voodu-accent")
      span(class: "absolute left-[3px] top-[3px] w-[14px] h-[14px] rounded-full bg-white shadow transition-transform peer-checked:translate-x-[14px]")
    end
  end
end
