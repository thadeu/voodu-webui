# frozen_string_literal: true

# Components::Pods::LabelsCard — every label on the container, in a
# stable order that reflects voodu's hierarchy:
#
#   1. voodu.*                  — our metadata first (the part operators
#                                 actually care about)
#   2. org.opencontainers.*     — OCI image labels
#   3. everything else          — third-party labels (createdby, app-
#                                 specific, etc.) at the bottom
#
# Inside each bucket: alphabetical. Bypass otherwise — every key the
# JSON ships shows up here as-is, with a copy button.
#
# Header has an inline filter input (Stimulus `kv-filter`) that hides
# rows whose key OR value doesn't match. No round-trip — the whole
# list is in the DOM, filtering is local.
class Components::Pods::LabelsCard < Components::Base
  def initialize(pod:)
    @pod = pod
  end

  def view_template
    entries = sorted_labels

    render Components::UI::SectionCard.new(title: "Labels · #{entries.size}") do
      if entries.empty?
        div(class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]") { "no labels" }
      else
        div(data: { controller: "kv-filter" }) do
          filter_bar
          rows(entries)
        end
      end
    end
  end

  private

  def sorted_labels
    h = @pod["labels"]
    return [] unless h.is_a?(Hash)

    h.sort_by { |k, _| [bucket(k), k.to_s] }
  end

  # bucket — 0 for voodu.*, 1 for org.opencontainers.*, 2 for the rest.
  def bucket(key)
    return 0 if key.to_s.start_with?("voodu.")
    return 1 if key.to_s.start_with?("org.opencontainers.")

    2
  end

  def filter_bar
    div(class: "flex items-center gap-2 px-3.5 h-9 border-b border-voodu-border bg-voodu-surface") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      input(
        type: "search",
        placeholder: "filter keys or values…",
        data: {
          kv_filter_target: "input",
          action: "input->kv-filter#filter"
        },
        class: "flex-1 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2"
      )
    end
  end

  def rows(entries)
    div(data: { kv_filter_target: "list" }) do
      entries.each { |k, v| label_row(k, v) }
    end
    empty_match
  end

  def label_row(key, value)
    str = value.to_s
    pair = "#{key}=#{str}"

    div(
      data: {
        kv_filter_target: "row",
        key: key.to_s.downcase,
        value: str.downcase
      }
    ) do
      render Components::UI::KvRow.new(key: key, copy: true, copy_value: pair) do
        if str.blank?
          span(class: "text-voodu-muted-2") { "(empty)" }
        else
          plain str
        end
      end
    end
  end

  def empty_match
    div(
      hidden: true,
      data: { kv_filter_target: "empty" },
      class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]"
    ) { "no labels match the filter." }
  end
end
