# frozen_string_literal: true

# ServerScoped — for the stores that hold a bare `server_id` and nothing else.
#
# The metrics warehouse, the HEP tables and the NDJSON log tree live outside the
# primary database (or outside any database), so their rows carry an integer
# `server_id` with no org column, no foreign key, and nothing that could notice
# a wrong one. Authorization happens exactly once, upstream, when
# ApplicationController#authorized_servers turns a URL into a Server — and
# every one of these entry points is downstream of it.
#
# So the rule is not "remember to scope the query". It is: **a Server instance
# IS the capability.** Hand these an object and the caller had to have gone
# through the scoped producer to get it; hand them an integer and they cannot
# tell whose it is. `extend`ed into each of those classes so the refusal is
# identical everywhere, and loud.
#
# test/architecture/tenant_scoping_test.rb enforces the other half of this: that
# request code never names those models at all.
module ServerScoped
  def server_id_of(server)
    return server.id if server.is_a?(::Server)

    raise ArgumentError,
      "expected a Server, got #{server.class}. These rows carry a bare server_id " \
      "with no org column — the object is the only proof the caller was allowed to " \
      "reach it. See ServerScoped."
  end
end
