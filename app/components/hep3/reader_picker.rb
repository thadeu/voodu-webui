# frozen_string_literal: true

# Components::Hep3::ReaderPicker — the "which reader?" step of a /hep3 tab, in
# the card language of the Logs Analytics scope gate (status dot, kind, mono
# name), plus the optional filter for the tab's panels.
#
# The filter is set HERE, once per tab, not over the panels: on the panel page
# it crowded the chart and the table for an edit that happens rarely. "Change
# reader" comes back here with the filter filled in.
#
# A GET form: each card is a radio (`reader=scope:name`, split and redirected
# to scope/name by Hep3Controller#index), so the selected look is pure CSS
# (`has-[:checked]`) and Apply / Cmd+Enter submit both choices together. The
# window and tab ride as hidden fields so a pick never resets them.
class Components::Hep3::ReaderPicker < Components::Base
  CARD = "group relative flex flex-col gap-1.5 min-w-0 p-3 border cursor-pointer select-none transition-colors " \
         "border-voodu-border bg-voodu-surface hover:bg-voodu-surface-2 hover:border-voodu-border-2 " \
         "has-[:checked]:border-voodu-accent-line has-[:checked]:bg-voodu-accent-dim " \
         "has-[:focus-visible]:outline has-[:focus-visible]:outline-1 has-[:focus-visible]:outline-voodu-accent"

  def initialize(readers:, hidden_params: {}, filter_query: "", fields: [])
    @readers = Array(readers)
    @hidden_params = hidden_params
    @filter_query = filter_query.to_s
    @fields = fields
  end

  def view_template
    form(method: "get", action: hep3_path, class: "@container w-full pt-2 vmd:pt-4 flex flex-col gap-5") do
      @hidden_params.each { |name, value| input(type: "hidden", name: name.to_s, value: value.to_s) }

      intro
      reader_grid
      filter_section
      picker_footer
    end
  end

  private

  def intro
    div(class: "flex items-start gap-3") do
      span(class: "inline-flex items-center justify-center w-8 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 shrink-0") do
        render Icon::PhoneArrowUpRightOutline.new(class: "w-4 h-4")
      end

      div(class: "flex flex-col gap-0.5 min-w-0") do
        h2(class: "m-0 text-[14px] font-semibold text-voodu-text") { "Which reader do you want to see?" }
        p(class: "m-0 text-[12px] text-voodu-muted leading-relaxed") do
          plain "Select the HEP3 reader. The count and the table show the calls it captured in the selected time range."
        end
      end
    end
  end

  def reader_grid
    div(class: "flex flex-col gap-2.5") do
      section_title("Readers")

      div(class: "grid grid-cols-1 @md:grid-cols-2 @2xl:grid-cols-3 @4xl:grid-cols-4 gap-2") do
        @readers.each { |reader| reader_card(reader) }
      end
    end
  end

  def reader_card(reader)
    label(class: CARD, title: "#{reader[:scope]} · #{reader[:name]}") do
      input(
        type: "radio",
        name: "reader",
        value: "#{reader[:scope]}:#{reader[:name]}",
        required: true,
        checked: @readers.size == 1,
        class: "sr-only"
      )

      div(class: "flex items-center gap-1.5 min-w-0") do
        render Components::UI::StatusDot.new(status: reader[:running] ? :running : :stopped, size: 6)
        span(class: "text-[10px] font-voodu-mono uppercase tracking-[0.05em] text-voodu-muted-2 truncate") { reader[:kind] }

        span(class: "ml-auto shrink-0 text-voodu-accent-2 invisible group-has-[:checked]:visible") do
          render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        end
      end

      span(class: "text-[12.5px] font-semibold font-voodu-mono text-voodu-text truncate leading-tight") { reader[:name] }
      span(class: "text-[10.5px] font-voodu-mono text-voodu-muted truncate leading-tight") { reader_meta(reader) }
    end
  end

  def filter_section
    div(class: "flex flex-col gap-2.5") do
      section_title("Filter", note: "optional")

      render Components::UI::QueryEditor.new(
        value: @filter_query,
        name: "q",
        placeholder: "filter @to_user like /5511/",
        rows: "2",
        min_h: "min-h-[64px]",
        fields: @fields
      )
    end
  end

  def picker_footer
    div(class: "flex flex-col vmd:flex-row vmd:items-center vmd:justify-end gap-2.5 vmd:gap-3") do
      span(class: "hidden vmd:inline text-[11px] text-voodu-muted-2 shrink-0") { "⌘/Ctrl + Enter" }

      button(
        type: "submit",
        class: "inline-flex items-center justify-center gap-1.5 px-5 h-9 vmd:h-8 w-full vmd:w-auto shrink-0 " \
               "border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium " \
               "hover:bg-voodu-accent/20 transition-colors"
      ) do
        render Icon::PlayOutline.new(class: "w-3.5 h-3.5")
        span { "Apply" }
      end
    end
  end

  def section_title(text, note: nil)
    div(class: "flex items-center gap-2.5") do
      span(class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted shrink-0") { text }
      span(class: "text-[10px] text-voodu-muted-2 shrink-0") { note } if note
      span(class: "flex-1 h-px bg-gradient-to-r from-voodu-border to-transparent")
    end
  end

  def reader_meta(reader)
    replicas = (reader[:replicas] == 1) ? "1 replica" : "#{reader[:replicas]} replicas"

    "#{reader[:scope]} · #{replicas}"
  end
end
