# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Fork-local context

This is a fork of `umbrellio/clickhouse-native` maintained for use by Magellan AI's `war-of-the-worlds` Rails app.

Two doc trees, different audiences:

- **`docs/`** — maintainer-facing docs that travel with this codebase. Read `docs/README.md` for the index; `docs/boundary_risks.md` is required reading before any change to `ext/clickhouse_native/client.cpp`.
- **`docs/internal/`** — fork-local working notes (business motivation, contribution roadmap). Read `docs/internal/README.md` for orientation on why this fork exists and what we're prioritizing. **This subtree must not be included in PRs to upstream**; see its README for the convention.

The TL;DR for fast onboarding:

- **Why we're here**: the Ruby ecosystem's existing CH drivers all use HTTP, which gets killed by AWS EC2's 5-minute idle timeout for long-running CH queries. We need the native TCP protocol. This gem is the only realistic Ruby implementation.
- **The C extension is AI-authored** (upstream and ongoing). That carries specific risks at the Ruby/C++ boundary — see `docs/boundary_risks.md`. Heightened vigilance in C extension territory is required.
- **Sanitizer-instrumented CI is wired up and is a merge gate.** See `docs/ci_sanitizers.md` for how it works and how to read failures.

## Build and test

The native extension wraps the vendored `clickhouse-cpp` C++ client (a git submodule under `ext/clickhouse_native/vendor/clickhouse-cpp`). After cloning, run `git submodule update --init --recursive` — without it `extconf.rb` aborts.

```
docker compose up -d clickhouse        # ClickHouse on :9000 (native) and :8123 (HTTP, for benchmarks)
bundle exec rake compile               # builds vendored clickhouse-cpp + the .bundle/.so
bundle exec rspec                      # runs spec/clickhouse_native_spec.rb against the running server
bundle exec rspec spec/clickhouse_native_spec.rb -e "some example"  # single example
bundle exec rubocop
```

`rake compile` chains through `rake cpp_rebuild`, which re-applies `ext/clickhouse_native/patches/*.patch` to the vendored tree and runs `cmake --build tmp/cpp-build-<arch>`. If the static lib advances, the existing extension `.bundle`/`.so` under `lib/clickhouse_native/` is removed so mkmf relinks. **Do not edit files under `ext/clickhouse_native/vendor/clickhouse-cpp/` directly** — modify them via a new patch in `ext/clickhouse_native/patches/` so they survive `git submodule update`.

The CMake build dir is keyed by `RbConfig::CONFIG["arch"]` (e.g. `tmp/cpp-build-arm64-darwin24`). Switching architectures or cross-compiling won't collide. To force a clean C++ rebuild, `rm -rf tmp/cpp-build-*`.

Tests connect to a real server (`localhost:9000` by default; override with `CLICKHOUSE_HOST` / `CLICKHOUSE_PORT`). There are no mocks — `docker compose up -d clickhouse` is required.

Cross-compiled native gems (`rake gem:cross:<platform>`, or `gem:cross:all`) run inside `rake-compiler-dock` Docker images. Targets are pinned in `Rakefile` (`CROSS_PLATFORMS`, `CROSS_RUBIES`).

## Architecture

Three layers, top-down:

1. **Ruby surface** — `lib/clickhouse_native/`
   - `Client` (`client.rb`): high-level `#insert`, `#describe_table`, `#clear_schema_cache`. Memoizes table schemas per `(db_name, table)` so repeated inserts skip `DESCRIBE`. Pure Ruby on top of the C extension.
   - `Pool` (`pool.rb`): wraps `connection_pool` and re-exposes the `Client` surface (minus `close` / `reset_connection`). Owns session-settings `SET` rendering and the discard-on-error / single-retry policy for stale sockets — see the long comment on `Pool#with`.
   - `Logging` (`logging.rb`): a module `prepend`ed onto `Client` that wraps `execute` / `query` / `query_value` / `query_each` / `insert_block` with Sequel-style timing logs. Logging hooks land **on the C-defined methods**, so don't rename or skip those names.
   - `Errors` (`errors.rb`): hierarchy under `ClickhouseNative::Error`. The C extension imports these constants in `Init_clickhouse_native` and raises into them.

2. **C++ extension** — `ext/clickhouse_native/client.cpp` (single file, ~1100 lines). Defines `ClickhouseNative::Client` with `initialize`, `execute`, `query`, `query_value`, `query_each`, `insert_block`, `ping`, `server_version`, `reset_connection`, `close`. Responsibilities:
   - Encode Ruby values → `clickhouse-cpp` `Column` objects per declared CH type (`#insert`).
   - Decode `Block` columns → Ruby hashes (queries).
   - Release the GVL (`rb_thread_call_without_gvl`) around every blocking C++ call, so a `Pool` of size N actually runs N concurrent queries.
   - Map C++ exceptions to the right `ClickhouseNative::*` error class via `raise_mapped_ex`. The encoder/decoder paths intentionally *throw* internal exception types (`chn::EncoderFailure`, `chn::UnsupportedType`, `chn::DecoderFailure`) instead of `rb_raise`-ing inline so that the outer `catch` runs `ResetConnection()` and the pooled client doesn't stay mid-packet.

3. **Vendored clickhouse-cpp** — submodule, statically linked. Patched in-tree under `ext/clickhouse_native/patches/`:
   - `0001-preserve-declared-column-type.patch` — clickhouse-cpp normalises `Bool` to `UInt8` on the wire; the patch keeps the declared type so the extension can decode top-level `Bool` as Ruby `true`/`false`. Nested `Bool` (inside `Array` / `Map` / `Tuple`) still decodes as `UInt8` — see the encoding/decoding tables in README.md before changing this.

### Type system

The encode/decode mapping is the most subtle part of the codebase. The README's two tables (Decoding ClickHouse → Ruby, Encoding Ruby → ClickHouse) are the source of truth — keep them aligned with `client.cpp` when you change either side. Notable asymmetries:

- `Map`, arbitrary `Tuple`, `Dynamic`, `Variant`, typed `JSON` and other CH 24.x+ types **decode** but **don't encode** for `#insert` (raise `EncoderError` / `UnsupportedTypeError`).
- `nil` on a non-`Nullable` column silently coerces to the column's zero/empty default — matches the prior HTTP gem's `JSONEachRow` semantics. A test relies on this, don't tighten it without discussion.

### Insert path

`Client#insert` → resolves `(column_name, ch_type)` pairs (from `types:`, or by hitting `cached_schema` / `DESCRIBE`) → converts hash rows to positional arrays → calls C-level `insert_block(fq, col_pairs, row_arrays)`. Empty `rows` short-circuits without touching the server. After `ALTER TABLE`, callers must invoke `clear_schema_cache` (the cache is per-`Client`, so pooled callers may want to recreate the pool instead).

### Concurrency / pool semantics

`Client` is **not** thread-safe; concurrent work goes through `Pool`. `Pool#with` discards a connection on any exception (the C++ binding's `ResetConnection` doesn't drain buffered protocol errors from the previous aborted op, which would otherwise be misattributed to the next SQL — usually the SET re-applying session settings, producing confusing log lines). `ConnectionError` gets exactly one automatic retry to handle FIN'd idle pooled sockets that surface as `closed: Success` on first recv; the retry only runs because the failure happened before any data was sent, so writes don't risk double-execution.

## Conventions

- Frozen string literals everywhere (`# frozen_string_literal: true`).
- RuboCop config inherits `rubocop-config-umbrellio`, target Ruby 3.3. Vendored C++, `pkg/`, `tmp/`, `vendor/` are excluded.
- Required Ruby ≥ 3.3 (`gemspec`). Don't reach for ≥ 3.4-only syntax.
- Connection options on `Client.new` / `Pool.new` are **keyword-only**.

## Working in `client.cpp` — non-negotiables

These are durable invariants the existing code relies on. Don't break them without explicit discussion. The full taxonomy of why these matter is in `docs/boundary_risks.md`.

- **C++ exception translation pattern**: throw an internal `chn::*` exception type inside a `try`, catch and call `raise_mapped_ex(e)` *after* the C++ stack has unwound. **Never** `rb_raise` from inside a `try` block — it `longjmp`s past C++ destructors.
- **GVL release plumbing**: every blocking clickhouse-cpp call goes inside an `*_no_gvl` function passed to `rb_thread_call_without_gvl`. Inside that function, **no Ruby C API calls** — no `RSTRING_PTR`, no `rb_*`, nothing. Capture exceptions via `std::exception_ptr`; rethrow after GVL reacquire. Copy any Ruby-owned bytes into a `std::string` *before* releasing the GVL.
- **`query_each`'s GVL re-entry**: the `SelectCancelable` callback runs inside the no-GVL block; to yield to the user's Ruby block it must `rb_thread_call_with_gvl(with_gvl_yield, ...)` first. The `with_gvl_yield` body uses `rb_protect` to catch Ruby exceptions and set `aborted = true` on the shared state.
- **`raise_mapped_ex` is `[[noreturn]]` in spirit** (every branch ends in an `rb_raise` / `rb_exc_raise`). Adding the attribute is on the roadmap; until then, never write code after a `raise_mapped_ex` call.
- **`StringValue(value)` before `RSTRING_PTR(value)`**, always. And don't hold the resulting pointer across any Ruby allocation.
- **The vendored clickhouse-cpp's `Append(string_view)` copies its argument** — we rely on this for the encoder's correctness. Don't change to a function that stores the view.
- **No `VALUE`s stored in the `CHClient` TypedData struct.** If you ever add one, you must also add a `dmark` callback for GC to mark it. Easier to keep the struct VALUE-free.

When in doubt: write a header comment stating who owns what, what can throw, and who holds the GVL, **before** writing the function body. If you can't write that comment, you don't yet understand the invariants well enough to write the code.
