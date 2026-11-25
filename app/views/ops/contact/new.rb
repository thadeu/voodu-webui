# frozen_string_literal: true

# Views::Ops::Contact::New — one message to support, answered by email.
class Views::Ops::Contact::New < Views::Base
  def initialize(current_path:, servers: [])
    @current_path = current_path
    @servers = servers
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers,
      breadcrumb: [{label: "License", href: ops_license_path}, {label: "Email us"}]
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_head
        div(class: "max-w-2xl") { contact_card }
      end
    end
  end

  private

  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Email us" }
      p(class: "text-[12.5px] text-voodu-muted") { "Enterprise, a question or a problem. We answer at #{Current.user&.email}." }
    end
  end

  def contact_card
    render Components::UI::SectionCard.new(title: "Message") do
      form(action: ops_contact_path, method: "post", data: {turbo: false}, class: "flex flex-col") do
        div(class: "p-3.5 flex flex-col gap-1.5") do
          input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

          label(for: "contact_message", class: "text-[11px] font-semibold uppercase tracking-[0.06em] text-voodu-text-2") { "What do you need?" }

          textarea(id: "contact_message", name: "message", rows: 8, maxlength: 5000, required: true, class: tokens(input_classes, "text-[13px] py-2 h-auto"))
        end

        contact_actions
      end
    end
  end

  def contact_actions
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 p-3.5 border-t border-voodu-border") do
      render(Components::UI::Button.new(type: "submit", variant: :primary, class: "w-full vmd:w-auto")) { "Send" }
      render(Components::UI::Button.new(tag: :a, href: ops_license_path, variant: :secondary, class: "w-full vmd:w-auto")) { "Cancel" }
    end
  end
end
