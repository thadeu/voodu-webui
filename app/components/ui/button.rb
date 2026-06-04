# frozen_string_literal: true

# Components::UI::Button — the workhorse action element.
#
# Five variants tuned for the voodu palette:
#
#   :primary    — purple accent fill (CTAs, "Add island", "Restart")
#   :secondary  — surface fill + border (cancel, secondary actions)
#   :ghost      — no fill, hover lifts background (subtle nav, icon-only)
#   :danger     — red outline (destructive — revoke PAT, delete island)
#   :inversed   — light text on dark for high-contrast pulls
#
# Plus three sizes and four shapes (matching the clowk convention so
# muscle memory carries — square/circular shapes are for icon-only
# buttons).
class Components::UI::Button < Components::Base
  VARIANTS = {
    primary:   "bg-voodu-accent text-voodu-on-accent hover:bg-voodu-accent-2",
    secondary: "bg-voodu-surface text-voodu-text border border-voodu-border hover:bg-voodu-surface-2",
    ghost:     "bg-transparent text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text",
    danger:    "bg-transparent text-voodu-red border border-voodu-red/40 hover:bg-voodu-red-dim",
    inversed:  "bg-voodu-text text-voodu-bg hover:opacity-90"
  }.freeze

  SHAPES = {
    default:  "",
    squared:  "aspect-square !px-0 justify-center",
    rounded:  "!rounded-full",
    circular: "!rounded-full aspect-square !px-0 justify-center"
  }.freeze

  SIZES = {
    sm: "px-3 py-1.5 text-xs rounded-voodu-md",
    md: "px-4 py-2 text-sm rounded-voodu-md",
    lg: "px-5 py-2.5 text-sm rounded-voodu-lg"
  }.freeze

  def initialize(variant: :primary, size: :sm, shape: :default, tag: :button, type: nil, **attrs)
    @variant  = variant
    @size     = size
    @shape    = shape
    @tag      = tag
    # type:
    #   nil (default) on a <button> → "button" (safe — won't auto-submit
    #                                  a wrapping form, matching most
    #                                  call sites that use it for UI actions)
    #   :submit  → emits type="submit" for form CTAs (Add island, Save, …)
    #   on an <a> tag → omitted (links have no `type`).
    @type     = type
    @disabled = attrs.delete(:disabled) || false
    @attrs    = attrs
  end

  def view_template(&)
    send(@tag,
      class: tokens(
        "inline-flex items-center justify-center gap-2 font-medium cursor-pointer transition-colors duration-150 no-underline",
        VARIANTS.fetch(@variant, VARIANTS[:primary]),
        SIZES.fetch(@size, SIZES[:sm]),
        SHAPES.fetch(@shape, SHAPES[:default]),
        ("opacity-50 pointer-events-none" if @disabled),
        @attrs[:class]
      ),
      disabled: @disabled || nil,
      type: button_type,
      **@attrs.except(:class)) do
      yield if block_given?
    end
  end

  private

  # button_type — caller's `type:` wins; otherwise default to "button"
  # on a <button> tag (so a UI click doesn't accidentally submit a
  # surrounding form), and omit for <a> tags (links have no type).
  def button_type
    return @type.to_s if @type
    return "button" if @tag == :button

    nil
  end
end
