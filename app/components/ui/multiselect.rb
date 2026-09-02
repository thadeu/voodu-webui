# frozen_string_literal: true

# Components::UI::Multiselect — a dropdown backed by REAL checkboxes, so the
# form submits them exactly like a checkbox group. No hidden mirroring, no
# JavaScript needed to make the value correct.
#
# Extracted from the alert-rule form, where it lived as three private methods.
# The `ds-multiselect` Stimulus controller was always shareable; the markup it
# drives was not, so the second caller would have copied it — and a copied
# dropdown is how two pickers in one product start behaving differently.
#
# The empty selection is MEANINGFUL and the caller owns what it means. On a
# filter bar, nothing checked means "no filter, show everything"; on the alert
# form it means "notify nowhere". Hence `empty_label` rather than a built-in
# word: the component does not get to decide.
#
# Usage:
#
#   render Components::UI::Multiselect.new(
#     name: "status[]",
#     options: [{value: "failed", label: "Failed"}],
#     selected: %w[failed],
#     empty_label: "All statuses",
#     group_label: "Status"
#   )
class Components::UI::Multiselect < Components::Base
  # @param name [String] the submitted field name, `[]`-suffixed by the caller
  #   so it reads the same as the markup it produces.
  # @param options [Array<Hash>] {value:, label:, hint: nil}
  # @param selected [Array<String>] values currently picked
  # @param empty_label [String] trigger label when NOTHING is picked
  # @param all_label [String] trigger label when everything is picked; defaults
  #   to empty_label, because for a filter "none selected" and "all selected"
  #   show the same rows and should say the same thing.
  # @param group_label [String] the sticky header beside Select all / Clear
  # @param clear_sentinel [Boolean] emit a blank hidden input so an
  #   all-unchecked submit still sends the key. Needed by forms that UPDATE a
  #   record (an omitted key leaves the column unchanged); wrong for a GET
  #   filter, where an empty key would litter the URL.
  def initialize(name:, options:, selected: [], empty_label: "All", all_label: nil,
    group_label: nil, clear_sentinel: false, trigger_class: nil)
    @name = name
    @options = options
    @selected = Array(selected).map(&:to_s)
    @empty_label = empty_label
    @all_label = all_label || empty_label
    @group_label = group_label
    @clear_sentinel = clear_sentinel
    @trigger_class = trigger_class
  end

  def view_template
    div(
      class: "relative",
      data: {
        controller: "dropdown ds-multiselect",
        ds_multiselect_empty_label_value: @empty_label,
        ds_multiselect_all_label_value: @all_label
      }
    ) do
      trigger
      menu
    end
  end

  private

  def trigger
    button(
      type: "button",
      data: {action: "click->dropdown#toggle"},
      class: tokens(
        @trigger_class || tokens(input_classes, "h-8"),
        "flex items-center gap-2 text-[12px] cursor-pointer"
      )
    ) do
      # Server-rendered so there is no flash of the wrong word before
      # ds-multiselect#connect recomputes it.
      span(data: {ds_multiselect_target: "label"}, class: "flex-1 min-w-0 truncate text-left") do
        trigger_label
      end

      render Icon::ChevronDownOutline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
    end
  end

  def menu
    div(hidden: true, data: {dropdown_target: "menu"}, class: menu_classes) do
      if @clear_sentinel
        input(type: "hidden", name: @name, value: "")
      end

      group_header if @group_label

      @options.each { |option| option_row(option) }
    end
  end

  def group_header
    button(
      type: "button",
      data: {action: "ds-multiselect#toggleAll"},
      class: "flex items-center justify-between gap-2 w-full px-3 py-2 border-b border-voodu-border-2 " \
             "text-left text-[11.5px] text-voodu-text-2 hover:bg-voodu-surface-2 sticky top-0 bg-voodu-surface"
    ) do
      span(class: "uppercase tracking-[0.05em] text-voodu-muted-2") { @group_label }
      span(data: {ds_multiselect_target: "selectAllLabel"}, class: "text-voodu-link") { "Select all" }
    end
  end

  def option_row(option)
    value = option[:value].to_s

    label(
      class: "flex items-center gap-2.5 w-full px-3 py-2 cursor-pointer hover:bg-voodu-surface-2 " \
             "text-[12.5px] text-voodu-text-2 border-b border-voodu-border-2 last:border-b-0"
    ) do
      input(
        type: "checkbox", name: @name, value: value, checked: @selected.include?(value),
        data: {
          ds_multiselect_target: "option",
          label: option[:label],
          action: "change->ds-multiselect#sync"
        },
        class: "w-3.5 h-3.5 accent-voodu-accent"
      )

      span(class: "truncate") { option[:label] }

      if option[:hint].present?
        span(class: "text-[10px] uppercase tracking-[0.05em] text-voodu-muted-2 ml-auto shrink-0") do
          option[:hint]
        end
      end
    end
  end

  def trigger_label
    return @empty_label if @selected.empty?
    return @all_label if @selected.size == @options.size

    if @selected.size == 1
      picked = @options.find { |o| o[:value].to_s == @selected.first }

      return picked ? picked[:label] : @selected.first
    end

    "#{@selected.size} selected"
  end

  def menu_classes
    "absolute left-0 top-[calc(100%+4px)] z-30 min-w-full w-max max-w-[320px] max-h-[300px] " \
      "overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
  end
end
