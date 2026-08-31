# frozen_string_literal: true

# Components::UI::UpsellCard — the paid option, offered beside the free one.
#
# Both installation screens have the same shape: the left column is what you
# HAVE, and until now the right one was empty on a wide display. What belongs
# there is what you could have — an operator running the free tier has no way to
# discover the paid tier exists, and a product nobody knows is for sale is not
# on sale.
#
# Deliberately restrained. It is an advertisement inside a tool somebody is
# using to run their infrastructure, so it reads as a card like the ones beside
# it rather than as a banner: same border, same header, one accent button. The
# accent is spent on the single action, and nothing else in here competes for
# it.
#
# Every link leaves the app, so each is marked as such — rel="noopener" because
# target="_blank" without it hands the opened page a handle on this one.
class Components::UI::UpsellCard < Components::Base
  def initialize(title:, headline:, blurb:, features:, primary:,
    secondary: nil, alternate: nil, price: nil, footnote: nil)
    @title = title
    @headline = headline
    @blurb = blurb
    @features = features
    @primary = primary
    @secondary = secondary
    @alternate = alternate
    @price = price
    @footnote = footnote
  end

  def view_template
    render Components::UI::SectionCard.new(title: @title) do
      div(class: "flex flex-col gap-3.5 p-3.5") do
        pitch
        feature_list
        price_line
        actions
        alternate_line
        footnote_line
      end
    end
  end

  private

  def pitch
    div(class: "flex flex-col gap-1.5") do
      h3(class: "m-0 text-[15px] font-semibold text-voodu-text") { @headline }
      p(class: "m-0 text-[12.5px] leading-relaxed text-voodu-muted") { @blurb }
    end
  end

  # Checkmarks rather than bullets: each line is something you GET, and a list
  # of dots reads as specification where this is meant to read as a promise.
  def feature_list
    ul(class: "flex flex-col gap-1.5 m-0 p-0 list-none") do
      @features.each do |feature|
        li(class: "flex items-start gap-2 text-[12.5px] text-voodu-text-2") do
          render Icon::CheckOutline.new(class: "w-3.5 h-3.5 mt-0.5 shrink-0 text-voodu-accent")
          span(class: "min-w-0") { feature }
        end
      end
    end
  end

  # Stacks under vmd: at 360px two side-by-side buttons would each be too narrow
  # to read, and full-width stacked ones are easier to hit anyway.
  def actions
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 pt-0.5") do
      render Components::UI::Button.new(
        tag: :a, href: @primary[:href], variant: :primary,
        target: "_blank", rel: "noopener",
        class: "w-full vmd:w-auto"
      ) { @primary[:label] }

      if @secondary
        render Components::UI::Button.new(
          tag: :a, href: @secondary[:href], variant: :secondary,
          class: "w-full vmd:w-auto"
        ) { @secondary[:label] }
      end
    end
  end

  # Between the list and the button, which is where someone decides. The words
  # around the figure stay in the caller — only the typography is decided here —
  # and the amount is mono, like every other number in this app.
  #
  # `lead` carries its own weight: "From" is the difference between a price and
  # a promise, and a card that quotes an entry figure without saying so is the
  # kind of thing a buyer holds against you later.
  def price_line
    return if @price.nil?

    # Inline flow with REAL spaces, not flex with a gap. Flex made each part its
    # own box, so the accessible text ran together as "From$9per month" — the
    # gap is a visual separator and a screen reader never sees it. Inline also
    # wraps and baseline-aligns on its own, which is what this line wanted.
    div(class: "flex flex-col gap-0.5") do
      if @price[:free]
        p(class: "m-0 text-[12.5px] text-voodu-text-2") do
          span(class: "font-semibold text-voodu-text") { @price[:free][:amount] }
          plain " #{@price[:free][:scope]}"
        end
      end

      p(class: "m-0 text-[12.5px] text-voodu-muted") do
        plain "#{@price[:lead]} "
        span(class: "font-voodu-mono text-[16px] font-semibold text-voodu-text") { @price[:amount] }
        plain " #{@price[:cadence]}"
      end
    end
  end

  # The second way in, under the button rather than beside it.
  #
  # A text link and not a second Button: two filled controls of equal weight
  # make the reader choose before they have read either, and these two are not
  # equal — one explains, the other commits. The quiet treatment is what says
  # "if you already know, skip ahead".
  def alternate_line
    return if @alternate.nil?

    p(class: "m-0 text-[12px] text-voodu-muted") do
      plain "#{@alternate[:lead]} "
      a(
        href: @alternate[:href], target: "_blank", rel: "noopener",
        class: "text-voodu-text-2 underline underline-offset-2 " \
               "hover:text-voodu-text transition-colors"
      ) { @alternate[:label] }
    end
  end

  def footnote_line
    return if @footnote.nil?

    p(class: "m-0 text-[11.5px] text-voodu-muted-2") { @footnote }
  end
end
