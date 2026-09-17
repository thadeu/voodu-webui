# frozen_string_literal: true

namespace :hep3 do
  desc "Resolve call_key across legs for HEP messages written before the column existed (one-off, idempotent)"
  task backfill_call_keys: :environment do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rewritten = HepMessage.backfill_call_keys!
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

    puts "hep3:backfill_call_keys rewritten=#{rewritten} rows in #{elapsed}s"
  end
end
