# frozen_string_literal: true

# Advisories — the standing warnings that belong above every page.
#
# One component rather than one per warning, because they stack: an install can
# be anonymous AND reached from outside AND running Postgres without a licence,
# and three sibling components in the layout would each have to know about the
# others to avoid a wall of red.
#
# None of these are dismissable. A banner you can close is a banner that gets
# closed, and every condition here describes something that is still true after
# you stop looking at it. The way to silence one is to fix what it describes.
class Components::Layouts::Advisories < Components::Base
  def view_template
    perimeter_advisory if perimeter_warning?
    postgres_advisory if unlicensed_postgres?
  end

  private

  # Anonymous mode reached from a public address. Whoever arrives is an owner,
  # and owners reveal PATs — which are the controllers themselves, not charts.
  def perimeter_advisory
    advisory(:danger, "No sign-in required") do
      plain "This request came from a public address. Anyone who reaches this port is an " \
            "operator and can read every server's access token. Put a VPN or an access proxy " \
            "in front of it, or set "
      code(class: "font-voodu-mono text-[11.5px] text-voodu-text") { "VOODU_TRUSTED_PERIMETER=1" }
      plain " if one is already there."
    end
  end

  # Postgres in use without an entitlement. Deliberately a notice and not a
  # refusal: the control plane already lives in that database, and an app that
  # declined to read it would not be enforcing a licence, it would be locking
  # the operator out of their own data. Enforcement here is the licence terms,
  # and what the product owes is to make the state impossible to miss.
  def postgres_advisory
    advisory(:warn, "Postgres without a licence") do
      plain "This installation stores its control plane in Postgres, which the Elastic " \
            "License 2.0 covers under an Enterprise licence. Nothing has been restricted — " \
            "see Settings for the current plan."
    end
  end

  def advisory(tone, title)
    colour = (tone == :danger) ? "red" : "amber"

    div(
      role: "alert",
      class: "flex flex-col vmd:flex-row vmd:items-center gap-1.5 vmd:gap-3 px-4 py-2.5 " \
             "border-b border-voodu-#{colour}/40 bg-voodu-#{colour}/10"
    ) do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::ExclamationTriangleOutline.new(class: "w-4 h-4 shrink-0 text-voodu-#{colour}")
        span(class: "text-[12.5px] font-semibold text-voodu-#{colour} shrink-0") { title }
      end

      span(class: "text-[12px] text-voodu-text-2 min-w-0") { yield }
    end
  end
end
