# frozen_string_literal: true

# The tab rail: the two halves of VooduCD, on one screen.
#
# ICON ONLY, with a tooltip, and that is a size decision rather than a
# minimalist one. With two items a labeled rail spends ~150px of every
# viewport to say two words the icons already say — and the content beside it
# is a three-column repository browser and a six-column table, both of which
# want that width more than the rail does.
#
# The two halves are CONFIGURATION and OPERATIONS: which repositories deploy
# here, and what happened when they did. Read at different times, by people
# asking different questions, which is why they are tabs rather than one long
# page — but one screen, because the answer to "did my push land" starts on
# one and ends on the other.
class Components::Deploys::Rail < Components::Base
  TABS = [
    {id: :repositories, label: "Repositories", icon: :FolderOutline},
    {id: :deployments, label: "Deployments", icon: :QueueListOutline},
    # Last, because it is the one you open when the other two disagree with
    # what you expected: the deliveries that arrived, and what we did with
    # each. On a working installation nobody looks here.
    {id: :webhooks, label: "Webhooks", icon: :BoltOutline}
  ].freeze

  def initialize(active:)
    @active = active.to_sym
  end

  # A horizontal strip below the breakpoint, a vertical rail above it. Two
  # icons in a column is fine beside content; at 360px it is a column of
  # nothing next to a squeezed table.
  def view_template
    nav(
      # FULL HEIGHT above the breakpoint, so the divider runs the length of the
      # content instead of stopping under the second icon. A rail that ends
      # two rows down reads as a floating button group; one that runs the whole
      # way reads as a sub-sidebar, which is what it is.
      class: "flex vmd:flex-col gap-1 shrink-0 vmd:self-stretch " \
             "vmd:border-r vmd:border-voodu-border vmd:pr-2 vmd:mr-1",
      "aria-label": "Deploys sections"
    ) do
      TABS.each { |tab| item(tab) }
    end
  end

  private

  def item(tab)
    active = @active == tab[:id]

    # `relative` + a named group so the tooltip can position against THIS item
    # and react to its hover without the nav's own hover firing all of them.
    # A NAMED group. The unnamed one is spoken for elsewhere on the page (the
    # sidebar's collapsed state reads it), and sharing it would make one item's
    # hover look like every item's.
    div(class: "relative group/rail vmd:self-start") do
      # `title` stays as well. The drawn tooltip is the good one; the native
      # one is what still names the tab if a stylesheet fails to load, which on
      # an icon-only rail is the difference between slow and unusable.
      a(href: href_for(tab[:id]), title: tab[:label], "aria-label": tab[:label],
        "aria-current": (active ? "page" : nil), class: item_class(active)) do
        render Icon.const_get(tab[:icon]).new(class: "w-4 h-4")

        # The label is drawn inline on the horizontal strip: on a phone the
        # rail sits above the content with room to spare, and a tooltip is not
        # reachable without a mouse.
        span(class: "vmd:hidden text-[12px]") { tab[:label] }
      end

      render Components::UI::Tooltip.new(
        label: tab[:label], group: "rail", visible_when: "hidden vmd:block"
      )
    end
  end

  def item_class(active)
    base = "flex items-center gap-2 h-9 px-2.5 vmd:w-9 vmd:px-0 vmd:justify-center " \
           "border no-underline transition-colors "

    base + if active
      "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
    else
      "border-transparent text-voodu-muted hover:bg-voodu-hover hover:text-voodu-text"
    end
  end

  def href_for(id)
    case id
    when :repositories then deploys_repositories_path
    when :deployments then deploys_deployments_path
    else deploys_webhooks_path
    end
  end
end
