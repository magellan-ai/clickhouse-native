# Why this gem matters to Magellan AI

Background context for `magellan-ai/clickhouse-native`: why a Ruby
ClickHouse driver speaking the native binary protocol is load-bearing
for our Rails app, and what that implies for the work we're doing here.

## The originating constraint

The hard constraint that drives the need for the native protocol:

> AWS EC2 terminates any TCP connection that goes 5 minutes without
> data transfer. For Ruby workloads talking to an EC2-hosted
> ClickHouse instance, that's a hard ceiling on long-running queries
> over HTTP. A query that takes 10 minutes before producing output
> — anything with a heavy `ORDER BY`, for instance — has its HTTP
> connection killed mid-flight at the 5-minute mark. The server-side
> query may keep running (`cancel_http_readonly_queries_on_client_close`
> only applies to readonly queries), but the Ruby process waiting on
> the response sees an EOF with no clean way to learn whether the
> query succeeded.

The native binary protocol uses a persistent TCP connection with
keepalive that doesn't trip this. It also uses columnar block
streaming, which is meaningfully more efficient than HTTP+JSON/TSV
even within the 5-minute window.

## Why this specific gem

`clickhouse-native` is the only Ruby gem currently using the native
TCP protocol; the other active gems (`click_house`,
`click_house-client`, `clickhouse-activerecord`, `clickhouse-rb`)
all use HTTP. Within HTTP-only options, none has signaled native
roadmap interest, and at least one tightly couples HTTP to the
ActiveRecord adapter in a way that would require an upstream
refactor before native could be plugged in.

The gem itself is architecturally what we'd build from scratch:
vendor `clickhouse-cpp`, expose it via a C extension, ship
precompiled binary gems, release the GVL on blocking calls, layer a
connection pool on top. Apache-2.0 licensed.

## What this fork is for

The plan is to adopt `clickhouse-native` as the transport layer for
ClickHouse access in our Rails workloads, replacing the current
HTTP-via-`clickhouse-activerecord` path. Ahead of putting it in
production, this fork is where we audit the C extension, wire up
sanitizer-instrumented CI, and stage contributions back upstream.

The expected long-term arc:

- Improvements that are clearly upstream-friendly become PRs back to
  the source repo. See `roadmap.md` for what's on deck.
- Anything fork-only (sanitizer suppressions tuned to our patches,
  deeper instrumentation, pre-release experimentation) lives here.
- Once the gem is production-stable for our workload, the fork
  becomes a thin overlay on upstream.

## Future related work (out of scope here)

Adding a backend abstraction to `clickhouse-activerecord` so the
ActiveRecord adapter can swap HTTP for native transport. Separate
gem, separate PR. Not blocking the immediate use case.
