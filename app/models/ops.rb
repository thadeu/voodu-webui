# frozen_string_literal: true

# Operational records — settings for the container rather than for anything
# inside it: the licence it runs under and the identity provider it trusts.
#
# table_name_prefix is what makes Ops::License read ops_licenses instead of
# licenses. It is the Rails-provided way to namespace tables, and without it a
# namespaced model silently claims the un-prefixed name — which is both a
# collision waiting to happen and a table that no longer says where it belongs.
module Ops
  def self.table_name_prefix = "ops_"
end
