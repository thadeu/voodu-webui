# frozen_string_literal: true

# Components::Pods::EnvCard — pod environment variables, alphabetised.
#
# Header has an inline filter input (Stimulus `kv-filter` controller)
# that hides KvRows whose key OR value doesn't match. No round-trip —
# whole list is in the DOM, filtering is local.
#
# Values containing `***` (the PAT plane redaction marker for
# secrets) render in amber so the operator immediately sees what was
# scrubbed.
class Components::Pods::EnvCard < Components::Base
  def initialize(pod:)
    @pod = pod
  end

  def view_template
    entries = sorted_env

    card = Components::UI::SectionCard.new(title: "Environment · #{entries.size}")
    card.with_action { period_chip(entries.size) }

    render card do
      div(data: { controller: "kv-filter" }) do
        filter_bar
        rows(entries)
      end
    end
  end

  private

  def sorted_env
    h = @pod["env"]
    return [] unless h.is_a?(Hash)

    h.sort_by { |k, _| k.to_s }
  end

  def period_chip(_count)
    # No period selector here — slot left empty for future controls.
  end

  def filter_bar
    div(class: "flex items-center gap-2 px-3.5 h-9 border-b border-voodu-border bg-voodu-bg-2") do
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
    if entries.empty?
      empty
    else
      div(data: { kv_filter_target: "list" }) do
        entries.each { |k, v| env_row(k, v) }
      end
      empty_match
    end
  end

  def env_row(key, value)
    str = value.to_s
    redacted = str.include?("***")
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
        elsif redacted
          span(class: "text-voodu-amber") { plain str }
        else
          plain str
        end
      end
    end
  end

  def empty
    div(class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]") { "no environment keys" }
  end

  def empty_match
    div(
      hidden: true,
      data: { kv_filter_target: "empty" },
      class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]"
    ) { "no keys match the filter." }
  end
end
