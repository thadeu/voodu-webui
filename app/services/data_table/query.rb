# frozen_string_literal: true

# DataTable::Query — compiles the DataTable filter DSL into a parameterized
# SQL WHERE fragment. Same grammar as LogQuery (so an operator prototypes a
# filter in /logs Analytics and pastes it into a table panel verbatim), but
# it emits SQL instead of a Ruby predicate — the table lives in SQLite, so
# filtering happens in the query and paging stays efficient.
#
#   @to_user like /5511/
#   @method = INVITE and @response_code = 200
#   @x_cid like /abc/ and not @method like /OPTIONS/
#
# Grammar (case-insensitive keywords):
#   query   := or
#   or      := and ("or" and)*
#   and     := unary ("and" unary)*
#   unary   := "not" unary | primary
#   primary := "(" or ")" | term
#   term    := field op? value        # op omitted ⇒ "like"
#   op      := "like" | "=" | "==" | "!="
#   value   := /regex/ | "quoted" | bareword
#
# `like /re/` is a real regex (SQLite REGEXP, registered on the connection
# by HepRecord.ensure_regexp!); `like text` is a substring; `=`/`!=` are exact
# (case-insensitive). Every clause names a field — the caller passes a
# `resolver` (field name → safe SQL expression, from the source's allowlist),
# so the field is NEVER attacker SQL and the value is always a bind param.
module DataTable
  class Query
    class ParseError < StandardError; end

    # Compiled — `sql` is nil (no filter) when the query is empty or failed to
    # parse; `error` carries the parse message for the editor to surface.
    Compiled = Struct.new(:sql, :binds, :error) do
      def filter?
        !sql.nil? && !sql.empty?
      end
    end

    KEYWORDS = %w[and or not like].freeze

    # compile — DataTable::Query.compile(str) { |field| expr_or_nil } → Compiled.
    def self.compile(source, &resolver)
      new(source, resolver).compile
    end

    def initialize(source, resolver)
      @source = source.to_s
      @resolver = resolver
    end

    def compile
      src = @source.strip
      return Compiled.new(sql: nil, binds: [], error: nil) if src.empty?

      @tokens = tokenize(src)
      @pos = 0
      node = parse_or
      raise ParseError, "unexpected '#{peek[1]}'" if peek

      Compiled.new(sql: node[:sql], binds: node[:binds], error: nil)
    rescue ParseError => e
      Compiled.new(sql: nil, binds: [], error: e.message)
    end

    private

    # ── tokenizer (mirrors LogQuery, without the `|` pipeline) ───────────

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
          m = src[i..].match(/\A@\w+/) or raise ParseError, "bad field near '#{src[i..i + 6]}'"
          tokens << [:field, m[0]]
          i += m[0].length
        elsif c == "="
          step = (src[i + 1] == "=") ? 2 : 1
          tokens << [:op, "="]
          i += step
        elsif c == "!"
          raise ParseError, "expected '!='" unless src[i + 1] == "="

          tokens << [:op, "!="]
          i += 2
        else
          m = src[i..].match(%r{\A[^\s()"/=!@]+})
          word = m[0]
          tokens << (KEYWORDS.include?(word.downcase) ? [:kw, word.downcase] : [:word, word])
          i += word.length
        end
      end

      tokens
    end

    def scan_delimited(src, start, delim, unescape: false)
      n = src.length
      j = start + 1
      buf = +""
      closed = false

      while j < n
        ch = src[j]

        if ch == "\\" && j + 1 < n
          nxt = src[j + 1]
          buf << ((unescape && [delim, "\\"].include?(nxt)) ? nxt : "#{ch}#{nxt}")
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

    # ── recursive descent → SQL nodes { sql:, binds: } ──────────────────

    def parse_or
      node = parse_and

      while kw?("or")
        advance
        node = combine("OR", node, parse_and)
      end

      node
    end

    def parse_and
      node = parse_unary

      while kw?("and")
        advance
        node = combine("AND", node, parse_unary)
      end

      node
    end

    def parse_unary
      if kw?("not")
        advance

        return negate(parse_unary)
      end

      parse_primary
    end

    def parse_primary
      skip_filter

      if type?(:lparen)
        advance
        node = parse_or
        expect(:rparen)

        return node
      end

      parse_term
    end

    # skip_filter — swallow an optional `filter` keyword. LogQuery uses it to
    # introduce a stage; here there are no stages, so it's an accepted no-op
    # prefix — a query pasted from /logs Analytics (`filter @to_user like
    # /5511/`) parses verbatim instead of erroring on the leading word.
    def skip_filter
      advance while (t = peek) && t[0] == :word && t[1].casecmp?("filter")
    end

    def parse_term
      raise ParseError, "every clause needs a field — e.g. @to_user like /5511/" unless type?(:field)

      name = current[1].delete_prefix("@")
      expr = @resolver.call(name) or raise ParseError, "unknown field '@#{name}'"
      advance

      op = (type?(:op) || kw?("like")) ? parse_op : :like
      kind, value = parse_value

      term(expr, op, kind, value)
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

    # term — one clause → a { sql:, binds: } node.
    def term(expr, op, kind, value)
      if kind == :regex
        base = {sql: "#{expr} REGEXP ?", binds: [value]}

        return (op == :neq) ? negate(base) : base
      end

      case op
      when :eq then {sql: "#{expr} = ? COLLATE NOCASE", binds: [value]}
      when :neq then negate({sql: "#{expr} = ? COLLATE NOCASE", binds: [value]})
      else {sql: "#{expr} LIKE ? ESCAPE '\\'", binds: ["%#{like_escape(value)}%"]}
      end
    end

    def combine(op, left, right)
      {sql: "(#{left[:sql]}) #{op} (#{right[:sql]})", binds: left[:binds] + right[:binds]}
    end

    def negate(node)
      {sql: "NOT (#{node[:sql]})", binds: node[:binds]}
    end

    def like_escape(value)
      value.gsub(/[\\%_]/) { |ch| "\\#{ch}" }
    end

    # ── cursor helpers ──────────────────────────────────────────────────

    def peek = @tokens[@pos]
    alias_method :current, :peek

    def advance = (@pos += 1)

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
end
