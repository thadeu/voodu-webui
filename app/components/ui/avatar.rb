# frozen_string_literal: true

# Components::UI::Avatar — image with letter fallback.
#
# Adapted from clowk: switched coral gradient for the voodu purple
# accent (gradient feels brand-coherent — the dashboard's only big
# gradient is the logo, this matches it). Falls back to the first
# letter of the supplied name when no URL is given.
class Components::UI::Avatar < Components::Base
  SIZES = {sm: 28, md: 36, lg: 40, xl: 56}.freeze

  def initialize(url: nil, name: "", size: :md, **attrs)
    @url = url
    @name = name.to_s
    @size = size
    @attrs = attrs
  end

  def view_template
    px = SIZES.fetch(@size, 36)
    fallback_class = "rounded-full shrink-0 flex items-center justify-center font-semibold text-voodu-on-accent " \
                     "bg-gradient-to-br from-voodu-accent-2 to-voodu-accent"

    if @url.present?
      div(
        style: "width: #{px}px; height: #{px}px; font-size: #{px * 0.4}px;",
        class: tokens("relative", fallback_class, @attrs[:class])
      ) do
        plain initial
        img(
          src: @url,
          alt: @name,
          class: "absolute inset-0 w-full h-full rounded-full object-cover",
          loading: "lazy"
        )
      end
    else
      div(
        style: "width: #{px}px; height: #{px}px; font-size: #{px * 0.4}px;",
        class: tokens(fallback_class, @attrs[:class]),
        **@attrs.except(:class)
      ) { plain initial }
    end
  end

  private

  def initial
    @name.present? ? @name[0].upcase : "?"
  end
end
