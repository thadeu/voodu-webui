# Puma config — voodu-webui.
#
# Sizing rationale (deliberately departs from the Rails default of
# 3 threads):
#
# This app uses ActionController::Live for the log streaming proxies
# (LogsController#stream + #stream_all). Each open SSE tab parks ONE
# Puma thread for the entire lifetime of the connection — operators
# typically leave logs open for minutes or hours. With the Rails
# default pool of 3, just 2-3 open log tabs is enough to saturate
# the pool; the next request (Pod drawer fetch, ⌘K refresh, asset
# reload) queues behind the parked threads and the app appears
# frozen. Documented repro: 100s "Completed 200 OK" on a /pods/:name
# embed request while 3 log tabs were streaming.
#
# Fix: size threads for the SSE workload, not the average HTTP app.
#
#   threads_min = max(SSE_tabs, normal_concurrent_requests) + slack
#
# For a small ops dashboard (~2-4 operators, each with 1-2 tabs):
# ~4 SSE + ~4 normal + slack ≈ 12-16 threads. We pick 16 — same
# number for dev AND prod because SSE behaves the same in both
# environments; the dev "I leave 5 tabs open while testing" load
# is actually MORE adversarial than a clean prod operator session.
#
# Threads are cheap (~1MB stack each) when they're parked in
# blocking IO, which is what SSE does ~100% of the time. 16 threads
# adds ~16MB of stack to the worker — negligible against any
# realistic RAM budget.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 16).to_i
threads threads_count, threads_count

# Workers (forked processes for true CPU parallelism).
#
# voodu-webui is IO-bound: every request that does real work hits
# the controller's PAT plane via Faraday. The GVL is already
# released during that IO, so adding workers buys little parallel
# throughput. Workers DO help with:
#
#   - Crash isolation (one worker dies, the other absorbs traffic)
#   - Memory leak resilience (kill + respawn one worker without
#     downtime)
#   - Eliminating the cold-start tail when one worker is GCing
#
# Cost: each worker forks the Rails process (~150-300MB of resident
# memory vs ~1MB per thread). For a small VM hosting both the
# WebUI and the controller, 1 worker × 16 threads is the sweet
# spot — ~300MB total, 16 concurrent requests, single point of
# failure but the WebUI is operator-only (not customer-facing) so
# a brief restart is acceptable.
#
# Kamal / docker compose can override via WEB_CONCURRENCY when the
# deployment has the RAM headroom for crash isolation. Setting
# WEB_CONCURRENCY=2+ AUTOMATICALLY enables preload_app! so the
# extra workers fork copy-on-write from a fully booted Rails app
# (~150MB shared instead of ~300MB per worker).
#
# Default = 0 (single-process, NOT cluster mode). Puma 8 warns
# loudly when you run `workers 1` because a single forked worker
# is pure overhead (extra master process babysitting one child for
# no parallelism gain). Single-process is the right shape for a
# 1-replica deployment.
worker_count = ENV.fetch("WEB_CONCURRENCY", 0).to_i
workers worker_count if worker_count > 0

# preload_app! requires that the app be re-loadable AFTER fork;
# Rails handles this fine in prod (eager_load!). In dev (which
# stays single-process), preload_app! defeats Rails' autoload-on-
# request behaviour anyway — Phlex view edits would stop being
# picked up. So we ONLY preload when actually forking ≥2 workers.
preload_app! if worker_count > 1

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
