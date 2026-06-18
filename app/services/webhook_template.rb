# frozen_string_literal: true

# WebhookTemplate — renders an operator-supplied JSON body template by
# substituting {{token}} placeholders, mirroring clowk-voodu's
# on_probe/on_deploy webhook substitution (same {{...}} syntax for
# ecosystem consistency).
#
# The template is parsed as JSON, the tree is walked, and {{token}}
# markers inside STRING values are replaced with their token value;
# the result is re-serialised. Re-marshalling is what keeps the output
# valid — a token value containing a quote is JSON-escaped
# automatically, so it can't break the operator's payload.
#
# Unknown tokens are left literal (some receivers use {{...}} in their
# own templating). Tokens never expand outside string values (you
# can't put {{value}} as a bare JSON number — that wouldn't be valid
# JSON in the template — so numbers are templated as strings, e.g.
# "value": "{{value}}").
#
# ── Filters ────────────────────────────────────────────────────────
#
# A token may carry a pipe chain of value transforms:
#
#   {{dedup_key | slice: 0, 6}}   → first 6 chars
#   {{rule | upcase}}             → upper-cased
#   {{target | slice: 0, 8 | upcase}}
#
# Filters are NOT code: each pipe segment is parsed into a filter name
# + literal args (ints / quoted strings only) and dispatched against a
# FROZEN whitelist of lambdas. Nothing the operator types is ever
# `eval`'d — there is no path to arbitrary Ruby, so a hostile template
# can't reach `system`/`File`/`ENV` or the decrypted credentials.
#
# Names + semantics deliberately mirror Liquid's built-in filters, so a
# future move to the Liquid gem is a renderer swap with the operator's
# templates left byte-identical. (Liquid's `first` is for arrays, so
# substring uses `slice` — the Liquid-compatible spelling.)
class WebhookTemplate
  TOKEN = /\{\{([^}]+)\}\}/

  # Liquid-compatible filter whitelist. Each lambda takes the (string)
  # value plus already-parsed literal args. Unknown filters and bad
  # arities are no-ops (see apply_filters) — never a 500, never a leak.
  FILTERS = {
    "upcase" => ->(v) { v.upcase },
    "downcase" => ->(v) { v.downcase },
    "capitalize" => ->(v) { v.capitalize },
    "strip" => ->(v) { v.strip },
    "slice" => ->(v, start, len = 1) { v[start, len].to_s },
    "truncate" => ->(v, len, ell = "...") { (v.length > len) ? v[0, [len - ell.length, 0].max] + ell : v },
    "replace" => ->(v, from, to = "") { v.gsub(from.to_s, to.to_s) },
    "append" => ->(v, suffix) { "#{v}#{suffix}" },
    "prepend" => ->(v, prefix) { "#{prefix}#{v}" },
    "default" => ->(v, fallback) { v.empty? ? fallback.to_s : v }
  }.freeze

  def self.render(template_json, tokens)
    tree = JSON.parse(template_json)
    string = tokens.transform_keys(&:to_s).transform_values { |v| v.nil? ? "" : v.to_s }

    JSON.generate(substitute(tree, string))
  end

  def self.substitute(node, tokens)
    case node
    when Hash then node.transform_values { |v| substitute(v, tokens) }
    when Array then node.map { |v| substitute(v, tokens) }
    when String then apply(node, tokens)
    else node
    end
  end

  def self.apply(str, tokens)
    return str unless str.include?("{{")

    str.gsub(TOKEN) do
      whole = Regexp.last_match(0)
      name, *filters = Regexp.last_match(1).split("|").map(&:strip)

      # Unknown token → leave the whole {{...}} literal.
      tokens.key?(name) ? apply_filters(tokens[name], filters) : whole
    end
  end

  # Walk the pipe chain, applying each whitelisted filter in turn. An
  # unknown filter or a wrong-arity call leaves the value untouched
  # rather than raising — the body must still render.
  def self.apply_filters(value, filters)
    filters.reduce(value) do |acc, segment|
      name, _, argstr = segment.partition(":")
      fn = FILTERS[name.strip]
      next acc unless fn

      begin
        fn.call(acc, *parse_args(argstr)).to_s
      rescue ArgumentError, TypeError, IndexError
        acc
      end
    end
  end

  # Filter args are literals only: integers or (optionally quoted)
  # strings. Never expressions, never method names — there is nothing
  # to evaluate.
  def self.parse_args(argstr)
    return [] if argstr.strip.empty?

    argstr.split(",").map do |raw|
      arg = raw.strip

      if arg.match?(/\A-?\d+\z/)
        arg.to_i
      elsif (m = arg.match(/\A"(.*)"\z/) || arg.match(/\A'(.*)'\z/))
        m[1]
      else
        arg
      end
    end
  end
end
