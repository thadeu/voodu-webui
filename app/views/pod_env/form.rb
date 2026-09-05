# frozen_string_literal: true

# The drawer body: add a variable, change one, or override one the image set.
#
# ONE FORM, THREE HEADINGS, and the headings are not decoration. The three
# submit the same request and mean different things:
#
#   add       — a variable this app did not have.
#   edit      — a config key that already exists. Saving changes it.
#   override  — a variable the IMAGE declares. Saving creates a config key that
#               shadows it, permanently, including across future images.
#
# The third is the one worth spelling out. An operator who thinks they are
# editing PATH is not: they are adding a permanent piece of configuration whose
# effect outlives the image they were looking at when they clicked.
class Views::PodEnv::Form < Views::Base
  def initialize(pod_name:, bucket_label:, key: nil, from_config: false)
    @pod_name = pod_name
    @bucket_label = bucket_label
    @key = key
    @from_config = from_config
  end

  def view_template
    div(class: "flex flex-col gap-4 p-3.5") do
      intro

      form(action: pod_env_path(pod_name: @pod_name), method: "post",
        class: "flex flex-col gap-3.5") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

        key_field
        value_field
        restart_toggle
        actions
      end

      remove_form if editing? && @from_config
    end
  end

  private

  def adding? = @key.blank?

  def editing? = @key.present?

  def override? = editing? && !@from_config

  def intro
    div(class: "flex flex-col gap-1") do
      span(class: "text-[13px] font-medium text-voodu-text") { heading }
      span(class: "text-[11.5px] text-voodu-muted") { explanation }
    end
  end

  def heading
    return "Add a variable" if adding?
    return "Override #{@key}" if override?

    "Edit #{@key}"
  end

  # The sentence that stops somebody from doing something they did not mean.
  def explanation
    if override?
      return "#{@key} comes from the image. Saving creates a config variable " \
             "that shadows it — on this app, from now on, including on future images."
    end

    "Stored on #{@bucket_label}. Only this app reads it."
  end

  # Read-only when editing: a form that lets you change the NAME of the key
  # you opened would rename by creating a second variable and leaving the
  # first — which is not what anybody means by editing.
  def key_field
    field(label: "Name", hint: adding? ? "Letters, digits and underscores" : nil) do
      input(
        type: "text", name: "key", value: @key, required: true,
        readonly: editing?, autocomplete: "off", spellcheck: "false",
        placeholder: "DATABASE_URL",
        pattern: "[A-Za-z_][A-Za-z0-9_]*",
        class: field_class(muted: editing?)
      )
    end
  end

  # The value is NOT here on open. When the key already lives in the config
  # bucket, the eye fetches it; otherwise there is nothing to fetch and the
  # field starts empty, which is the honest state.
  def value_field
    field(label: "Value", hint: value_hint) do
      turbo_frame_tag(Views::PodEnv::Value.frame_id(@key.presence || "new")) do
        div(class: "flex flex-col gap-1.5") do
          textarea(
            name: "value", rows: "3", spellcheck: "false",
            placeholder: editing? ? "unchanged unless you type something" : "value",
            class: "w-full px-3 py-2 bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
                   "font-voodu-mono text-[12.5px] outline-none placeholder:text-voodu-muted-2 " \
                   "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line"
          ) { "" }

          reveal_link if @from_config
        end
      end
    end
  end

  def value_hint
    return "Never shown until you ask for it" if @from_config
    return "The image's value is not ours to read" if override?

    nil
  end

  # A link into the frame above, so clicking it swaps the empty field for the
  # revealed one without touching the rest of the drawer.
  def reveal_link
    # Never prefetched — see Components::Pods::EnvCard#reveal_link.
    a(href: reveal_pod_env_path(pod_name: @pod_name, key: @key, variant: "field"),
      data: {turbo_frame: Views::PodEnv::Value.frame_id(@key), turbo_prefetch: "false"},
      class: "self-start inline-flex items-center gap-1.5 text-[11.5px] text-voodu-link") do
      render Icon::EyeOutline.new(class: "w-3.5 h-3.5")
      span { "Reveal current value" }
    end
  end

  # Opt-out, matching the box. A variable nothing restarts to pick up is a
  # variable that did not take effect, and finding that out an hour later is
  # worse than a restart somebody expected.
  def restart_toggle
    label(class: "flex items-center gap-2 text-[12px] text-voodu-text-2") do
      input(type: "hidden", name: "restart", value: "false")
      input(type: "checkbox", name: "restart", value: "true", checked: true,
        class: "accent-[var(--voodu-accent)]")
      span { "Restart this app so it picks the change up" }
    end
  end

  # Confirmed, always — adding as much as editing.
  #
  # Not ceremony: saving here writes a production environment variable and (by
  # default) restarts the app that reads it. The drawer is opened from a dense
  # list, one small button away from the row above it, and "I meant to click
  # the eye" should not be a deploy.
  #
  # The sentence names the KEY and the BUCKET, never the value — this string
  # goes into an attribute in the page.
  def actions
    div(class: "flex items-center gap-2") do
      render Components::UI::Button.new(
        tag: :button, type: :submit, variant: :primary, size: :sm,
        data: {turbo_confirm: confirm_text}
      ) { span { override? ? "Create override" : "Save" } }
    end
  end

  def confirm_text
    if override?
      return "Create #{key_label} on #{@bucket_label}? It will shadow the image's " \
             "value from now on, and the app restarts."
    end

    return "Set #{key_label} on #{@bucket_label}? The app restarts." if adding?

    "Change #{key_label} on #{@bucket_label}? The app restarts."
  end

  # The typed name is not known server-side when adding, so the confirmation
  # says "this variable" rather than inventing one.
  def key_label = @key.presence || "this variable"

  # Its own form, below the fold of the main one: a destructive button inside
  # the save form is a button somebody hits with Enter.
  def remove_form
    div(class: "pt-3.5 border-t border-voodu-border") do
      form(action: pod_env_path(pod_name: @pod_name), method: "post") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        input(type: "hidden", name: "_method", value: "delete")
        input(type: "hidden", name: "key", value: @key)

        render Components::UI::Button.new(
          tag: :button, type: :submit, variant: :ghost, size: :sm,
          data: {turbo_confirm: "Remove #{@key} from #{@bucket_label}? The app restarts."}
        ) do
          render Icon::TrashOutline.new(class: "w-3.5 h-3.5 text-voodu-red")
          span { "Remove this variable" }
        end
      end
    end
  end

  def field(label:, hint: nil)
    div(class: "flex flex-col gap-1.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { label }

      yield

      span(class: "text-[11px] text-voodu-muted") { hint } if hint
    end
  end

  def field_class(muted: false)
    base = "w-full px-3 h-9 border border-voodu-border font-voodu-mono text-[12.5px] " \
           "outline-none placeholder:text-voodu-muted-2 " \
           "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line "

    base + (muted ? "bg-voodu-surface text-voodu-muted" : "bg-voodu-surface-2 text-voodu-text")
  end
end
