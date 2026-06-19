# frozen_string_literal: true

# LogQuery — compiles the /logs/analytics filter into a predicate over a log
# record. The operator's needle grew from "one substring (or one regex)" into
# a small CloudWatch-Logs-Insights-flavoured boolean language:
#
#   /INVITE/ and not /health/
#   @level = "ERROR" and @message like /timeout/
#   callid or (200 OK and not OPTIONS)
#
# Grammar (case-insensitive keywords):
#
#   query    := stage ( "|" stage )*                       # CloudWatch pipeline
#   stage    := "filter" or | "limit" int | agg | or       # bare ⇒ implicit filter
#   agg      := ("count"|"sum"|"avg"|"min"|"max")           # reduces the match count
#                 ("(" … ")")? ("as" word)?                 # optional, ignored
#   or       := and ( "or"  and )*
#   and      := unary ( "and" unary )*
#   unary    := "not" unary | primary
#   primary  := "(" or ")" | term
#   term     := field op value | field value               # value-only ⇒ "like"
#   field    := "@message" | "@level" | "@stream"
#   op       := "like" | "=" | "==" | "!="
#   value    := /regex/ | "quoted" | bareword
#
# Pipeline: stages chain with `|`, CloudWatch-Logs-Insights style. `filter`
# stages are AND-combined — `filter A | filter B` ≡ `A and B` (each narrows
# further). `filter` is OPTIONAL: a bare `@message like /x/` is an implicit
# single-stage filter, so terse queries stay terse.
#
# `limit N` is a SET operation, not a row predicate — it can't live in the
# compiled `predicate`, so it surfaces as `Result#limit` (an Integer or nil)
# for the caller (LogSearchData) to cap the newest-N result set. Last `limit`
# wins. (Future commands — stats / fields / sort — slot in as new stage kinds
# here too.)
#
# EVERY clause names a field — there is no bare-term shorthand (a lone
# `/User-Agent/` or `callid` is NOT a query, it must be `@message like
# /User-Agent/`). Fields map to the record: @message tests msg AND raw (covers
# structured + plain lines, so it's the catch-all); @level / @stream test
# their own field. (@pod is intentionally absent — the pod scope picker owns
# that axis.)
#
# One deliberate safety net:
#
#   - **Never match-nothing on a typo.** A parse/regex error (including a
#     field-less query, e.g. a legacy `?q=callid` bookmark from the old simple
#     input) degrades to a literal substring on @message and stashes the
#     message in `#error`. So old URLs still return results, and the editor
#     surfaces `#error` to nudge the operator to name a field.
#
# Regexes compile with a per-match `timeout:` (Ruby 3.4) as a ReDoS backstop;
# the Reader rescues Regexp::TimeoutError per line and treats it as a non-match.
class LogQuery
  FIELDS = {"@message" => :message, "@level" => :level, "@stream" => :stream}.freeze
  KEYWORDS = %w[and or not like].freeze
  REGEX_TIMEOUT = 1.0

  # compile — convenience: LogQuery.compile(str) → Result.
  def self.compile(source)
    new(source).compile
  end

  # Result — `predicate` is always a callable Proc(record)->bool (never nil),
  # so callers don't branch. `limit` is the `limit N` stage value (Integer) or
  # nil. `agg` is the trailing `| <agg>` stage as a Symbol (:count/:sum/:avg/
  # :min/:max) or nil (no agg stage ⇒ caller treats as :count). `error` is nil
  # on success, else a human message describing why we fell back to a literal
  # substring match.
  Result = Struct.new(:predicate, :limit, :error, :agg) do
    def valid?
      error.nil?
    end
  end

  # The aggregation suffix stages. They reduce the per-bucket COUNT of matching
  # lines (the value source is always the line tally) — no field extraction.
  # The reduction itself (count=latest bucket, sum=total, avg=mean, min/max)
  # lives in LogMetricData; here we only parse WHICH one.
  AGG_STAGES = %w[count sum avg min max].freeze

  class ParseError < StandardError; end

  def initialize(source)
    @source = source.to_s
  end

  def compile
    src = @source.strip
    return Result.new(predicate: ->(_rec) { true }, limit: nil, error: nil, agg: nil) if src.empty?

    @tokens = tokenize(src)
    @pos = 0
    @limit = nil
    @agg = nil
    node = parse_pipeline
    raise ParseError, "unexpected '#{peek[1]}'" if peek

    Result.new(predicate: node, limit: @limit, error: nil, agg: @agg)
  rescue ParseError, RegexpError => e
    # Degrade to a literal substring of the whole input — a malformed query
    # still searches for what was typed instead of silently matching nothing.
    Result.new(predicate: substring_predicate(:message, src), limit: nil, error: e.message, agg: nil)
  end

  private

  # ── tokenizer ────────────────────────────────────────────────────────────

  def tokenize(src)
    tokens = []
    i = 0
    n = src.length

    while i < n
      c = src[i]

      if /\s/.match?(c)
        i += 1
      elsif c == "("
        tokens << [:lparen, "("]
        i += 1
      elsif c == ")"
        tokens << [:rparen, ")"]
        i += 1
      elsif c == "/"
        body, i = scan_delimited(src, i, "/")
        tokens << [:regex, body]
      elsif c == '"'
        body, i = scan_delimited(src, i, '"', unescape: true)
        tokens << [:string, body]
      elsif c == "@"
        # Keep the original case: @message/@level/@stream resolve
        # case-insensitively (downcased at the FIELDS lookup), but a stats
        # @field is a JSON key, which CAN be camelCase (@durationMs) — losing
        # case here would read the wrong key.
        m = src[i..].match(/\A@\w+/) or raise ParseError, "bad field near '#{src[i..i + 6]}'"
        tokens << [:field, m[0]]
        i += m[0].length
      elsif c == "="
        step = (src[i + 1] == "=") ? 2 : 1
        tokens << [:op, "="]
        i += step
      elsif c == "!"
        raise ParseError, "expected '!=' " unless src[i + 1] == "="

        tokens << [:op, "!="]
        i += 2
      elsif c == "|"
        tokens << [:pipe, "|"]
        i += 1
      else
        m = src[i..].match(%r{\A[^\s()"/=!@|]+})
        word = m[0]
        tokens << (KEYWORDS.include?(word.downcase) ? [:kw, word.downcase] : [:word, word])
        i += word.length
      end
    end

    tokens
  end

  # scan_delimited — read a `delim`…`delim` literal starting at `start`,
  # honouring `\delim` so the delimiter can appear inside. Returns [body, next].
  # Regex bodies keep their backslashes verbatim (so `\d`, `\.` survive into
  # Regexp.new); quoted strings unescape `\"` and `\\`.
  def scan_delimited(src, start, delim, unescape: false)
    n = src.length
    j = start + 1
    buf = +""
    closed = false

    while j < n
      ch = src[j]

      if ch == "\\" && j + 1 < n
        nxt = src[j + 1]

        if unescape
          buf << (%W[#{delim} \\].include?(nxt) ? nxt : "\\#{nxt}")
        else
          buf << ch << nxt
        end

        j += 2
      elsif ch == delim
        closed = true
        j += 1
        break
      else
        buf << ch
        j += 1
      end
    end

    raise ParseError, "unterminated #{(delim == "/") ? "regex" : "string"}" unless closed

    [buf, j]
  end

  # ── recursive-descent parser → composed Proc(record) ───────────────────────

  # parse_pipeline — `stage | stage | …`. Stages are AND-combined: a line only
  # survives if it passes EVERY filter (each `|` narrows further, exactly like
  # chaining `filter` commands in CloudWatch Logs Insights).
  def parse_pipeline
    node = parse_stage

    while type?(:pipe)
      advance
      right = parse_stage
      left = node
      node = ->(rec) { left.call(rec) && right.call(rec) }
    end

    node
  end

  # parse_stage — one pipeline stage: a `filter` (or bare) boolean expression,
  # a `limit N`, or an aggregation suffix (`count` / `avg` / `min` / `max` /
  # `sum`). limit + agg aren't row predicates, so they're recorded as side
  # effects (@limit / @agg, last-wins) and contribute a pass-through.
  #
  # A stage that STARTS with a bare agg word IS the agg stage — a filter clause
  # always starts with a field (@message/@level/@stream), so there's no clash.
  def parse_stage
    if type?(:word) && current[1].casecmp?("limit")
      advance
      @limit = parse_limit

      return ->(_rec) { true }
    end

    if type?(:word) && AGG_STAGES.include?(current[1].downcase)
      @agg = current[1].downcase.to_sym
      advance
      skip_agg_args

      return ->(_rec) { true }
    end

    advance if type?(:word) && current[1].casecmp?("filter")

    parse_or
  end

  # skip_agg_args — the agg suffix takes no real argument (its value source IS
  # the per-bucket match count). For paste-friendliness we tolerate and ignore
  # an optional `(...)` (e.g. `count(*)`) and a trailing `as <name>`.
  def skip_agg_args
    if type?(:lparen)
      depth = 0

      loop do
        t = peek or break
        advance
        depth += 1 if t[0] == :lparen
        depth -= 1 if t[0] == :rparen
        break if depth.zero?
      end
    end

    return unless type?(:word) && current[1].casecmp?("as")

    advance
    advance if type?(:word) || type?(:field)
  end

  def parse_limit
    t = peek
    raise ParseError, "limit needs a positive integer — e.g. limit 1000" unless t && t[0] == :word && t[1].match?(/\A\d+\z/)

    n = t[1].to_i
    raise ParseError, "limit must be greater than 0" unless n.positive?

    advance
    n
  end

  def parse_or
    node = parse_and

    while kw?("or")
      advance
      right = parse_and
      left = node
      node = ->(rec) { left.call(rec) || right.call(rec) }
    end

    node
  end

  def parse_and
    node = parse_unary

    while kw?("and")
      advance
      right = parse_unary
      left = node
      node = ->(rec) { left.call(rec) && right.call(rec) }
    end

    node
  end

  def parse_unary
    if kw?("not")
      advance
      inner = parse_unary

      return ->(rec) { !inner.call(rec) }
    end

    parse_primary
  end

  def parse_primary
    if type?(:lparen)
      advance
      node = parse_or
      expect(:rparen)

      return node
    end

    parse_term
  end

  # parse_term — every clause MUST start with a field. A value with no field
  # (a bare /regex/, word, or "string") is rejected, so the operator always
  # says WHAT they're filtering. After the field, the operator is optional —
  # `@message /re/` is shorthand for `@message like /re/`.
  def parse_term
    unless type?(:field)
      got = peek ? "'#{peek[1]}'" : "end of query"
      raise ParseError, "every clause needs a field (@message, @level, @stream) — got #{got}"
    end

    field = FIELDS[current[1].downcase] or raise ParseError, "unknown field '#{current[1]}' — use @message, @level or @stream"
    advance

    op = (type?(:op) || kw?("like")) ? parse_op : :like
    kind, raw = parse_value

    build_predicate(field, op, kind, raw)
  end

  def parse_op
    t = peek or raise ParseError, "expected an operator"

    if t[0] == :kw && t[1] == "like"
      advance
      :like
    elsif t[0] == :op && t[1] == "="
      advance
      :eq
    elsif t[0] == :op && t[1] == "!="
      advance
      :neq
    else
      raise ParseError, "expected like / = / != , got '#{t[1]}'"
    end
  end

  def parse_value
    t = peek or raise ParseError, "expected a value"

    case t[0]
    when :regex then advance
                     [:regex, t[1]]
    when :string, :word then advance
                             [:text, t[1]]
    else raise ParseError, "expected a value, got '#{t[1]}'"
    end
  end

  # build_predicate — one term → Proc(record). Regex values match (or, for !=,
  # don't-match); text values substring-match for `like` and exact-match
  # (case-insensitive) for `=`/`!=`.
  def build_predicate(field, op, kind, raw)
    if kind == :regex
      re = compile_regex(raw)

      return field_proc(field) { |str| !re.match?(str) } if op == :neq

      field_proc(field) { |str| re.match?(str) }
    else
      needle = raw.downcase

      case op
      when :eq then field_proc(field) { |str| str.casecmp?(raw) }
      when :neq then field_proc(field) { |str| !str.casecmp?(raw) }
      else field_proc(field) { |str| str.downcase.include?(needle) }
      end
    end
  end

  # field_proc — apply `test` to the field's string(s). @message is checked
  # against BOTH msg and raw (OR), so a needle finds structured or plain lines.
  # `!=`/not-regex stay correct under that OR: the block already carries the
  # negation, and "matches neither msg nor raw" is the right reading of `!=`.
  def field_proc(field, &test)
    if field == :message
      ->(rec) { test.call(rec[:msg].to_s) || test.call(rec[:raw].to_s) }
    else
      ->(rec) { test.call(rec[field].to_s) }
    end
  end

  def substring_predicate(field, text)
    needle = text.downcase
    field_proc(field) { |str| str.downcase.include?(needle) }
  end

  def compile_regex(source)
    Regexp.new(source, Regexp::IGNORECASE, timeout: REGEX_TIMEOUT)
  end

  # ── token cursor helpers ───────────────────────────────────────────────────

  def peek
    @tokens[@pos]
  end
  alias_method :current, :peek

  def advance
    @pos += 1
  end

  def type?(kind)
    (t = peek) && t[0] == kind
  end

  def kw?(word)
    (t = peek) && t[0] == :kw && t[1] == word
  end

  def expect(kind)
    raise ParseError, "expected '#{(kind == :rparen) ? ")" : kind}'" unless type?(kind)

    advance
  end
end
