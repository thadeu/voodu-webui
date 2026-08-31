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

  class_methods do
    def authorize(capability, **options)
      before_action(**options) { require_permission!(capability) }
    end

    # For the installation-wide screens (/ops/*), which carry no :org_id.
    def authorize_anywhere(capability, **options)
      before_action(**options) { require_permission_anywhere!(capability) }
    end
  end

  included do
    helper_method :allowed?, :allowed_anywhere?
  end

  private

  def allowed?(capability)
    Permissions.allow?(Current.role, capability)
  end

  # The same table, asked about the STRONGEST role the person holds ANYWHERE.
  #
  # `allowed?` reads Current.role, which answers for the org in the URL — and
  # /ops/license and /ops/sso have no :org_id segment by design, so Current.role
  # is nil there by construction and every check against it denies. Not a
  # missing membership: there is no org for the question to be about. Licence
  # and sign-in belong to the installation, not to one org in it.
  #
  # The trade this accepts, stated because it is not obvious: on a hosted
  # multi-tenant installation every customer is owner of their own org, so every
  # customer satisfies this. These screens are safe to reach only where the
  # people who can sign in are the people who run the box.
  def allowed_anywhere?(capability)
    memberships = Current.user&.org_memberships&.active || []

    memberships.any? { |membership| Permissions.allow?(membership.role, capability) }
  end

  def require_permission!(capability)
    return if allowed?(capability)

    refuse(capability)
  end

  def require_permission_anywhere!(capability)
    return if allowed_anywhere?(capability)

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
