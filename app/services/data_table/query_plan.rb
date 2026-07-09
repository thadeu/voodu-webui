# frozen_string_literal: true

# DataTable::QueryPlan — parses the CloudWatch-Insights-style PIPELINE into a
# structured aggregation plan. It layers ON TOP of DataTable::Query (which owns
# the filter → SQL WHERE): QueryPlan splits the `|` pipeline, pulls out the
# aggregation / group-by / sort / limit stages, and hands the remaining filter
# text back for DataTable::Query to compile in the read path (M2).
#
#   @to_user like /5511/ | count() by to_user | sort desc | limit 100
#     └── filter ──────┘  └── metric + group ─┘  └ sort ┘  └ limit ┘
#
# Each `|` is a reduce step. The plan it produces:
#
#   filter         "@to_user like /5511/"   # the filter stage(s), AND-joined ("" ⇒ none)
#   aggregate      :count                    # the metric (only :count today), or nil
#   distinct_field "corr_id"                 # count(distinct <field>), or nil
#   group_by       "to_user"                 # `by <field>` ⇒ one series/row per value, or nil
#   sort_field     :value | "cseq"           # sort key (:value ⇒ the agg value), or nil
#   sort_dir       :asc | :desc              # default :desc
#   limit          100                       # `limit N`, or nil (⇒ all groups)
#
# GRAMMAR (case-insensitive keywords; function ALWAYS with parens):
#
#   query   := stage ( "|" stage )*
#   stage   := filter-expr                       # DataTable::Query grammar (WHERE)
#            | metric [ "by" field ]             # aggregation (+ optional grouping)
#            | "sort" [ "by" field ] [ "asc" | "desc" ]   # default: by the agg value, desc
#            | "limit" int
#   metric  := "count" "(" ")"                   # count rows
#            | "count" "(" "distinct" field ")"  # count distinct values of a field
#            | "count"                           # bare ⇒ count() (backward-compat)
#
# PURE parse: no SQL, no DB, no field allowlist here — the field NAMES are
# captured as strings and validated against the source's allowlist in M2 (where
# the SQL is built). A leading `@` on a field is stripped (matches DataTable::Query).
#
# A query with NO aggregation stage (a plain filter, or `filter | limit`) leaves
# `aggregate` nil — the read path treats it exactly as today (a table / filter),
# so old queries and panels keep working. Parse issues degrade softly: `error`
# is set and the best-effort plan (filter kept) is still returned.
module DataTable
  class QueryPlan
    Plan = Struct.new(
      :filter, :aggregate, :distinct_field, :group_by,
      :sort_field, :sort_dir, :limit, :error
    ) do
      def aggregate? = !aggregate.nil?

      def grouped? = !group_by.nil?

      def valid? = error.nil?
    end

    def self.compile(source)
      new(source).compile
    end

    def initialize(source)
      @source = source.to_s
    end

    def compile
      plan = Plan.new(filter: "")
      src = @source.strip

      return plan if src.empty?

      filters = []

      split_pipeline(src).each do |stage|
        if stage.match?(/\Acount\b/i)
          parse_metric_stage(stage, plan)
        elsif stage.match?(/\Asort\b/i)
          parse_sort_stage(stage, plan)
        elsif stage.match?(/\Alimit\b/i)
          parse_limit_stage(stage, plan)
        else
          filters << stage
        end
      end

      # AND-join the filter stage(s), each parenthesized so `or` inside one stage
      # can't leak across the `and`. DataTable::Query compiles this in M2.
      plan.filter = filters.map { |f| "(#{f})" }.join(" and ")

      plan
    end

    private

    # split_pipeline — split on `|`, but NEVER inside a /regex/ or "string"
    # (a filter like `@message like /INVITE|BYE/` must survive intact).
    def split_pipeline(src)
      stages = []
      buf = +""
      i = 0
      n = src.length

      while i < n
        c = src[i]

        if c == "|"
          stages << buf.strip
          buf = +""
          i += 1
        elsif c == "/" || c == '"'
          chunk, i = scan_delimited(src, i, c)
          buf << chunk
        else
          buf << c
          i += 1
        end
      end

      stages << buf.strip
      stages.reject(&:empty?)
    end

    # scan_delimited — copy a /…/ or "…" chunk VERBATIM (including delimiters and
    # `\`-escapes) so its contents never get interpreted as pipeline syntax.
    # Unterminated ⇒ copy the rest (the filter compiler surfaces the real error).
    def scan_delimited(src, start, delim)
      n = src.length
      j = start + 1
      buf = +src[start]

      while j < n
        ch = src[j]
        buf << ch

        if ch == "\\" && j + 1 < n
          buf << src[j + 1]
          j += 2
        elsif ch == delim
          j += 1
          break
        else
          j += 1
        end
      end

      [buf, j]
    end

    # metric stage: `count()` / `count(distinct <field>)` / `count`, with an
    # optional trailing `by <field>`.
    def parse_metric_stage(stage, plan)
      rest = stage.strip

      if (bym = rest.match(/\bby\s+@?(\w+)\s*\z/i))
        plan.group_by = bym[1]
        rest = rest[0...bym.begin(0)].strip
      end

      if (cm = rest.match(/\Acount\s*\(\s*(?:distinct\s+@?(\w+)\s*)?\)\z/i))
        plan.aggregate = :count
        plan.distinct_field = cm[1]
      elsif rest.casecmp?("count")
        plan.aggregate = :count
      else
        plan.error ||= "bad aggregation: '#{stage}' — use count() or count(distinct <field>)"
      end
    end

    # sort stage: `sort [by <field>] [asc|desc]`. No field ⇒ sort by the agg
    # value (:value). No direction ⇒ desc (the useful default for "top N").
    def parse_sort_stage(stage, plan)
      if (m = stage.match(/\Asort\b\s*(?:by\s+@?(\w+)\s*)?(asc|desc)?\s*\z/i))
        plan.sort_field = m[1] || :value
        plan.sort_dir = (m[2]&.downcase == "asc") ? :asc : :desc
      else
        plan.error ||= "bad sort: '#{stage}' — use sort [by <field>] [asc|desc]"
      end
    end

    def parse_limit_stage(stage, plan)
      if (m = stage.match(/\Alimit\s+(\d+)\s*\z/i))
        plan.limit = m[1].to_i
      else
        plan.error ||= "bad limit: '#{stage}' — use limit <N>"
      end
    end
  end
end
