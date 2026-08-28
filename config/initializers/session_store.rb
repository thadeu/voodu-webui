# frozen_string_literal: true

# Sessions live server-side, not in the cookie.
#
# The default CookieStore caps a session at 4KB, and Clowk::Authenticable
# spends most of that on its own: it persists the raw JWT *and* the full
# decoded claims payload. With a Google-backed RS256 token (avatar URL, name,
# issuer, key id) the session lands around 3.5KB before this app writes
# anything — so the first flash message of any size raised CookieOverflow and
# 500'd the request that set it. That is not a bug you fix by writing shorter
# flashes; it is a ceiling one dependency already spends.
#
# :cache_store keeps a small session id in the cookie and the payload in the
# cache (solid_cache in production, the file store in development). Eviction is
# not a logout: the `clowk_token` cookie survives independently, and
# Clowk::Authenticable re-establishes the session from it on the next request.
#
# expire_after bounds an abandoned session in the store. It is not the security
# boundary — Authentication::SESSION_HARD_CEILING is, and it is shorter.
Rails.application.config.session_store :cache_store,
  key: "_voodu_webui_session",
  expire_after: 30.days,
  same_site: :lax,
  secure: Rails.env.production?
