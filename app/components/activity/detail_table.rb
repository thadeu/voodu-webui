# frozen_string_literal: true

# Components::Activity::DetailTable — the labelled key/value table inside an
# expanded activity row.
#
# WHY A TABLE AND NOT THE CHIP ROW IT REPLACES. A wrapping row of
# `statefulset runa/pg` chips reads as five identical blobs: the eye has to
# re-parse each one to find the kind, because nothing lines up. In a column the
# kinds stack and the difference between an `asset` and a `statefulset` is
# visible without reading a single word.
#
# EVERY ACTION GETS ITS OWN COLUMNS, which is the point of this component
# existing rather than one hardcoded resource list. An apply is a set of
# manifests; a config change is a key in a bucket; a rollback is a release.
# Forcing them through one shape means every row shows blanks where the shape
# does not fit, and blanks are what made the panel unreadable.
#
# Renders nothing at all for an empty row set — a caption over an empty table
# is a promise the panel did not keep.
class Components::Activity::DetailTable < Components::Base
  def initialize(caption:, headers:, rows:)
    @caption = caption
    @headers = headers
    @rows = rows
  end

  def view_template
    return if @rows.blank?

    div(class: "flex flex-col gap-1 min-w-0") do
      caption_line
      table_body
    end
  end

  private

  def caption_line
    span(class: "text-[10px] font-semibold uppercase tracking-[0.08em] text-voodu-muted") { @caption }
  end

  # overflow-x-auto rather than a mobile transposition: this table is already
  # inside a disclosure the operator opened on purpose, and three short mono
  # columns scroll far better than they stack.
  def table_body
    div(class: "overflow-x-auto") do
      div(class: "inline-block min-w-full border border-voodu-border bg-voodu-surface") do
        header_row
        @rows.each_with_index { |row, i| body_row(row, i) }
      end
    end
  end

  def header_row
    div(class: "flex items-center gap-4 px-2.5 py-1 border-b border-voodu-border bg-voodu-bg-2") do
      @headers.each_with_index do |header, i|
        span(class: "#{column_class(i)} text-[10px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") do
          header
        end
      end
    end
  end

  def body_row(row, index)
    div(
      class: "flex items-center gap-4 px-2.5 py-1 #{"border-t border-voodu-border-2" if index.positive?}"
    ) do
      row.each_with_index do |value, i|
        span(class: "#{column_class(i)} text-[11px] font-voodu-mono #{value_tone(i)} truncate") do
          value.presence || "—"
        end
      end
    end
  end

  # The first column is the classifier (kind, key) and carries the meaning, so
  # it is the one drawn at full strength; the rest are context.
  def value_tone(index)
    index.zero? ? "text-voodu-text" : "text-voodu-text-2"
  end

  # Fixed widths so header and body align, and the LAST column grows. A name is
  # the one field with no bound — a kind is a short vocabulary and a scope is a
  # word the operator chose.
  def column_class(index)
    (index == @headers.size - 1) ? "flex-1 min-w-[80px]" : "w-[104px] shrink-0"
  end
end
