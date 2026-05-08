# frozen_string_literal: true

RSpec.describe ClickhouseNative do
  it "has a version number" do
    expect(ClickhouseNative::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end
end

RSpec.describe ClickhouseNative::Client, :clickhouse do
  subject(:client) { described_class.new(**CH_KWARGS) }

  after { client.close }

  describe "connection attributes" do
    it "exposes host/port/database" do
      expect(client.host).to eq(CH_HOST)
      expect(client.port).to eq(CH_PORT)
      expect(client.database).to eq("default")
    end

    it "inspect renders host:port/database" do
      expect(client.inspect).to include("#{CH_HOST}:#{CH_PORT}/default")
    end
  end

  describe "#ping" do
    it "returns true on a live connection" do
      expect(client.ping).to be(true)
    end
  end

  describe "#server_version" do
    it "returns a dotted version string" do
      expect(client.server_version).to match(/\A\d+\.\d+\.\d+\z/)
    end
  end

  describe "#execute" do
    it "runs DDL/DML without returning rows" do
      client.execute("CREATE DATABASE IF NOT EXISTS chn_test")
      client.execute("DROP TABLE IF EXISTS chn_test.x")
      client.execute("CREATE TABLE chn_test.x (id UInt64, s String) ENGINE = Memory")
      client.execute("INSERT INTO chn_test.x VALUES (1, 'a'), (2, 'b')")
      expect(client.query_value("SELECT count() FROM chn_test.x")).to eq(2)
      client.execute("DROP DATABASE chn_test")
    end
  end

  describe "#query_value" do
    it "returns the first cell or nil" do
      expect(client.query_value("SELECT 7 AS n")).to eq(7)
      expect(client.query_value("SELECT 1 WHERE 0")).to be_nil
    end
  end

  describe "#query" do
    it "returns an array of symbol-keyed hashes" do
      # Outer SELECT so ORDER BY spans both UNION branches; without it
      # ORDER BY binds to the second SELECT only and CH 24.x can return
      # the two branches' blocks in arbitrary order.
      rows = client.query(<<~SQL)
        SELECT * FROM (SELECT 1 AS a, 2 AS b UNION ALL SELECT 3 AS a, 4 AS b) ORDER BY a
      SQL
      expect(rows).to eq([{ a: 1, b: 2 }, { a: 3, b: 4 }])
    end

    it "handles no-row results" do
      expect(client.query("SELECT 1 WHERE 0")).to eq([])
    end

    context "type codec" do
      it "decodes String / LowCardinality(String) / FixedString" do
        row = client.query(<<~SQL).first
          SELECT
            'hello'                                AS s,
            CAST('cat' AS LowCardinality(String))  AS lc,
            CAST('abc' AS FixedString(5))          AS fs
        SQL
        expect(row[:s]).to eq("hello")
        expect(row[:s].encoding).to eq(Encoding::UTF_8)
        expect(row[:lc]).to eq("cat")
        expect(row[:fs]).to eq("abc\0\0")
      end

      it "decodes integer widths" do
        row = client.query(<<~SQL).first
          SELECT
            toInt8(-128) AS i8, toInt16(-32768) AS i16,
            toInt32(-2147483648) AS i32, toInt64(-9223372036854775808) AS i64,
            toUInt8(255) AS u8, toUInt16(65535) AS u16,
            toUInt32(4294967295) AS u32, toUInt64(18446744073709551615) AS u64
        SQL
        expect(row[:i8]).to eq(-128)
        expect(row[:i16]).to eq(-32_768)
        expect(row[:i32]).to eq(-2_147_483_648)
        expect(row[:i64]).to eq(-9_223_372_036_854_775_808)
        expect(row[:u8]).to eq(255)
        expect(row[:u16]).to eq(65_535)
        expect(row[:u32]).to eq(4_294_967_295)
        expect(row[:u64]).to eq(18_446_744_073_709_551_615)
      end

      it "decodes Decimal round-trip as BigDecimal" do
        sql = "SELECT toDecimal64('123.456789', 6) AS d, toDecimal128('-1.5', 2) AS e"
        row = client.query(sql).first
        expect(row[:d]).to eq(BigDecimal("123.456789"))
        expect(row[:e]).to eq(BigDecimal("-1.5"))
      end

      it "decodes Float32 / Float64" do
        sql = "SELECT toFloat32(1.5) AS f32, toFloat64(3.141592653589793) AS f64"
        row = client.query(sql).first
        expect(row[:f32]).to be_within(1e-6).of(1.5)
        expect(row[:f64]).to eq(3.141592653589793)
      end

      it "decodes DateTime64(6, 'UTC') at microsecond precision" do
        row = client.query("SELECT toDateTime64('2026-04-22 12:34:56.654321', 6, 'UTC') AS t").first
        expect(row[:t]).to be_a(Time)
        expect(row[:t].to_i).to eq(Time.utc(2026, 4, 22, 12, 34, 56).to_i)
        expect(row[:t].usec).to eq(654_321)
      end

      it "decodes Nullable(T)" do
        row = client.query("SELECT NULL::Nullable(String) AS a, toNullable('x') AS b").first
        expect(row[:a]).to be_nil
        expect(row[:b]).to eq("x")
      end

      it "decodes Array(T) recursively" do
        sql = "SELECT [1, 2, 3]::Array(UInt32) AS a, " \
              "[['x'], ['y', 'z']]::Array(Array(String)) AS aa"
        row = client.query(sql).first
        expect(row[:a]).to eq([1, 2, 3])
        expect(row[:aa]).to eq([["x"], %w[y z]])
      end

      it "decodes Map(K, V)" do
        row = client.query("SELECT map('a', 1, 'b', 2)::Map(String, Int32) AS m").first
        expect(row[:m]).to eq({ "a" => 1, "b" => 2 })
      end

      it "decodes Tuple(...)" do
        row = client.query("SELECT (1, 'two', 3.0)::Tuple(UInt8, String, Float64) AS t").first
        expect(row[:t]).to eq([1, "two", 3.0])
      end

      it "decodes Enum8 as a Symbol name" do
        sql = "SELECT CAST('blue' AS Enum8('red' = 1, 'green' = 2, 'blue' = 3)) AS c"
        row = client.query(sql).first
        expect(row[:c]).to eq(:blue)
      end

      it "decodes Bool as Ruby true/false (not Integer 0/1)" do
        row = client.query("SELECT true::Bool AS t, false::Bool AS f").first
        expect(row[:t]).to be(true)
        expect(row[:f]).to be(false)
      end

      it "decodes Nullable(Bool) as Ruby Boolean or nil" do
        sql = "SELECT true::Nullable(Bool) AS t, false::Nullable(Bool) AS f, " \
              "NULL::Nullable(Bool) AS n"
        row = client.query(sql).first
        expect(row[:t]).to be(true)
        expect(row[:f]).to be(false)
        expect(row[:n]).to be_nil
      end

      it "decodes Bool through query_value" do
        expect(client.query_value("SELECT true::Bool")).to be(true)
        expect(client.query_value("SELECT false::Bool")).to be(false)
      end
    end

    context "advanced types not supported by clickhouse-cpp v2.6.1" do
      # On CH 24.x these types require allow_experimental_*_type = 1 at the
      # server. The SETTINGS clauses make the server accept the cast on both
      # 24.x and 25.x so the error always comes from our decoder.
      it "rejects Dynamic with UnsupportedTypeError" do
        sql = "SELECT CAST(42 AS Dynamic) AS d SETTINGS allow_experimental_dynamic_type = 1"
        expect { client.query(sql) }
          .to raise_error(ClickhouseNative::UnsupportedTypeError, /Dynamic/)
      end

      it "rejects Variant with UnsupportedTypeError" do
        sql = "SELECT CAST(toUInt64(42), 'Variant(UInt64, String)') AS v " \
              "SETTINGS allow_experimental_variant_type = 1"
        expect { client.query(sql) }
          .to raise_error(ClickhouseNative::UnsupportedTypeError, /Variant/)
      end

      it "rejects typed JSON with UnsupportedTypeError" do
        sql = "SELECT CAST('{\"a\":1}', 'JSON') AS j SETTINGS allow_experimental_json_type = 1"
        expect { client.query(sql) }
          .to raise_error(ClickhouseNative::UnsupportedTypeError, /JSON/)
      end
    end
  end

  describe "#describe_table" do
    it "returns [{name:, type:, ...}]" do
      cols = client.describe_table("one", db_name: "system")
      expect(cols).to be_a(Array)
      expect(cols.first).to include(:name, :type)
      expect(cols.map { |c| c[:name] }).to include("dummy")
    end
  end

  describe "#insert" do
    before do
      client.execute("CREATE DATABASE IF NOT EXISTS chn_ins_test")
      client.execute("DROP TABLE IF EXISTS chn_ins_test.t")
      client.execute(<<~SQL)
        CREATE TABLE chn_ins_test.t (
          id UInt64,
          name String,
          score Nullable(Float64),
          tags Array(String),
          created DateTime64(6, 'UTC')
        ) ENGINE = Memory
      SQL
    end

    after { client.execute("DROP DATABASE chn_ins_test") }

    let(:t) { Time.utc(2026, 4, 22, 10, 30, 0, 123_456) }

    it "inserts an Array<Hash>, round-trips via SELECT" do
      client.insert("t", [
        { id: 1, name: "a", score: 1.5, tags: ["x"], created: t },
        { id: 2, name: "b", score: nil, tags: %w[y z], created: t },
      ], db_name: "chn_ins_test")

      rows = client.query("SELECT id, name, score, tags, created FROM chn_ins_test.t ORDER BY id")
      expect(rows.size).to eq(2)
      expect(rows[0]).to include(id: 1, name: "a", score: 1.5, tags: ["x"])
      expect(rows[0][:created].usec).to eq(123_456)
      expect(rows[1]).to include(id: 2, name: "b", score: nil, tags: %w[y z])
    end

    it "inserts Array<Array> with explicit columns in table order" do
      client.insert("t",
                    [[10, "c", nil, [], t]],
                    db_name: "chn_ins_test")
      expect(client.query_value("SELECT name FROM chn_ins_test.t WHERE id = 10")).to eq("c")
    end

    it "is a no-op on an empty rows array" do
      expect(client.insert("t", [], db_name: "chn_ins_test")).to eq(0)
      expect(client.query_value("SELECT count() FROM chn_ins_test.t")).to eq(0)
    end

    it "round-trips Map(String, Int32) including empty/nil maps" do
      client.execute(<<~SQL)
        CREATE TABLE chn_ins_test.m (id UInt32, attrs Map(String, Int32)) ENGINE = Memory
      SQL
      client.insert("m", [
        { id: 1, attrs: { "a" => 1, "b" => 2 } },
        { id: 2, attrs: {} },
        { id: 3, attrs: nil },
      ], db_name: "chn_ins_test")
      rows = client.query("SELECT id, attrs FROM chn_ins_test.m ORDER BY id")
      expect(rows).to eq([
        { id: 1, attrs: { "a" => 1, "b" => 2 } },
        { id: 2, attrs: {} },
        { id: 3, attrs: {} },
      ])
    end

    it "inserts into Map(LowCardinality(String), LowCardinality(String))" do
      client.execute(<<~SQL)
        CREATE TABLE chn_ins_test.lcm (
          id    UInt32,
          attrs Map(LowCardinality(String), LowCardinality(String))
        ) ENGINE = Memory
      SQL
      client.insert("lcm", [{ id: 1, attrs: { "exp" => "v1", "ab" => "control" } }],
                    db_name: "chn_ins_test")
      row = client.query("SELECT attrs FROM chn_ins_test.lcm WHERE id = 1").first
      expect(row[:attrs]).to eq("exp" => "v1", "ab" => "control")
    end

    it "round-trips Bool and Nullable(Bool) as Ruby true/false" do
      client.execute(<<~SQL)
        CREATE TABLE chn_ins_test.b (
          id      UInt32,
          active  Bool,
          flag    Nullable(Bool)
        ) ENGINE = Memory
      SQL
      client.insert("b", [
        { id: 1, active: true,  flag: true },
        { id: 2, active: false, flag: false },
        { id: 3, active: true,  flag: nil },
      ], db_name: "chn_ins_test")
      rows = client.query("SELECT id, active, flag FROM chn_ins_test.b ORDER BY id")
      expect(rows).to eq([
        { id: 1, active: true,  flag: true },
        { id: 2, active: false, flag: false },
        { id: 3, active: true,  flag: nil },
      ])
    end

    it "inserts into LowCardinality(String) and LowCardinality(Nullable(String))" do
      client.execute(<<~SQL)
        CREATE TABLE chn_ins_test.lc (
          category LowCardinality(String),
          tag      LowCardinality(Nullable(String))
        ) ENGINE = Memory
      SQL
      client.insert("lc", [
        { category: "a", tag: "x" },
        { category: "b", tag: nil },
      ], db_name: "chn_ins_test")
      rows = client.query("SELECT category, tag FROM chn_ins_test.lc ORDER BY category")
      expect(rows).to eq([
        { category: "a", tag: "x" },
        { category: "b", tag: nil },
      ])
    end

    it "memoizes the schema across repeated inserts into the same table" do
      row = { id: 1, name: "a", score: nil, tags: [], created: t }
      client.insert("t", [row], db_name: "chn_ins_test")
      first = client.instance_variable_get(:@schema_cache).fetch(%w[chn_ins_test t])
      client.insert("t", [row], db_name: "chn_ins_test")
      second = client.instance_variable_get(:@schema_cache).fetch(%w[chn_ins_test t])
      expect(second).to equal(first)
    end

    it "drops the memoized schema on clear_schema_cache" do
      row = { id: 1, name: "a", score: nil, tags: [], created: t }
      client.insert("t", [row], db_name: "chn_ins_test")
      expect(client.instance_variable_get(:@schema_cache)).not_to be_empty
      client.clear_schema_cache("t", db_name: "chn_ins_test")
      expect(client.instance_variable_get(:@schema_cache)).to be_empty
    end
  end

  describe "#query_each" do
    it "yields each row to the block" do
      rows = []
      client.query_each("SELECT number AS n FROM numbers(5)") { |row| rows << row }
      expect(rows).to eq([{ n: 0 }, { n: 1 }, { n: 2 }, { n: 3 }, { n: 4 }])
    end

    it "streams large result sets without materialising an array" do
      count = 0
      client.query_each("SELECT number FROM numbers(10000)") { |_| count += 1 }
      expect(count).to eq(10_000)
    end

    it "propagates an exception raised inside the block and keeps the client usable" do
      expect do
        client.query_each("SELECT number FROM numbers(100)") do |row|
          raise "boom" if row[:number] == 3
        end
      end.to raise_error("boom")
      # Connection was auto-reset; the client still works.
      expect(client.query_value("SELECT 1")).to eq(1)
    end

    it "supports early termination via a Ruby raise" do
      first = nil
      begin
        client.query_each("SELECT number FROM numbers(1000000)") do |row|
          first ||= row[:number]
          throw :done
        end
      rescue UncaughtThrowError
        # expected
      end
      expect(first).to eq(0)
      expect(client.query_value("SELECT 2")).to eq(2)
    end
  end

  describe "error mapping" do
    it "raises ServerError with code/name/message on server-side failures" do
      expect { client.query("SELECT no_such_function()") }.to raise_error do |err|
        expect(err).to be_a(ClickhouseNative::ServerError)
        expect(err.server_code).to be_a(Integer)
        expect(err.server_name).to be_a(String).and include("DB::Exception")
        expect(err.message).to include("no_such_function")
      end
    end

    it "raises ConnectionError when the host is unreachable" do
      expect { described_class.new(host: "127.0.0.1", port: 6553) }
        .to raise_error(ClickhouseNative::ConnectionError)
    end

    it "auto-resets after an error so the client stays usable" do
      expect { client.query("SELECT no_such_function()") }.to raise_error(ClickhouseNative::ServerError)
      expect(client.query_value("SELECT 1")).to eq(1)
    end
  end

  describe "#close" do
    it "releases the connection; subsequent calls raise ConnectionError" do
      client.close
      expect do
        client.query("SELECT 1")
      end.to raise_error(ClickhouseNative::ConnectionError, /closed/)
    end
  end

  describe "connection reuse" do
    it "serves many queries on one underlying socket" do
      30.times { expect(client.query_value("SELECT 1")).to eq(1) }
    end
  end

  describe "logger" do
    it "logs each SQL statement with elapsed time at :debug" do
      io = StringIO.new
      logger = Logger.new(io, level: :debug, formatter: -> (_, _, _, m) { "#{m}\n" })
      c = described_class.new(**CH_KWARGS, logger: logger)
      c.query_value("SELECT 42")
      c.close
      lines = io.string.lines
      expect(lines).to include(match(/\(\d+\.\d{3}ms\) SELECT 42/))
    end

    it "logs errors at :error" do
      io = StringIO.new
      logger = Logger.new(io, level: :debug, formatter: -> (sev, _, _, m) { "#{sev}: #{m}\n" })
      c = described_class.new(**CH_KWARGS, logger: logger)
      expect { c.query("SELECT no_such_function()") }.to raise_error(ClickhouseNative::ServerError)
      c.close
      expect(io.string).to include("ERROR:").and include("no_such_function")
    end
  end

  describe "compression" do
    it "round-trips identically under :lz4" do
      lz4 = described_class.new(**CH_KWARGS, compression: :lz4)
      expect(lz4.query_value("SELECT count() FROM numbers(1000)")).to eq(1000)
      rows = lz4.query("SELECT number AS n FROM numbers(10)")
      expect(rows.map { |r| r[:n] }).to eq((0..9).to_a)
      lz4.close
    end

    it "round-trips identically under :zstd" do
      z = described_class.new(**CH_KWARGS, compression: :zstd)
      expect(z.query_value("SELECT count() FROM numbers(1000)")).to eq(1000)
      z.close
    end

    it "rejects unknown compression at construction" do
      expect { described_class.new(**CH_KWARGS, compression: :snappy) }
        .to raise_error(ArgumentError, /compression/)
    end
  end
end

RSpec.describe ClickhouseNative::Pool, :clickhouse do
  subject(:pool) { described_class.new(**CH_KWARGS, pool_size: 4) }

  it "exposes the Client API" do
    expect(pool.query_value("SELECT 1")).to eq(1)
    expect(pool.ping).to be(true)
  end

  it "serves concurrent queries across its checked-out clients" do
    results = Array.new(8).map { Thread.new { pool.query_value("SELECT 1") } }.map(&:value)
    expect(results).to all(eq(1))
  end

  it "#with yields a Client handle" do
    pool.with { |c| expect(c).to be_a(ClickhouseNative::Client) }
  end

  it "exposes host/port/database" do
    expect(pool.host).to eq(CH_HOST)
    expect(pool.port).to eq(CH_PORT)
    expect(pool.database).to eq("default")
  end

  describe "ConnectionError retry" do
    it "retries once after a stale-connection ConnectionError" do
      attempts = 0
      result = pool.with do |client|
        attempts += 1
        raise ClickhouseNative::ConnectionError, "closed: Success" if attempts == 1
        client.query_value("SELECT 1")
      end
      expect(result).to eq(1)
      expect(attempts).to eq(2)
    end

    it "raises after the second ConnectionError" do
      attempts = 0
      expect do
        pool.with do
          attempts += 1
          raise ClickhouseNative::ConnectionError, "closed: Success"
        end
      end.to raise_error(ClickhouseNative::ConnectionError)
      expect(attempts).to eq(2)
    end

    it "does not retry non-connection errors" do
      attempts = 0
      expect do
        pool.with do
          attempts += 1
          raise ClickhouseNative::ServerError, "boom"
        end
      end.to raise_error(ClickhouseNative::ServerError)
      expect(attempts).to eq(1)
    end
  end

  describe "settings:" do
    it "applies Integer settings to every client on checkout" do
      p = described_class.new(**CH_KWARGS, pool_size: 2, settings: { max_threads: 7 })
      expect(p.query_value("SELECT getSetting('max_threads')")).to eq(7)
    end

    it "applies multiple settings in one SET" do
      p = described_class.new(
        **CH_KWARGS,
        pool_size: 2,
        settings: { max_threads: 3, max_execution_time: 42 },
      )
      expect(p.query_value("SELECT getSetting('max_threads')")).to eq(3)
      expect(p.query_value("SELECT getSetting('max_execution_time')")).to eq(42)
    end

    it "quotes non-numeric values as SQL strings" do
      p = described_class.new(
        **CH_KWARGS,
        pool_size: 1,
        settings: { log_comment: "chn-spec" },
      )
      expect(p.query_value("SELECT getSetting('log_comment')")).to eq("chn-spec")
    end

    it "applies the setting to every connection, not just the first" do
      # 4 clients, 8 concurrent reads — each must see the setting regardless
      # of which client the pool hands out.
      p = described_class.new(**CH_KWARGS, pool_size: 4, settings: { max_threads: 11 })
      results = Array.new(8).map do
        Thread.new { p.query_value("SELECT getSetting('max_threads')") }
      end.map(&:value)
      expect(results).to all(eq(11))
    end

    it "surfaces invalid setting names as ServerError at pool construction" do
      expect do
        described_class.new(**CH_KWARGS, pool_size: 1, settings: { no_such_setting: 1 })
          .ping
      end.to raise_error(ClickhouseNative::ServerError, /setting/i)
    end

    # Regression: a client whose query raised must not be reused. Reusing
    # it surfaces buffered protocol errors from the aborted operation on
    # the next send, attributing them to unrelated SQL (in particular the
    # session-settings SET we'd otherwise re-run). Discarding + replacing
    # is the safe path; the fresh client also gets settings re-applied by
    # the pool builder, so end-to-end behavior stays intact.
    it "re-applies settings on the next checkout after a query raised" do
      p = described_class.new(**CH_KWARGS, pool_size: 1, settings: { max_threads: 5 })
      expect(p.query_value("SELECT getSetting('max_threads')")).to eq(5)

      expect { p.query("SELECT no_such_function()") }
        .to raise_error(ClickhouseNative::ServerError)

      expect(p.query_value("SELECT getSetting('max_threads')")).to eq(5)
    end
  end

  describe "discard-on-error" do
    it "closes the client when its block raises" do
      p = described_class.new(**CH_KWARGS, pool_size: 1)
      captured = nil
      p.with { |c| captured = c }

      expect { p.with { raise "boom" } }.to raise_error("boom")

      expect { captured.ping }.to raise_error(ClickhouseNative::ConnectionError, /closed/)
      expect(p.ping).to be(true)
    end
  end
end

# Exercises the GC-driven cleanup path bypassed by spec_helper's
# auto-close hook. FD count is the observable; Ruby reclaims wrappers
# regardless of dfree's behavior, so an ObjectSpace assertion would
# pass even on a broken dfree.
RSpec.describe "ClickhouseNative::Client GC finalization", :clickhouse do
  it "releases native resources when a dropped Client is GC'd" do
    skip "Requires /proc/self/fd (Linux only)" unless File.directory?("/proc/self/fd")
    skip "Premise breaks under GC.stress" if GC.stress

    fd_count = -> { Dir.children("/proc/self/fd").size }
    baseline = fd_count.call
    20.times { ClickhouseNative::Client.new(**CH_KWARGS) }

    # Witness that sockets actually opened, or the post-GC check is meaningless.
    expect(fd_count.call - baseline).to be >= 20

    # Forces dfree synchronously; second pass flushes deferred finalizations.
    GC.start(full_mark: true, immediate_sweep: true)
    GC.start(full_mark: true, immediate_sweep: true)

    expect(fd_count.call).to be <= baseline
  end
end
