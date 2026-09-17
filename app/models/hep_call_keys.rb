# frozen_string_literal: true

# HepCallKeys — gives every SIP message the key of the CALL it belongs to,
# by looking at the rows already stored for the same reader instance.
#
# The rule, per message, in order:
#   1. a stored row has the same Call-ID        → inherit its call_key
#   2. else the message has an X-CID and a stored row has that X-CID
#                                               → inherit its call_key
#   3. else                                     → new call, call_key = Call-ID
#
# And the union: when 1 and 2 both match but name DIFFERENT keys, the table
# has been holding one call as two (a leg whose responses landed before the
# INVITE that carries the X-CID, or a B-leg tailed before its A-leg). The
# later key is folded into the earlier one with a single UPDATE, inside the
# same transaction as the batch.
#
# Why this lives at ingest and not in the query: corr_id — the per-row
# COALESCE(x_cid, call_id) — cannot know that the 100 Trying without an
# X-CID belongs to the INVITE with one; that fact is in another row. Resolve
# it once, when the row is written, and COUNT(DISTINCT call_key) is a plain
# indexed count from then on. Maps are seeded with ONE query per batch per
# side (Call-ID / X-CID), so a page of 500 lines costs two lookups.
#
# `seed: false` is the backfill's mode: it walks an instance in ts order
# with empty maps, so stored (possibly split) keys never leak back in, and
# it collects merges instead of writing them — the caller rewrites the rows.
class HepCallKeys
  def initialize(instance, seed: true)
    @instance = instance
    @seed = seed
    @by_call = {}
    @by_x = {}
    @merges = 0
  end

  attr_reader :merges

  # assign — sets :call_key on every row hash (rows carry :payload, the raw
  # NDJSON line, or :call_id / :x_cid already extracted). Rows are processed
  # in the order given, which for the poller is the reader's file order.
  def assign(rows)
    parsed = rows.map { |row| [row, ids_of(row)] }
    seed_maps(parsed.map { |_, ids| ids }) if @seed

    parsed.each do |row, (call_id, x_cid)|
      row[:call_key] = resolve(call_id, x_cid)
    end

    rows
  end

  # key_for — the resolved key of one (call_id, x_cid) pair, in memory only.
  # The backfill uses it to rewrite rows without touching the DB per row.
  def key_for(call_id, x_cid)
    resolve(call_id.to_s, x_cid.to_s)
  end

  private

  def ids_of(row)
    return [row[:call_id].to_s, row[:x_cid].to_s] if row.key?(:call_id)

    payload = JSON.parse(row[:payload].to_s)
    [payload["call_id"].to_s, payload["x_cid"].to_s]
  rescue JSON::ParserError
    ["", ""]
  end

  def seed_maps(ids)
    call_ids = ids.map(&:first).reject(&:empty?).uniq
    x_cids = ids.map(&:last).reject(&:empty?).uniq

    if call_ids.any?
      @instance.where(call_id: call_ids).where.not(call_key: nil)
        .distinct.pluck(:call_id, :call_key).each { |cid, key| @by_call[cid] ||= key }
    end

    if x_cids.any?
      @instance.where(x_cid: x_cids).where.not(call_key: nil)
        .distinct.pluck(:x_cid, :call_key).each { |xc, key| @by_x[xc] ||= key }
    end
  end

  def resolve(call_id, x_cid)
    return "" if call_id.empty?

    by_call = @by_call[call_id]
    by_x = x_cid.empty? ? nil : @by_x[x_cid]
    key = by_call || by_x || call_id

    merge(loser: by_x, winner: by_call) if by_call && by_x && by_call != by_x

    @by_call[call_id] = key
    @by_x[x_cid] = key unless x_cid.empty?
    key
  end

  # merge — two keys turned out to be one call. The stored rows move in one
  # UPDATE (ingest mode); the maps move in both modes so the rest of the
  # batch lands on the surviving key.
  def merge(loser:, winner:)
    @merges += 1
    @instance.where(call_key: loser).update_all(call_key: winner) if @seed
    @by_call.transform_values! { |k| (k == loser) ? winner : k }
    @by_x.transform_values! { |k| (k == loser) ? winner : k }
  end
end
