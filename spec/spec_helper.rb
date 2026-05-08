# frozen_string_literal: true

# Enable GC.stress before any other allocations so the GC fires on
# every allocation in the entire test run — including require/load. The
# CI job sets CLICKHOUSE_NATIVE_GC_STRESS=1; local dev is unaffected.
# RUBY_GC_STRESS env var is *not* reliably honored across CRuby builds,
# so we wire it ourselves and emit a marker line for observability: if
# the warn doesn't appear in CI logs, stress is not actually active.
if ENV["CLICKHOUSE_NATIVE_GC_STRESS"] == "1"
  GC.stress = true
  warn "[spec_helper] GC.stress = true"
end

require "bigdecimal"
require "logger"
require "stringio"
require "clickhouse_native"

CH_HOST = ENV.fetch("CLICKHOUSE_HOST", "localhost")
CH_PORT = Integer(ENV.fetch("CLICKHOUSE_PORT", "9000"))
CH_KWARGS = { host: CH_HOST, port: CH_PORT }.freeze

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  # Close any ClickhouseNative::Client that survived the example.
  # Inline `Pool.new(...)` constructions in `it` blocks have no
  # binding-scoped teardown; this sweep catches them. Pool-owned
  # Clients are reachable through the Pool's ConnectionPool queue and
  # get swept too. Client#close is a no-op on an already-closed Client.
  config.after do
    ObjectSpace.each_object(ClickhouseNative::Client) do |c|
      c.close
    rescue StandardError => error
      warn "[teardown cleanup] #{c.class}#close raised: #{error.class}: #{error.message}"
    end
  end
end
