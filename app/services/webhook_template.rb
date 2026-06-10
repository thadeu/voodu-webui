# frozen_string_literal: true

# WebhookTemplate — renders an operator-supplied JSON body template
# by substituting {{token}} placeholders, mirroring clowk-voodu's
# on_probe/on_deploy webhook substitution (same {{...}} syntax for
# ecosystem consistency).
#
# The template is parsed as JSON, the tree is walked, and {{token}}
# markers inside STRING values are replaced with their token value;
# the result is re-serialised. Re-marshalling is what keeps the
# output valid — a token value containing a quote is JSON-escaped
# automatically, so it can't break the operator's payload.
#
# Unknown tokens are left literal (some receivers use {{...}} in
# their own templating). Tokens never expand outside string values
# (you can't put {{value}} as a bare JSON number — that wouldn't be
# valid JSON in the template — so numbers are templated as strings,
# e.g. "value": "{{value}}").
class WebhookTemplate
  TOKEN = /\{\{(\w+)\}\}/

  def self.render(template_json, tokens)
    tree   = JSON.parse(template_json)
    string = tokens.transform_keys(&:to_s).transform_values { |v| v.nil? ? "" : v.to_s }

    JSON.generate(substitute(tree, string))
  end

  def self.substitute(node, tokens)
    case node
    when Hash  then node.transform_values { |v| substitute(v, tokens) }
    when Array then node.map { |v| substitute(v, tokens) }
    when String then apply(node, tokens)
    else node
    end
  end

  def self.apply(str, tokens)
    return str unless str.include?("{{")

    str.gsub(TOKEN) { tokens.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
  end
end
