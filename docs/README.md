# `clickhouse-native` developer docs

Documentation for anyone working on this codebase. Read whichever is
relevant to what you're touching:

- **[boundary_risks.md](boundary_risks.md)** — non-negotiable invariants
  for working in `ext/clickhouse_native/client.cpp`. The Ruby/C++
  boundary has specific failure modes that don't show up in tests.
  Read before touching extension code.
- **[audit.md](audit.md)** — known correctness and behavior findings
  in the C extension and surrounding Ruby. Severity-ranked. Some
  items have been fixed (cross-reference `ext/clickhouse_native/patches/`
  for the running tally); the rest are open.
- **[ci_sanitizers.md](ci_sanitizers.md)** — how the ASan+UBSan and
  GC.stress CI jobs work, why we use clang+clang's libsanitizer
  instead of gcc, and how to read sanitizer failures when they
  appear.

For fork-local working notes (business motivation, contribution
roadmap, in-flight prioritization) see [internal/](internal/).
