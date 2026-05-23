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
# Inside each bucket alphabetical. Bypass otherwise: every key the
# JSON ships shows up here as-is, with a copy button.
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
        entries.each { |k, v| label_row(k, v) }
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

  def label_row(key, value)
    str = value.to_s
    pair = "#{key}=#{str}"

    render Components::UI::KvRow.new(key: key, copy: true, copy_value: pair) do
      if str.blank?
        span(class: "text-voodu-muted-2") { "(empty)" }
      else
        plain str
      end
    end
  end
end
