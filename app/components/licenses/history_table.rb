# frozen_string_literal: true

# Every licence this installation has run under.
#
# The rows were always being written — one per activation, with the subject, its
# dates and who pasted it — and nothing displayed them. What they answer is the
# question support actually gets asked: when did this become Enterprise, under
# whose name, and who did it.
#
# Same shape as Components::Orgs::MembersTable, including the kv-filter bar: a
# renewal a year is a short list until it is not, and a filter that appears only
# once a table is already unusable is a filter added too late.
class Components::Licenses::HistoryTable < Components::Base
  def initialize(keys:)
    @keys = keys
  end

  def view_template
    div(data: {controller: "kv-filter"}, class: "border border-voodu-border bg-voodu-surface") do
      filter_bar

      div(data: {kv_filter_target: "list"}) do
        @keys.each_with_index { |key, index| history_row(key, current: index.zero?) }
      end

      empty_row
    end
  end

  private

  def filter_bar
    div(class: "flex items-center gap-2 px-3.5 h-9 border-b border-voodu-border") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      input(
        type: "search",
        placeholder: "filter by customer or year…",
        data: {kv_filter_target: "input", action: "input->kv-filter#filter"},
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] " \
               "text-voodu-text placeholder:text-voodu-muted-2"
      )
      span(class: "text-[11px] text-voodu-muted tabular-nums shrink-0") { @keys.size.to_s }
    end
  end

  # Stacks on narrow and goes to a row at the breakpoint. Three fields sharing
  # one line turns a mono subject into one character per line at 360px.
  def history_row(key, current:)
    div(
      data: {
        kv_filter_target: "row",
        key: key.subject.to_s.downcase,
        value: "#{key.expires_at&.year} #{key.created_at.year} #{key.activated_by&.display_name}".downcase
      },
      class: "flex flex-col vmd:flex-row vmd:items-baseline gap-0.5 vmd:gap-4 px-3.5 py-2.5 " \
             "border-b border-voodu-border-2 last:border-b-0"
    ) do
      span(class: "text-[12.5px] font-voodu-mono text-voodu-text truncate vmd:w-40 shrink-0") do
        key.subject
      end

      span(class: "text-[11.5px] text-voodu-muted vmd:flex-1 min-w-0 truncate") { activation_line(key) }

      span(class: "text-[11.5px] font-voodu-mono shrink-0 #{tone(key, current)}") { validity_line(key, current) }
    end
  end

  def activation_line(key)
    plain "activated #{key.created_at.to_date}"
    plain " by #{key.activated_by.display_name}" if key.activated_by
  end

  def validity_line(key, current)
    plain "in force · " if current
    plain key.expired? ? "expired #{key.expires_at.to_date}" : "until #{key.expires_at.to_date}"
  end

  # Only the licence actually in force is worth colouring; a superseded row is
  # history, and expired is what history looks like.
  def tone(key, current)
    return "text-voodu-muted" unless current

    key.expired? ? "text-voodu-red" : "text-voodu-text-2"
  end

  def empty_row
    div(
      hidden: true, data: {kv_filter_target: "empty"},
      class: "px-3.5 py-4 text-[12.5px] text-voodu-muted text-center"
    ) { "No licences match." }
  end
end
