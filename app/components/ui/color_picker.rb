# frozen_string_literal: true

# Components::UI::ColorPicker — a DS colour picker (spectrum canvas + hue rail
# + hex input), ported from Stella's color-picker.tsx. Driven by the
# `color-picker` Stimulus controller; on change it dispatches a bubbling
# `color-picker:change` { color, name } event a host controller can apply.
# Drop it inside a popover for a swatch-triggered picker.
class Components::UI::ColorPicker < Components::Base
  def initialize(value: "#8b6cff", name: "")
    @value = value
    @name = name
  end

  def view_template
    div(
      class: "flex flex-col gap-2.5 select-none w-[220px] p-3 border border-voodu-border-2 bg-voodu-surface shadow-2xl",
      data: {controller: "color-picker", color_picker_color_value: @value, color_picker_name_value: @name}
    ) do
      spectrum
      hue_rail
      preview_and_hex
    end
  end

  private

  def spectrum
    div(class: "relative overflow-hidden", style: "height: 132px") do
      canvas(
        width: "212", height: "132",
        class: "w-full h-full cursor-crosshair block",
        data: {color_picker_target: "spectrum", action: "mousedown->color-picker#spectrumDown"}
      )
      div(
        class: "pointer-events-none absolute w-3 h-3 rounded-full border-2 border-white -translate-x-1/2 -translate-y-1/2",
        style: "box-shadow: 0 0 0 1.5px rgba(0,0,0,0.45), 0 2px 6px rgba(0,0,0,0.5)",
        data: {color_picker_target: "spectrumThumb"}
      )
    end
  end

  def hue_rail
    div(class: "relative overflow-hidden rounded-full", style: "height: 10px") do
      canvas(
        width: "212", height: "10",
        class: "w-full h-full cursor-pointer block",
        data: {color_picker_target: "hue", action: "mousedown->color-picker#hueDown"}
      )
      div(
        class: "pointer-events-none absolute top-1/2 w-3.5 h-3.5 rounded-full border-2 border-white -translate-x-1/2 -translate-y-1/2",
        style: "box-shadow: 0 0 0 1px rgba(0,0,0,0.35), 0 2px 4px rgba(0,0,0,0.4)",
        data: {color_picker_target: "hueThumb"}
      )
    end
  end

  def preview_and_hex
    div(class: "flex items-center gap-2") do
      div(
        class: "shrink-0 w-7 h-7 rounded border border-voodu-border-2",
        data: {color_picker_target: "preview"}
      )
      div(class: "relative flex-1 min-w-0") do
        span(class: "absolute left-2.5 top-1/2 -translate-y-1/2 text-[10px] text-voodu-muted-2 pointer-events-none") { "#" }
        input(
          type: "text", maxlength: "6", spellcheck: "false",
          autocomplete: "off", placeholder: "FFFFFF",
          class: "w-full pl-5 pr-2 h-8 text-[11.5px] font-voodu-mono uppercase bg-voodu-surface-2 " \
                 "border border-voodu-border text-voodu-text placeholder:text-voodu-muted-2 " \
                 "focus:outline-none focus:border-voodu-accent-line",
          data: {color_picker_target: "hex", action: "input->color-picker#onHex"}
        )
      end
    end
  end
end
