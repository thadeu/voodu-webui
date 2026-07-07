# frozen_string_literal: true

# PayloadParsable — every record that stores raw JSON in a `payload` column
# (warehouse rows: HepMessage, MetricSample; state snapshots: Pod, System)
# exposes it as a memoized Hash, {} on a blank or malformed payload. Never
# raises — a bad row degrades to {} rather than 500-ing a render.
#
# Models keep their historical accessor name via an alias (payload_json /
# payload_hash) so call sites are untouched.
module PayloadParsable
  extend ActiveSupport::Concern

  def parsed_payload
    return @parsed_payload if defined?(@parsed_payload)

    @parsed_payload = JSON.parse(payload || "{}")
  rescue JSON::ParserError
    @parsed_payload = {}
  end
end
