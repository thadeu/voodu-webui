# frozen_string_literal: true

# Returnable — a safe "come back here when you're done" param for modals & drawers.
#
# A modal or drawer is opened FROM somewhere (a list, a tab, a card) and, on
# cancel/save/delete, should return the operator EXACTLY there — not to whatever
# landing page the controller defaults to. The origin passes its own URL as
# `?return_to=<path>` (and carries it through the form as a hidden field so the
# POST keeps it); the acting controller reads it back with `return_to_path`.
#
# Generic on purpose: `return_to` is a full path, so it can point at any route
# (a tab, a filtered list, a nested page) — not just one dimension. Today the
# alert-rule modal uses it; tomorrow any modal/drawer can.
#
# SECURITY: `return_to` is attacker-controllable (it rides in the URL), so it
# MUST NOT become an open redirect. `url_from` is Rails' own guard — it returns
# the location only when it's a same-origin local path, and nil for anything
# cross-host or protocol-relative (`//evil.com`). Non-String params (array/hash
# pollution) fall through to nil too. Unsafe/blank → the caller's fallback.
module Returnable
  extend ActiveSupport::Concern

  # return_to_path — the validated `?return_to` target, or `fallback` when it's
  # missing/unsafe. Use it both for the post-action redirect AND for the value
  # handed to the view (Cancel link / close button / hidden field), so the
  # round-trip is validated in exactly one place.
  def return_to_path(fallback)
    raw = params[:return_to]

    (raw.is_a?(String) && url_from(raw)) || fallback
  end
end
