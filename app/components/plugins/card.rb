# frozen_string_literal: true

# One plugin, as a card.
#
# The card carries its own state because an install is asynchronous: the
# operator clicks Install, the controller answers immediately and keeps
# working, and this card is where they find out what happened. So it has three
# faces — installed, installing, failed — and the failed one has to say WHY,
# because "it didn't work" sends somebody to SSH into the box, which is the
# thing this screen exists to avoid.
#
# The trash sits top-right, away from Install/Update, because the two live in
# different worlds: one is routine and one destroys work. Putting them in the
# same row is how a mis-click happens.
class Components::Plugins::Card < Components::Base
  def initialize(plugin:, server:, manageable:)
    @plugin = plugin
    @server = server
    @manageable = manageable
  end

  def view_template
    article(class: tokens(
      "flex flex-col h-full min-w-0 border transition-colors",
      @plugin.failed? ? "border-voodu-red/40" : "border-voodu-border hover:border-voodu-border-2",
      # Catalogue entries sit back: what this server HAS should be what the eye
      # lands on first, with what it could have available but quieter.
      (@plugin.installed? || @plugin.installing? || @plugin.failed?) ? "bg-voodu-surface" : "bg-voodu-bg-2"
    )) do
      card_head
      card_body
      card_actions
    end
  end

  private

  def card_head
    div(class: "flex items-start gap-2 px-3.5 pt-3.5") do
      div(class: "min-w-0 flex-1 flex flex-col gap-1") do
        div(class: "flex items-baseline gap-2 flex-wrap") do
          h3(class: "m-0 text-[14px] font-semibold text-voodu-text truncate") { @plugin.name }
          version_label
        end
        state_badge
      end

      uninstall_control if @manageable && @plugin.installed?
    end
  end

  def version_label
    label = @plugin.version_label
    return if label.nil?

    span(class: "font-voodu-mono text-[11.5px] text-voodu-muted shrink-0") { label }
  end

  def state_badge
    variant, text = case @plugin.state
    when "installing" then [:info, "installing…"]
    when "failed" then [:danger, "failed"]
    when "available" then [:neutral, "not installed"]
    else [:success, "installed"]
    end

    render Components::UI::Badge.new(variant: variant, class: "self-start") { text }
  end

  def card_body
    div(class: "flex flex-col gap-2 px-3.5 py-3 flex-1 min-w-0") do
      description
      failure_reason if @plugin.failed?
      div(class: "flex-1")
      homepage_link
    end
  end

  # A fixed band, min and max the same.
  #
  # Manifest descriptions run from one line (caddy) to seven (redis), and a
  # grid row stretches to its tallest card — so one verbose plugin dragged
  # every card beside it out of shape and left holes in the layout. Bounding
  # the description is what makes the cards a grid instead of a collage.
  #
  # Overflow scrolls rather than truncating: the text is the only description
  # the operator gets, and an ellipsis would hide the sentence that says what
  # the plugin actually does.
  def description
    text = @plugin.description.presence
    klass = "m-0 text-[12.5px] leading-[1.5] text-voodu-muted " \
            "min-h-[84px] max-h-[84px] overflow-y-auto scrollbar-hidden"

    return p(class: klass) { "No description in this plugin's manifest." } if text.nil?

    p(class: klass, title: text) { text }
  end

  # The whole reason the state lives on the card. Pre-wrapped and scrollable
  # because hook output is a build log, and truncating the one line that names
  # the cause would defeat the point of showing it at all.
  def failure_reason
    reason = @plugin.error.presence || "The controller did not say why."

    div(class: "border border-voodu-red/30 bg-voodu-red-dim px-2.5 py-2 overflow-x-auto") do
      pre(class: "m-0 font-voodu-mono text-[11px] leading-[1.5] text-voodu-text-2 whitespace-pre-wrap break-words") do
        plain reason
      end
    end
  end

  # Absent for a plugin installed from a path on the box, which is a real case
  # — a dead link would be worse than no link.
  def homepage_link
    url = @plugin.homepage_url
    return if url.nil?

    a(
      href: url, target: "_blank", rel: "noopener",
      class: "inline-flex items-center gap-1.5 text-[12px] text-voodu-link hover:underline self-start"
    ) do
      render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "truncate") { url.sub(%r{\Ahttps?://}, "") }
    end
  end

  def card_actions
    return unless @manageable

    div(class: "flex items-center gap-2 px-3.5 py-2.5 border-t border-voodu-border") do
      if @plugin.installing?
        working_button
      elsif @plugin.available?
        install_button
      else
        reinstall_button
      end
    end
  end

  # The same button with a different label, not a sentence where the button
  # was. Swapping the control for prose changes the card's shape mid-operation,
  # which is a flinch exactly when the operator is watching to see whether
  # their click landed — and the button is where they are already looking.
  #
  # Disabled rather than absent: a control that vanishes reads as "did I break
  # it", and the disabled state is what says "yes, it is working".
  def working_button
    render Components::UI::Button.new(
      tag: :button, type: "button", variant: :secondary, size: :sm, disabled: true
    ) do
      render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5 animate-spin")
      span { @plugin.version.present? ? "Updating…" : "Installing…" }
    end
  end

  def install_button
    form(action: install_plugin_path, method: "post", class: "contents") do
      csrf
      input(type: "hidden", name: "source", value: @plugin.source)

      render Components::UI::Button.new(
        tag: :button, type: "submit", variant: :primary, size: :sm
      ) do
        render Icon::SquaresPlusOutline.new(class: "w-3.5 h-3.5")
        span { "Install" }
      end
    end
  end

  # Update and Retry are the same request: install again from the same source.
  # There is no "an update is available" here, and saying so would need the
  # controller to ask GitHub what the latest tag is — an outbound call from a
  # box that is otherwise self-contained. So the button offers the action, not
  # a claim about whether it is needed.
  def reinstall_button
    form(action: install_plugin_path, method: "post", class: "contents") do
      csrf
      input(type: "hidden", name: "source", value: install_source)

      render Components::UI::Button.new(
        tag: :button, type: "submit", variant: :secondary, size: :sm
      ) do
        render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
        span { @plugin.failed? ? "Retry" : "Update" }
      end
    end
  end

  # A failed install remembers what the operator typed; an installed plugin
  # only knows its homepage, which is where it came from in every case except
  # a local path.
  def install_source
    return @plugin.source if @plugin.source.present?

    @plugin.homepage_url.to_s.sub(%r{\Ahttps?://(www\.)?github\.com/}, "").presence || @plugin.name
  end

  def uninstall_control
    render Components::UI::Confirmable.new(
      title: "Uninstall #{@plugin.name}?",
      message: "This removes the plugin from #{@server.name} and runs its uninstall hook. " \
               "Anything it manages on that box keeps running; the commands go away.",
      confirm_label: "Uninstall",
      danger: true,
      form: {action: plugin_path(name: @plugin.name), method: :delete},
      trigger: {
        "aria-label": "Uninstall #{@plugin.name}",
        title: "Uninstall",
        class: "shrink-0 inline-flex items-center justify-center w-7 h-7 border border-voodu-border " \
               "bg-voodu-surface text-voodu-muted hover:text-voodu-red hover:border-voodu-red/40 transition-colors"
      }
    ) { render Icon::TrashOutline.new(class: "w-3.5 h-3.5") }
  end

  def csrf
    input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
  end
end
