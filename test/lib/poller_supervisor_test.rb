# frozen_string_literal: true

require "test_helper"
require "socket"

# Poller::Supervisor keeps the Go poller alive under Puma. These pin the
# three behaviours that used to be missing: a dead child is respawned with
# backoff and its exit is logged; stop() really ends the child; a child
# whose /healthz goes stale is killed and respawned.
class PollerSupervisorTest < ActiveSupport::TestCase
  setup do
    @lines = []
    @logger = ->(msg) { @lines << msg }
  end

  teardown { @sup&.stop }

  def wait_until(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  test "a child that exits is respawned with backoff and the exit is logged" do
    @sup = Poller::Supervisor.new(
      command: ["sh", "-c", "exit 3"], logger: @logger,
      backoff_min: 0.05, backoff_max: 0.1, spawn_out: File::NULL, spawn_err: File::NULL
    ).start

    wait_until(3) { @sup.restarts >= 2 }

    assert_operator @sup.restarts, :>=, 2
    assert @lines.any? { |l| l.include?("exited status=3") }, @lines.inspect
    assert @lines.any? { |l| l.include?("respawning in") }
  end

  test "stop terminates a running child" do
    @sup = Poller::Supervisor.new(
      command: ["sleep", "60"], logger: @logger, spawn_out: File::NULL, spawn_err: File::NULL
    ).start

    wait_until(3) { @sup.running? }
    pid = @sup.pid
    assert @sup.running?

    @sup.stop

    wait_until(3) { !process_alive?(pid) }
    assert_not process_alive?(pid), "child #{pid} should be gone after stop"
    assert_equal 0, @sup.restarts, "a stop is not a crash"
  end

  test "a child whose healthz reports a stale last_poll is killed and respawned" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    stale = (Time.now - 3600).utc.iso8601

    serving = Thread.new do
      loop do
        client = server.accept
        client.gets
        body = %({"status":"healthy","last_poll":"#{stale}"})
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    rescue IOError
      nil
    end

    @sup = Poller::Supervisor.new(
      command: ["sleep", "60"], logger: @logger, healthz_url: "http://127.0.0.1:#{port}/healthz",
      grace: 0.1, health_every: 0.1, stale_after: 1, backoff_min: 0.05, backoff_max: 0.1,
      spawn_out: File::NULL, spawn_err: File::NULL
    ).start

    wait_until(8) { @sup.restarts >= 1 }

    assert_operator @sup.restarts, :>=, 1
    assert @lines.any? { |l| l.include?("is unhealthy") }, @lines.inspect
    assert @lines.any? { |l| l.include?("last_poll is") }, @lines.inspect
  ensure
    serving&.kill
    server&.close
  end

  private

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
