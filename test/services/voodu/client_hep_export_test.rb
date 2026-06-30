# frozen_string_literal: true

require "test_helper"

# Voodu::Client#hep_export is the wire contract for the HEP3 poller: it
# GETs the reader's /export tail through the PAT plugin proxy and returns
# [raw_ndjson_body, next_cursor]. These pin that the `since` cursor rides
# the query, the X-Hep-Cursor header becomes the next cursor, the body is
# passed through unparsed (it's NDJSON, not JSON), and HTTP errors map to
# the typed Client errors the poller discards on.
class Voodu::ClientHepExportTest < ActiveSupport::TestCase
  fixtures :islands

  setup { @island = islands(:alpha) }

  def export_url
    "#{@island.endpoint}/api/pat/v1/hep3/fsw/hep3-api/export"
  end

  test "resumes from the cursor and surfaces the next one" do
    stub = stub_request(:get, export_url)
      .with(query: {"since" => "sip.ndjson:10"})
      .to_return(status: 200, body: "a\nb\n",
        headers: {"X-Hep-Cursor" => "sip.ndjson:42", "Content-Type" => "application/x-ndjson"})

    body, cursor = Voodu::Client.new(@island).hep_export("fsw", "hep3-api", since: "sip.ndjson:10")

    assert_equal "a\nb\n", body, "raw NDJSON body must pass through unparsed"
    assert_equal "sip.ndjson:42", cursor
    assert_requested stub
  end

  test "omits the since param on a cold cursor" do
    stub = stub_request(:get, export_url)
      .with(query: {})
      .to_return(status: 200, body: "", headers: {"X-Hep-Cursor" => "sip.ndjson:0"})

    body, cursor = Voodu::Client.new(@island).hep_export("fsw", "hep3-api")

    assert_equal "", body
    assert_equal "sip.ndjson:0", cursor
    assert_requested stub
  end

  test "maps a 401 to AuthError (so the poller discards, not retries)" do
    stub_request(:get, export_url).to_return(status: 401, body: "{}")

    assert_raises(Voodu::Client::AuthError) do
      Voodu::Client.new(@island).hep_export("fsw", "hep3-api")
    end
  end
end
