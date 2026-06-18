# frozen_string_literal: true

# PodStatus — canonical "given a pod payload, what symbol should the
# UI show?" derivation. Single source of truth for status mapping so
# the pods table, pod show header, and any future surface always
# agree on what a pod's pill says.
#
# Before this lived in two places with slightly different regexes:
#   - OverviewData#pod_status_sym matched /restarting/i
#   - PodDetailData#status_sym matched /restart/i and also checked
#     for the literal "stopped" status string
# Same intent, drift just waiting to happen. Now both call here.
#
# The `stale:` kwarg encodes the "controller offline → we can't
# honestly claim 'running' anymore" override. Callers that have a
# stale-data signal (OverviewData#stale?, PodDetailData#stale?) pass
# it; pages that only render fresh data (the live HTTP path) leave
# it false and get the raw mapping.
#
# Why a PORO and not a Pod model method?
#   - Both call sites work on RAW payload hashes (from the warehouse
#     OR a fresh HTTP fetch), not Pod model instances. Putting the
#     algorithm on the model would force every caller to materialise
#     a Pod just to compute a symbol.
#   - Pure function: payload in, symbol out, no I/O, no state — the
#     kind of thing that wants to live by itself so it's trivially
#     testable.
class PodStatus
  # from_payload — input is the raw pod hash (string keys, the shape
  # the controller's /pods response ships). Output is one of:
  #   :running    — container is up and reporting healthy
  #   :restarting — docker is mid-restart loop (status string contains
  #                 "restart")
  #   :stopped    — exited / never started / unknown
  #   :offline    — only when stale: true (controller unreachable, so
  #                 we can't honestly claim anything live)
  #
  # nil payload is treated as :stopped — happens transiently when the
  # warehouse is empty for a freshly-deployed pod (sync hasn't ticked
  # yet) or when an operator hits a stale bookmark.
  def self.from_payload(payload, stale: false)
    return :offline if stale
    return :stopped if payload.nil?
    return :running if payload["running"]
    return :restarting if payload["status"].to_s.match?(/restart/i)

    :stopped
  end

  # from_state_string — variant that takes the docker `state.status`
  # string directly (one of "running", "restarting", "stopped",
  # "exited", "created", …). Used by the Spec card's `state.status`
  # row where we only have the inner state hash, not the full pod
  # payload.
  #
  # Same stale-override semantics: when the controller is unreachable
  # the warehouse's last-known "running" is no longer trustworthy and
  # we degrade to :offline across every surface that shows the pod's
  # status — including the Spec card row.
  def self.from_state_string(status, stale: false)
    return :offline if stale

    s = status.to_s.downcase
    return :running if s == "running"
    return :restarting if s.include?("restart")
    return :stopped if s == "stopped" || s == "exited"

    :stopped
  end
end
