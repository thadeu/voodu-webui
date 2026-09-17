# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Poller
  # Supervisor — keeps ONE poller process alive for the life of the Puma
  # that owns it.
  #
  # The plugin used to spawn the binary once and forget the PID. A poller
  # that died — at boot, on a crash, on an OOM — stayed dead until an
  # operator noticed an empty warehouse and restarted the pod, while Puma
  # kept answering the health check as if nothing were wrong. Now a thread
  # waits on the child and respawns it with backoff, and every exit is a
  # log line with the status, so "the logs stopped" has a cause in the pod
  # log instead of a shrug.
  #
  # A poller that is alive but stuck is the other half: the thread also
  # asks the binary's own /healthz every `health_every` seconds and, past a
  # `grace` after spawn, kills and respawns it when the endpoint stops
  # answering or its `last_poll` goes stale.
  class Supervisor
    attr_reader :pid, :restarts

    def initialize(command:, logger:, env: {}, healthz_url: nil,
      health_every: 60, grace: 90, stale_after: 180,
      backoff_min: 1, backoff_max: 30, spawn_out: $stdout, spawn_err: $stderr)
      @command = Array(command)
      @env = env
      @log = logger
      @healthz_url = healthz_url
      @health_every = health_every
      @grace = grace
      @stale_after = stale_after
      @backoff_min = backoff_min
      @backoff_max = backoff_max
      @spawn_out = spawn_out
      @spawn_err = spawn_err
      @restarts = 0
      @stopping = false
      @mutex = Mutex.new
    end

    def start
      @thread = Thread.new { supervise }
      @thread.name = "poller-supervisor"
      self
    end

    # stop — TERM the child and wait; the loop sees @stopping and ends.
    def stop
      @mutex.synchronize { @stopping = true }
      terminate(@pid)
      @thread&.join(15)
    end

    def running? = !@pid.nil? && alive?(@pid)

    private

    def supervise
      backoff = @backoff_min

      until stopping?
        started_at = monotonic
        @pid = Process.spawn(@env, *@command, out: @spawn_out, err: @spawn_err)
        log "spawned PID #{@pid}"

        status = wait_watching(@pid, started_at)
        break if stopping?

        @restarts += 1
        uptime = monotonic - started_at
        # A poller that ran a while before dying earned a fresh backoff; one
        # that dies straight away is broken and must not spin.
        backoff = (uptime > 60) ? @backoff_min : [backoff * 2, @backoff_max].min
        log "exited #{describe(status)} after #{uptime.round}s — respawning in #{backoff}s"
        sleep backoff
      end
    end

    # wait_watching — reap the child when it exits; meanwhile run the health
    # probe on its cadence. Returns the Process::Status (nil when we killed
    # it for being unhealthy and it left no status behind).
    def wait_watching(pid, started_at)
      next_probe = started_at + @grace
      failures = 0

      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status

        sleep 1

        next if @healthz_url.nil? || monotonic < next_probe

        next_probe = monotonic + @health_every
        problem = probe

        if problem.nil?
          failures = 0
          next
        end

        failures += 1
        log "healthz: #{problem} (#{failures}/2)"
        next if failures < 2

        log "PID #{pid} is unhealthy — killing it"

        return terminate(pid)
      end
    rescue Errno::ECHILD
      nil
    end

    # probe — nil when healthy, else a short reason.
    def probe
      uri = URI(@healthz_url)
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 3) { |h| h.get(uri.path) }
      return "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      last_poll = JSON.parse(res.body)["last_poll"].to_s
      return nil if last_poll.empty?

      age = Time.now - Time.parse(last_poll)
      (age > @stale_after) ? "last_poll is #{age.round}s old" : nil
    rescue => e
      "#{e.class}: #{e.message}"
    end

    # terminate — TERM, give it 10s to exit, KILL if it will not, and REAP
    # it. Reaping is the part that matters: a child that has exited but not
    # been waited on is a zombie, and `kill 0` still says it is alive, so a
    # liveness poll would sit out the whole grace period on a corpse. Returns
    # the Process::Status, nil if there was nothing to reap.
    def terminate(pid)
      return nil if pid.nil?

      Process.kill("TERM", pid)
      deadline = monotonic + 10

      while monotonic < deadline
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status

        sleep 0.1
      end

      Process.kill("KILL", pid)
      _, status = Process.waitpid2(pid)
      status
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def describe(status)
      return "(no status)" if status.nil?
      return "status=#{status.exitstatus}" if status.exited?

      "signal=#{status.termsig}"
    end

    def stopping? = @mutex.synchronize { @stopping }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def log(msg) = @log.call("[poller] #{msg}")
  end
end
