# frozen_string_literal: true

# Authorization — declare the capability an action needs.
#
#   authorize :manage_servers, only: [:new, :create, :edit, :update]
#
# The capability table lives in Permissions; this is the enforcement half.
# Views ask the same question through `allowed?` to decide what to draw — but
# drawing is not deciding: a hidden button whose endpoint still honours the
# request is not a control.
module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :allowed?
  end

  class_methods do
    def authorize(capability, **options)
      before_action(**options) { require_permission!(capability) }
    end
  end

  private

  def allowed?(capability)
    Permissions.allow?(Current.role, capability)
  end

  def require_permission!(capability)
    return if allowed?(capability)

    refuse(capability)
  end

  # The fallback is the org-less /servers door, NOT root: `/` redirects to the first server you
  # can reach, and with none it redirects to the form you were just refused —
  # so refusing there bounced you between the two until the browser gave up
  # ("too many redirects"). /servers renders on its own and is not gated.
  #
  # redirect_back is still right for the usual case (a refused action inside a
  # page you were already on), but it must never send you back to the path that
  # refused you.
  def refuse(capability)
    message = "You need #{Permissions.minimum_role(capability)} access to do that."
    back = request.referer

    if back.present? && !back.end_with?(request.fullpath)
      redirect_to back, alert: message
    else
      redirect_to all_servers_path, alert: message
    end
  end
end
