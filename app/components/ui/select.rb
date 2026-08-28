# frozen_string_literal: true

# Components::UI::Select — the design-system single-select.
#
# A native <select> renders the OS widget, which ignores every token in the
# theme and looks like a different application dropped into the page. This is
# the same trigger + hidden input + menu the alert-rule form has always used,
# lifted out of it so there is one implementation instead of two: `dropdown`
# owns open/close (and the filter once the list is long), `ds-select` syncs the
# pick into the hidden input, updates the label and the ✓, and dispatches a
# `change` event so anything listening on the input still fires.
#
#   render Components::UI::Select.new(
#     name: "role", selected: "member",
#     options: [["member", "member"], ["admin", "admin"]]
#   )
#
# `options` is [[value, label], …]. `selected` is compared with `==`, so
# integer values work as well as strings.
class Components::UI::Select < Components::Base
  # Above this many options the menu grows a filter box — the same threshold
  # the metrics pickers use, so the two feel like one control.
  FILTER_THRESHOLD = 6

  def initialize(name:, options:, selected: nil, placeholder: "Select…", input_data: {}, **attrs)
    @name = name
    @options = options
    @selected = selected
    @placeholder = placeholder
    @input_data = input_data
    @attrs = attrs
  end

  def view_template
    div(class: tokens("relative", @attrs[:class]), data: {controller: "dropdown ds-select"}) do
      input(
        type: "hidden", name: @name, value: @selected,
        data: {ds_select_target: "input"}.merge(@input_data)
      )

      trigger
      menu
    end
  end

  private

  def current
    @current ||= @options.find { |value, _| value == @selected }
  end

  def trigger
    button(
      type: "button",
      data: {action: "click->dropdown#toggle"},
      class: tokens(input_classes, "flex items-center gap-2 text-[13px] cursor-pointer")
    ) do
      span(data: {ds_select_target: "label"}, class: "flex-1 min-w-0 truncate text-left") do
        current ? current[1] : @placeholder
      end
      render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
    end
  end

  def menu
    div(hidden: true, data: {dropdown_target: "menu"}, class: menu_classes) do
      dropdown_filter("Filter…") if @options.size > FILTER_THRESHOLD
      @options.each { |value, text| option(value, text) }
      dropdown_empty if @options.size > FILTER_THRESHOLD
    end
  end

  def option(value, text)
    active = value == @selected

    button(
      type: "button",
      data: {
        action: "click->ds-select#pick click->dropdown#close",
        dropdown_target: "option", ds_select_target: "option",
        value: value, label: text, active: active.to_s
      },
      class: "group flex items-center gap-2 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] " \
             "text-voodu-text hover:bg-voodu-hover data-[active=true]:text-voodu-accent-2"
    ) do
      span(class: "w-3.5 shrink-0 text-voodu-accent-2 opacity-0 group-data-[active=true]:opacity-100") { "✓" }
      span(class: "flex-1 min-w-0 truncate") { text }
    end
  end

  def menu_classes
    "absolute left-0 top-[calc(100%+4px)] z-30 min-w-full w-max max-w-[320px] max-h-[300px] " \
      "overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
  end
end
