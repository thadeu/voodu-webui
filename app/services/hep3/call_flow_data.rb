# frozen_string_literal: true

# Hep3::CallFlowData — turns the SIP messages of ONE call (correlated by
# corr_id, which already folds x_cid → call_id) into a ladder/sequence
# model the CallFlow SVG renders: vertical lifelines (the parties) and
# horizontal arrows (each message), in ts order.
#
# Backs Hep3Controller#call. Reads HepMessage.for_call and parses each
# line's payload once (incl. raw_sip, which the drawer panel shows on
# click). Purely a read/shape service — no SQL beyond the one scope.
#
# HEP wire convention (verified against real capture):
#   - a REQUEST has a method (INVITE/ACK/BYE/…) and response_code 0;
#   - a RESPONSE has an empty method and response_code > 0 — the method
#     it answers lives in cseq ("498 INVITE"). So request? == code.zero?.
#
# A lifeline is a party keyed by IP (a host may reuse ports; grouping by
# IP keeps the ladder to one column per host). Columns are ordered by
# first appearance scanning messages in ts order (src then dst) — stable
# and predictable left-to-right.
module Hep3
  class CallFlowData
    # SIP reason phrases for the common codes, so a response arrow reads
    # "180 Ringing" not a bare number. Unknown codes fall back to the
    # class name ("2xx", "4xx") — never a crash.
    REASONS = {
      100 => "Trying", 180 => "Ringing", 181 => "Forwarded", 182 => "Queued",
      183 => "Session Progress", 199 => "Early Dialog Terminated",
      200 => "OK", 202 => "Accepted", 204 => "No Notification",
      300 => "Multiple Choices", 301 => "Moved Permanently", 302 => "Moved Temporarily",
      305 => "Use Proxy", 380 => "Alternative Service",
      400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
      404 => "Not Found", 405 => "Method Not Allowed", 407 => "Proxy Auth Required",
      408 => "Request Timeout", 410 => "Gone", 415 => "Unsupported Media",
      420 => "Bad Extension", 480 => "Temporarily Unavailable", 481 => "Call/Transaction Does Not Exist",
      482 => "Loop Detected", 483 => "Too Many Hops", 484 => "Address Incomplete",
      486 => "Busy Here", 487 => "Request Terminated", 488 => "Not Acceptable Here",
      491 => "Request Pending",
      500 => "Server Internal Error", 501 => "Not Implemented", 502 => "Bad Gateway",
      503 => "Service Unavailable", 504 => "Server Timeout", 505 => "Version Not Supported",
      600 => "Busy Everywhere", 603 => "Decline", 604 => "Does Not Exist Anywhere",
      606 => "Not Acceptable"
    }.freeze

    def initialize(server:, scope:, name:, corr_id:, focus_id: nil)
      @server = server
      @scope = scope.to_s
      @name = name.to_s
      @corr_id = corr_id.to_s
      # focus_id — the HepMessage id of the row the operator clicked (message
      # views). The ladder opens pre-selected + scrolled to THAT message, not
      # always the first. nil / no-match (e.g. a Calls-view aggregate row) →
      # falls to the first message (the call's start).
      @focus_id = focus_id.presence&.to_i
    end

    attr_reader :corr_id, :scope, :name

    # focus_index — the position of the clicked message in the ladder, or 0
    # (the call's start) when there's no focus / it doesn't match.
    def focus_index
      return 0 if @focus_id.nil?

      idx = messages.index { |m| m[:id] == @focus_id }
      idx || 0
    end

    def focus_message
      messages[focus_index] || messages.first
    end

    # found? — the call has at least one message (else the controller 404s
    # / renders the empty state).
    def found? = messages.any?

    # messages — every SIP message of the call, chronological, as flat
    # display hashes (see #build_message). Memoised: one payload parse pass.
    def messages
      @messages ||= records.each_with_index.map { |record, i| build_message(record, i) }
    end

    # lifelines — the ordered distinct parties (by IP). Left-to-right = the
    # order each endpoint first appears (src then dst) scanning in ts order.
    def lifelines
      @lifelines ||= begin
        order = []

        messages.each do |m|
          order << m[:src] if m[:src].present? && !order.include?(m[:src])
          order << m[:dst] if m[:dst].present? && !order.include?(m[:dst])
        end

        order
      end
    end

    # column_index — a party's column position (0-based). Used by the SVG
    # to place each arrow's endpoints.
    def column_index(ip) = lifelines.index(ip)

    # summary — the header line: parties, final response code, message
    # count and wall-clock span. from/to come from the first message
    # (the initiating request); last_code is the last real response.
    def summary
      first = messages.first || {}
      responses = messages.map { |m| m[:code] }.reject(&:zero?)

      {
        count: messages.size,
        from_user: first[:from_user],
        to_user: first[:to_user],
        last_code: responses.last,
        methods: messages.filter_map { |m| m[:method] }.uniq,
        duration_ms: duration_ms
      }
    end

    # media_streams — the negotiated RTP media, DERIVED from the SDP we
    # already capture (we don't sniff RTP, so no packet counts — see the
    # panel note). One stream per dialog leg (raw Call-ID): the offer's media
    # endpoint (INVITE SDP) ⇄ the answer's (the final 2xx/183 SDP), with the
    # agreed codecs + direction. In a B2BUA each leg is a media hop.
    def media_streams
      @media_streams ||= messages
        .select { |m| m[:sdp] }
        .group_by { |m| m[:call_id] }
        .filter_map { |_call_id, msgs| stream_for(msgs) }
    end

    # inline_media — media streams whose BOTH endpoints map to a SIP lifeline,
    # so the RTP can be drawn as an arrow in the ladder (sngrep-style). Carries
    # from_col/to_col for the SVG.
    def inline_media
      media_streams.filter_map do |s|
        from = s[:offer_ip] && column_index(s[:offer_ip])
        to = s[:answer_ip] && column_index(s[:answer_ip])
        next if from.nil? || to.nil?

        s.merge(from_col: from, to_col: to)
      end
    end

    # gap_media — streams whose media endpoint isn't a signaling lifeline (RTP
    # on a different host than SIP). No clean spot in the ladder → the modal
    # shows these in the collapsible footer instead.
    def gap_media
      media_streams - inline_streams
    end

    private

    def inline_streams
      @inline_streams ||= media_streams.select do |s|
        s[:offer_ip] && s[:answer_ip] && column_index(s[:offer_ip]) && column_index(s[:answer_ip])
      end
    end

    def stream_for(msgs)
      parsed = msgs.map { |m| [m, parse_sdp(m[:raw_sip])] }.reject { |_, sdp| sdp.nil? }
      return nil if parsed.empty?

      offer_sdp = parsed.find { |m, _| m[:request] }&.last
      answer_pair = parsed.reverse.find { |m, _| !m[:request] }
      answer_sdp = answer_pair&.last
      near = answer_sdp || offer_sdp || parsed.first.last

      {
        offer: endpoint_label(offer_sdp),
        answer: endpoint_label(answer_sdp),
        offer_ip: offer_sdp&.dig(:ip),
        answer_ip: answer_sdp&.dig(:ip),
        codecs: near[:codecs],
        direction: near[:direction],
        answered: !answer_pair.nil?
      }
    end

    # parse_sdp — pull the (audio) media endpoint, codecs and direction from a
    # SIP message's SDP body. Best-effort: nil when there's no SDP.
    def parse_sdp(raw_sip)
      return nil unless sdp?(raw_sip)

      body = raw_sip.split(/\r?\n\r?\n/, 2)[1].to_s
      lines = body.presence ? body.split(/\r?\n/) : raw_sip.split(/\r?\n/)

      m = lines.find { |l| l.start_with?("m=audio") }&.split(/\s+/)
      rtpmap = lines.grep(/\Aa=rtpmap:/).to_h { |l| l.sub("a=rtpmap:", "").split(/\s+/, 2) }
      direction = lines.reverse.grep(/\Aa=(sendrecv|sendonly|recvonly|inactive)\b/).first&.sub("a=", "")

      {
        ip: lines.find { |l| l.start_with?("c=") }&.slice(/IN IP4 (\S+)/, 1),
        port: m&.at(1),
        codecs: (m ? m[3..] : []).map { |fmt| rtpmap[fmt] || fmt },
        direction: direction || "sendrecv"
      }
    end

    def endpoint_label(sdp)
      return "?" if sdp.nil? || sdp[:ip].blank?

      sdp[:port].present? ? "#{sdp[:ip]}:#{sdp[:port]}" : sdp[:ip]
    end

    def records
      HepMessage.for_call(server_id: @server.id, scope: @scope, name: @name, corr_id: @corr_id)
    end

    # build_message — one parsed message as a flat, view-ready hash. `kind`
    # drives the arrow colour; `label` is what the arrow reads.
    def build_message(record, index)
      payload = record.payload_json
      code = payload["response_code"].to_i
      request = code.zero?
      method = payload["method"].to_s
      raw_sip = payload["raw_sip"].to_s
      base_label = request ? method : response_label(code)

      {
        index: index,
        id: record.id,
        ts: payload["ts"].to_s,
        src: payload["src_ip"].to_s,
        src_port: payload["src_port"].to_s,
        dst: payload["dst_ip"].to_s,
        dst_port: payload["dst_port"].to_s,
        from_user: payload["from_user"].to_s,
        to_user: payload["to_user"].to_s,
        cseq: payload["cseq"].to_s,
        call_id: payload["call_id"].to_s,
        request: request,
        code: code,
        method: request ? method.presence : nil,
        sdp: sdp?(raw_sip),
        # A media-carrying message reads "INVITE (SDP)" / "200 OK (SDP)"
        # (sngrep convention) so the offer/answer legs stand out.
        label: sdp?(raw_sip) ? "#{base_label} (SDP)" : base_label,
        kind: classify(request, method, code),
        raw_sip: raw_sip
      }
    end

    # sdp? — does the message carry an SDP body? SIP always announces it with
    # a Content-Type: application/sdp header, so that's the reliable marker.
    def sdp?(raw_sip)
      raw_sip.match?(%r{content-type:\s*application/sdp}i)
    end

    def response_label(code)
      "#{code} #{REASONS.fetch(code, "#{code / 100}xx")}".strip
    end

    # classify — arrow colour bucket. Requests are neutral (blue) EXCEPT BYE,
    # which ends the call: flagged red so a hangup stands out. Responses split
    # by class so a 4xx/5xx stands out red and 1xx/2xx read green.
    def classify(request, method, code)
      if request
        return :terminate if method.to_s.casecmp?("BYE")

        return :request
      end

      case code
      when 100..199 then :provisional
      when 200..299 then :success
      when 300..399 then :redirect
      else :error
      end
    end

    def duration_ms
      stamps = messages.filter_map { |m| parse_ts(m[:ts]) }
      return 0 if stamps.size < 2

      ((stamps.max - stamps.min) * 1000).round
    end

    # parse_ts — the line's ts as an epoch float. Time.zone.parse handles
    # both the space- and T-separated forms the reader emits (Time.iso8601
    # rejects the space form). Unparseable → nil, never raises.
    def parse_ts(iso)
      return nil if iso.blank?

      Time.zone.parse(iso.to_s)&.to_f
    rescue ArgumentError, TypeError
      nil
    end
  end
end
