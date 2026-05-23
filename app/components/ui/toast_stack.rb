# frozen_string_literal: true

# Components::UI::ToastStack — fixed bottom-right tray that renders
# every Rails flash entry as a Toast. Drop one of these into the
# dashboard layout once; every screen automatically picks up
# notice/alert messages set by controllers.
class Components::UI::ToastStack < Components::Base
  def initialize(flash:)
    @flash = flash
  end

  def view_template
    return if @flash.blank?

    div(
      class: "fixed bottom-4 right-4 z-50 flex flex-col gap-2 pointer-events-none",
      aria: { live: "polite" }
    ) do
      @flash.each do |type, message|
        render Components::UI::Toast.new(variant: variant_for(type), message: message)
      end
    end
  end

  private

  def variant_for(flash_key)
    case flash_key.to_s
    when "notice"        then :success
    when "alert", "error" then :danger
    else                       :info
    end
  end
end
