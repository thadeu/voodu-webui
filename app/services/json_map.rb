# frozen_string_literal: true

# JsonMap — a tiny, dependency-free resolver for the panel mapping DSL that
# pulls values out of an external API's JSON response. It is deliberately NOT
# full JSONPath (no `..`, no filters, no mid-path wildcards) — just a dotted
# path with optional `[n]` array indices, which covers "reach into this
# object/array and grab this field" without the ReDoS/complexity surface of a
# general JSONPath engine.
#
#   JsonMap.dig(json, "data.items[0].name")  → the value, or nil on any miss
#   JsonMap.array_at(json, "data.items")     → an Array (wraps a lone object,
#                                               [] on miss) — the row/point set
#
# A leading `$` or `$.` is accepted and ignored, so operators can paste
# JSONPath-looking strings and they still resolve.
module JsonMap
  module_function

  # dig — navigate `path` into a parsed JSON value. "" / "$" → the value
  # itself. Returns nil the moment a segment doesn't resolve (wrong type,
  # missing key, out-of-range index).
  def dig(value, path)
    tokens(path).reduce(value) do |cur, tok|
      break nil if cur.nil?

      if tok.is_a?(Integer)
        cur.is_a?(Array) ? cur[tok] : nil
      else
        cur.is_a?(Hash) ? cur[tok] : nil
      end
    end
  end

  # array_at — resolve `path` and coerce to an Array: an array passes through,
  # a lone object is wrapped ([obj]) so a single-object response still yields
  # one row/point, and a miss (nil) is []. This is the row/point set a mapping
  # iterates.
  def array_at(value, path)
    resolved = dig(value, path)

    case resolved
    when Array then resolved
    when nil then []
    else [resolved]
    end
  end

  # tokens — split a path into a flat list of String keys and Integer indices.
  # "data.items[0].name" → ["data", "items", 0, "name"]. A leading `$`/`$.` is
  # stripped. Bracket indices can stack (`a[0][1]` → "a", 0, 1).
  def tokens(path)
    str = path.to_s.strip.delete_prefix("$").delete_prefix(".")
    return [] if str.empty?

    str.split(".").flat_map { |part| part_tokens(part) }
  end

  def part_tokens(part)
    m = part.match(/\A([^\[\]]*)((?:\[\d+\])*)\z/)
    return [part] unless m

    out = []
    out << m[1] unless m[1].empty?
    out.concat(m[2].scan(/\[(\d+)\]/).flatten.map(&:to_i))

    out
  end
end
