# frozen_string_literal: true

# Views::Islands::New — the onboarding form. Three fields, one button.
# Friction-minimal because the operator is going to do this repeatedly
# (once per VPS they want to monitor).
class Views::Islands::New < Views::Base
  def initialize(current_path:, island:)
    @current_path = current_path
    @island       = island
  end

  def view_template
    render Components::Layouts::Dashboard.new(current_path: @current_path) do
      div(class: "mx-auto max-w-xl px-6 py-10 flex flex-col gap-6") do
        div(class: "flex flex-col gap-1") do
          h1(class: "text-2xl font-semibold text-voodu-text") { "Add island" }
          p(class: "text-voodu-text-2") do
            plain "Point the WebUI at a voodu server. Mint the access token on the box with "
            span(class: "font-voodu-mono text-voodu-accent-2") { "vd pat create --scope=read,actions" }
            plain "."
          end
        end

        if @island.errors.any?
          render Components::UI::Card.new(variant: :default) do
            div(class: "py-1 flex flex-col gap-1") do
              @island.errors.full_messages.each do |msg|
                p(class: "text-sm text-voodu-red") { msg }
              end
            end
          end
        end

        form_block
      end
    end
  end

  private

  def form_block
    form(
      action: "/islands", method: "post",
      class: "flex flex-col gap-5", data: { turbo: false }
    ) do
      input(type: "hidden", name: "authenticity_token", value: helpers.form_authenticity_token)

      render Components::Form::Group.new(label: "Name", hint: "Free-form label shown in the sidebar.") do
        render Components::Form::Input.new(
          type: "text", name: "island[name]", value: @island.name,
          placeholder: "production-sao-paulo", autofocus: true
        )
      end

      render Components::Form::Group.new(label: "Destination", hint: "Host or IP. Port is optional — defaults to 8687.") do
        render Components::Form::Input.new(
          mono: true, type: "text", name: "island[endpoint]", value: @island.endpoint,
          placeholder: "203.0.113.10"
        )
      end

      render Components::Form::Group.new(label: "Personal access token", hint: "Shown ONCE on `vd pat create` — paste it here.") do
        render Components::Form::Input.new(
          mono: true, type: "password", name: "island[pat_ciphertext]", value: @island.pat,
          placeholder: "pat_a3F9bZ2k7Qm9pNvX4tCfH5d8yL2eRw"
        )
      end

      # Region + infra are operator metadata — they don't talk to
      # the controller. Two columns on wide viewports, stacked on
      # narrow. Both optional; the topbar collapses chips that are
      # blank, so leaving them empty is a valid choice.
      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-5") do
        render Components::Form::Group.new(label: "Region", hint: "Optional. Free-form (fra1, us-east-1, homelab).") do
          render Components::Form::Input.new(
            type: "text", name: "island[region]", value: @island.region == "—" ? nil : @island.region,
            placeholder: "fra1"
          )
        end

        render Components::Form::Group.new(label: "Infra", hint: "Optional. Where it runs (hetzner, aws, bare-metal).") do
          render Components::Form::Input.new(
            type: "text", name: "island[infra]", value: @island.infra,
            placeholder: "hetzner"
          )
        end
      end

      div(class: "flex items-center gap-3 pt-2") do
        render(Components::UI::Button.new(variant: :primary, type: :submit)) { "Register island" }
        render(Components::UI::Button.new(tag: :a, variant: :ghost, href: "/islands")) { "Cancel" }
      end
    end
  end
end
