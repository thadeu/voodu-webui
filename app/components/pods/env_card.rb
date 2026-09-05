# frozen_string_literal: true

# Components::Pods::EnvCard — a pod's environment: the KEYS, and nothing else.
#
# ## The values are not in this markup
#
# Not in a hidden span, not in a `data-value` attribute, not in a copy button's
# payload. The card ships names and masks; the real value arrives only when
# somebody clicks the eye, as a fetch into that row's own turbo frame.
#
# The card used to do the opposite — ship every value and hide them with CSS —
# and that is worth naming because it looked identical on screen. It was not:
# one script, one browser extension, one "inspect element", or one page scrape
# read the entire environment of the container without clicking anything. A
# mask over data already handed out is theatre.
#
# TWO THINGS THIS COSTS, both accepted:
#
#   - the filter matches KEYS only. A page that carries every secret so its
#     search box can find them is a page that carries every secret.
#   - there is no "reveal all". It would be a request per row to undo the
#     property this card exists for.
#
# ## Two origins, one list
#
# The container's env mixes variables the IMAGE declares (PATH, LANG) with
# variables an operator set through voodu. The payload does not distinguish
# them, so `config_keys` is fetched separately and each row is badged.
#
# Only voodu's own get a pencil. A row from the image gets none: an inline
# button there would look like editing and would in fact be CREATING a config
# key that shadows the image permanently, including across future images. That
# act is still available — through **Add**, with the same name, where the
# drawer says what is about to happen — but it should cost the deliberate path
# rather than sit under a pencil on every row.
class Components::Pods::EnvCard < Components::Base
  # A FIXED mask, identical on every row. The old one drew one bullet per
  # character, which told a reader how long each secret was: eight bullets
  # beside a token field says "that is not the token you think it is".
  MASK = "•" * 12

  # config_keys is nil when NOT ASKED — a third state, distinct from "asked and
  # it is not a config key". The drawer variant of the pod page does not spend
  # a round trip on provenance, and labelling every row "image" there would be
  # stating something never checked. No badge is drawn when it is nil.
  def initialize(pod:, pod_name: nil, config_keys: nil, editable: false)
    @pod = pod
    @pod_name = pod_name
    @config_keys = config_keys
    @editable = editable
  end

  def view_template
    entries = sorted_env

    card = Components::UI::SectionCard.new(title: "Environment · #{entries.size}", scroll: true)
    card.with_action { add_button }

    render card do
      # kv-filter alone now. The reveal used to live here too, as a Stimulus
      # controller toggling hidden spans — which only worked because every
      # value was already in the page. It is a fetch now, so there is nothing
      # left for it to toggle.
      div(data: {controller: "kv-filter"},
        class: "relative #{Components::UI::SectionCard::SCROLL_CHAIN}") do
        # The filter bar stays OUTSIDE the scroll container. A search input
        # that scrolls away from the list it filters is a search input you
        # scroll back up to use.
        filter_bar

        div(class: Components::UI::SectionCard::SCROLL_LIST) { rows(entries) }
      end
    end
  end

  private

  def sorted_env
    h = @pod["env"]
    return [] unless h.is_a?(Hash)

    h.sort_by { |k, _| k.to_s }
  end

  def editable? = @editable && @pod_name.present?

  # A drawer and not an inline row: adding a variable is a name, a value and a
  # decision about restarting, and squeezing that into a list row would make
  # the common case (reading) worse to serve the rare one.
  def add_button
    return unless editable?

    render Components::UI::Drawer.new(
      title: "Add a variable",
      src: new_pod_env_path(pod_name: @pod_name),
      open_url: new_pod_env_path(pod_name: @pod_name),
      width: "34vw", min_width: "320px", show_full_page_link: false,
      storage_key: "voodu:drawer-width:pod-env",
      trigger_attrs: {title: "Add a variable", class: header_button_class}
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Add" }
    end
  end

  def filter_bar
    div(class: "flex items-center gap-2 px-3.5 h-9 border-b border-voodu-border bg-voodu-surface") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      input(
        type: "search",
        # Keys only, now that values are not in the page to be searched. Said
        # in the placeholder rather than left for somebody to discover by
        # typing a value and getting nothing.
        placeholder: "filter keys…",
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
      div(data: {kv_filter_target: "list"}) do
        entries.each { |k, v| env_row(k, v) }
      end
      empty_match
    end
  end

  # NO `data-value`. That attribute is how the old filter matched values, and
  # it is also how a scrape read them.
  def env_row(key, value)
    str = value.to_s

    div(data: {kv_filter_target: "row", key: key.to_s.downcase}) do
      row_component(key, str.blank?, str.include?("***"))
    end
  end

  def row_component(key, empty, redacted)
    row = Components::UI::KvRow.new(key: key)

    # The eye sits in the ACTIONS column, beside the badge, and not next to the
    # mask it replaces. A turbo frame can be targeted from anywhere on the
    # page, so nothing about the reveal needs the trigger to live inside the
    # cell it swaps — and every other row on this dashboard puts what you can
    # DO on the right and what you are LOOKING AT on the left. Following that
    # costs nothing and means the eye lands where the eye already went.
    row.with_leading_actions do
      unless empty || redacted
        reveal_link(key)
        edit_trigger(key)
      end

      origin_badge(key)
    end

    render row do
      if empty
        span(class: "text-voodu-muted-2") { "(empty)" }
      elsif redacted
        # The box already refused to send this one. Nothing to reveal.
        span(class: "text-voodu-amber") { "***" }
      else
        value_frame(key)
      end
    end
  end

  # The mask alone. What replaces it arrives from the eye in the actions
  # column, which targets this frame by id.
  #
  # data-turbo-permanent LIVES HERE, on the frame the card renders, and that
  # placement is the whole fix rather than a detail.
  #
  # The pod body sits in a frame that reloads on every state tick with
  # `refresh: "morph"`. Morph skips nodes carrying an id and this attribute —
  # so without it, a value revealed at second 28 was replaced by the mask at
  # second 30, mid-read.
  #
  # Putting the attribute on the REVEALED frame instead does nothing, which is
  # the part that is easy to get wrong: Turbo's FrameRenderer replaces a
  # frame's CONTENTS (`selectNodeContents` + `extractContents`) and never
  # copies the response frame's attributes onto the live element. The element
  # in the DOM is always the one below, so the attribute has to be on it.
  #
  # Pinning the masked cell too costs nothing: its content is either a mask,
  # which has nothing to update, or a value somebody asked to see, which must
  # not be taken away. A row that appears or disappears is still added and
  # removed normally — permanence only stops a node being morphed in place.
  def value_frame(key)
    turbo_frame_tag(Views::PodEnv::Value.frame_id(key), data: {turbo_permanent: true}) do
      span(class: "select-none text-voodu-muted font-voodu-mono text-[12px]") { MASK }
    end
  end

  def reveal_link(key)
    return if @pod_name.blank?

    # data-turbo-prefetch false as well as the global meta tag: this href
    # returns a secret, and it must not start being fetched on hover because
    # somebody later decided prefetch was worth re-enabling site-wide.
    a(href: reveal_pod_env_path(pod_name: @pod_name, key: key),
      data: {turbo_frame: Views::PodEnv::Value.frame_id(key), turbo_prefetch: "false"},
      title: "Reveal #{key}", "aria-label": "Reveal #{key}",
      class: "inline-flex items-center justify-center w-5 h-5 text-voodu-muted " \
             "hover:text-voodu-text no-underline shrink-0") do
      render Icon::EyeOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # origin_badge — where this variable came from, in one word.
  #
  # Without it the pencil's absence on half the rows reads as a bug rather than
  # as a statement about what voodu owns.
  def origin_badge(key)
    return if @config_keys.nil?

    from_config = @config_keys.include?(key.to_s)

    span(
      title: from_config ? "Set through voodu" : "Declared by the container image",
      class: "hidden vmd:inline-flex items-center h-5 px-1.5 text-[10px] " \
             "border #{from_config ? "border-voodu-accent-line text-voodu-accent-2" : "border-voodu-border text-voodu-muted"}"
    ) { from_config ? "config" : "image" }
  end

  # The pencil, ONLY on variables voodu owns. See the class comment for why a
  # row from the image gets no inline action at all.
  def edit_trigger(key)
    return unless editable?
    return unless @config_keys&.include?(key.to_s)

    render Components::UI::Drawer.new(
      title: "Edit #{key}",
      src: edit_pod_env_path(pod_name: @pod_name, key: key),
      open_url: edit_pod_env_path(pod_name: @pod_name, key: key),
      width: "34vw", min_width: "320px", show_full_page_link: false,
      storage_key: "voodu:drawer-width:pod-env",
      trigger_attrs: {title: "Edit #{key}", "aria-label": "Edit #{key}", class: row_button_class}
    ) do
      render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5")
    end
  end

  def header_button_class
    "inline-flex items-center gap-1.5 h-6 px-2 border border-voodu-border " \
      "bg-voodu-surface text-[11.5px] text-voodu-text-2 hover:border-voodu-border-2 no-underline"
  end

  def row_button_class
    "inline-flex items-center justify-center w-5 h-5 text-voodu-muted hover:text-voodu-text no-underline"
  end

  def empty
    div(class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]") { "no environment keys" }
  end

  def empty_match
    div(
      hidden: true,
      data: {kv_filter_target: "empty"},
      class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]"
    ) { "no keys match the filter." }
  end
end
