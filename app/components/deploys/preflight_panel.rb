# frozen_string_literal: true

# The preflight: four questions, four answers, before the first push.
#
# WHY IT IS A BUTTON AND NOT AUTOMATIC. The box has to reach GitHub to answer,
# so running it on every render would spend a request each time somebody clicks
# a card. It is also the wrong shape: a preflight is something you RUN, and a
# result that appears without being asked for is a result nobody trusts as
# current.
#
# WHY FOUR ANSWERS AND NOT ONE. Each failure has a different fix — a firewall,
# an expired token, a paused trigger, a missing file — and "preflight failed"
# names none of them. The one time an operator will fix their configuration
# willingly is while they are looking at this screen having just connected;
# finding out on the Friday a deploy did not happen is the same information at
# the worst possible moment.
class Components::Deploys::PreflightPanel < Components::Base
  FRAME = "deploy-preflight"

  def initialize(data:, run: false)
    @data = data
    @run = run
    @repo = data.selected
  end

  def view_template
    turbo_frame_tag(FRAME) do
      @run ? result : prompt
    end
  end

  private

  def prompt
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 " \
               "border border-voodu-border bg-voodu-surface px-3.5 py-2.5") do
      div(class: "flex flex-col basis-full vmd:basis-auto vmd:flex-1 min-w-0") do
        span(class: "text-[12.5px] font-medium text-voodu-text") { "Check this deploy before the first push" }
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "Asks the box whether it reaches GitHub, can run containers, and found a usable file."
        end
      end

      # Never prefetched: this href makes the box call GitHub. Hovering a list
      # of repositories would run a preflight per row.
      render Components::UI::Button.new(
        tag: :a, href: preflight_deploys_path(repo: @repo.full_name),
        variant: :secondary, size: :sm, class: "shrink-0",
        data: {turbo_prefetch: "false"}
      ) do
        render Icon::ShieldCheckOutline.new(class: "w-3.5 h-3.5")
        span { "Run preflight" }
      end
    end
  end

  def result
    preflight = @data.preflight

    return no_trigger if preflight.nil?
    return failed(preflight) if preflight.failed?

    div(class: "border #{result_border(preflight)} px-3.5 py-3 flex flex-col gap-2") do
      summary(preflight)

      div(class: "flex flex-col gap-1.5") do
        preflight.checks.each { |check| check_row(check) }
      end

      rerun
    end
  end

  def result_border(preflight)
    # Green as a RULE, red with a faint fill. A passing preflight is
    # reassurance and should not shout; a failing one is the thing on this
    # panel that must catch the eye before it is read.
    preflight.ok? ? "border-l-2 border-l-voodu-green" : "border-l-2 border-l-voodu-red bg-voodu-red-dim"
  end

  def summary(preflight)
    div(class: "flex flex-wrap items-center gap-2") do
      if preflight.ok?
        span(class: "text-[12.5px] font-medium text-voodu-green") { "Ready to deploy" }
      else
        span(class: "text-[12.5px] font-medium text-voodu-red") do
          "#{preflight.failing.size} of #{preflight.checks.size} checks failed"
        end
      end

      if preflight.branch.present?
        span(class: "font-voodu-mono text-[11.5px] text-voodu-muted") { preflight.branch }
      end
    end
  end

  # The detail is shown on the FAILURES only. A passing check with an
  # explanation beside it reads as a caveat, and four of those turn a green
  # result into something the operator has to squint at.
  def check_row(check)
    div(class: "flex items-start gap-2 min-w-0") do
      if check.ok
        render Icon::CheckCircleOutline.new(class: "w-4 h-4 shrink-0 mt-px text-voodu-green")
      else
        render Icon::XCircleOutline.new(class: "w-4 h-4 shrink-0 mt-px text-voodu-red")
      end

      div(class: "flex flex-col min-w-0") do
        span(class: "text-[12.5px] text-voodu-text-2") { check.label }

        if !check.ok && check.detail.present?
          span(class: "text-[11.5px] text-voodu-muted break-words") { check.detail }
        end
      end
    end
  end

  def rerun
    a(href: preflight_deploys_path(repo: @repo.full_name),
      data: {turbo_prefetch: "false"},
      class: "self-start text-[11.5px] text-voodu-link underline") { "Run again" }
  end

  # Nothing to preflight yet, and saying so beats a button that answers "no
  # trigger". The panel above already carries the command that creates one.
  def no_trigger
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-2.5") do
      span(class: "text-[12.5px] text-voodu-text-2") do
        "There is no trigger for #{@repo.full_name} on this server yet — create one first."
      end
    end
  end

  def failed(preflight)
    render Components::UI::Callout.new(tone: :warning, title: "Could not run the preflight") do
      span(class: "text-[12px] text-voodu-text-2") { preflight.error.to_s }
      rerun
    end
  end
end
