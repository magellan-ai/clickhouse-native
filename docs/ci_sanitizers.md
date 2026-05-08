# Sanitizer CI

This document covers the memory- and thread-safety CI infrastructure
for the C extension: the `sanitize` job (ASan + UBSan, per-PR merge
gate), the `gc-stress` job (per-PR), and the `tsan` nightly job. It
explains why the configuration looks the way it does and how to read
failures when they appear.

## Why sanitizers

The C++ extension is the single highest-risk piece of code in the
gem. It bridges Ruby and clickhouse-cpp at every point where a Ruby
thread calls into native code; it manages exceptions, GVL state, and
memory ownership across that boundary. Bugs in this layer:

- Are often invisible in single-threaded happy-path tests.
- Manifest as production segfaults, mysterious connection drops, or
  "the worker pool got confused" reports that are unreproducible
  locally.
- Are exactly the class of error that sanitizers catch
  *deterministically and immediately* — turning "may segfault
  eventually under load" into "fails this CI run."

The `sanitize` job is a merge gate: a PR that introduces a heap
use-after-free, a buffer overflow, or undefined behavior in the C
extension or vendored clickhouse-cpp will fail this job. Two real
findings have been caught and patched this way — both in vendored
library code that would otherwise have shipped to production
silently:

- `ext/clickhouse_native/patches/0002-guard-empty-string-memcpy.patch`:
  `memcpy(_, NULL, 0)` in clickhouse-cpp's
  `ColumnString::Block::AppendUnsafe`.
- `ext/clickhouse_native/patches/0004-lz4-zero-offset-on-null.patch`:
  three zero-offset-on-null pointer arithmetic sites in vendored lz4.

Both were `runtime error: applying zero offset to null pointer`-class
UB — benign on every real implementation, real standards violations.
UBSan caught them; the gem now ships the patched code.

## Ruby-specific gotchas

Most "how to add ASan to your project" guides assume a pure C++ CMake
project. This is a Ruby gem with a C++ extension. The differences:

1. **Instrument the extension only, not Ruby itself.** The runner's
   pre-installed Ruby is not sanitizer-instrumented; rebuilding it
   from source is excessive. Compile only `client.cpp` + the linked
   clickhouse-cpp under sanitizers.

2. **Inject sanitizer flags via `CFLAGS` / `CXXFLAGS` / `LDFLAGS` at
   compile time.** mkmf picks them up if they're set in the
   environment before `bundle exec rake compile` runs.

3. **Preload both sanitizer runtimes at test time.**
   `-fsanitize=address,undefined` leaves `__asan_*` *and* `__ubsan_*`
   symbols undefined in the resulting `.so`. The ASan runtime only
   provides the former; the UBSan vptr check pulls in
   `__ubsan_vptr_type_cache` from the UBSan runtime. Preload both,
   colon-separated. With clang (what we use — see "Compiler / runtime
   choice"):
   `LD_PRELOAD="$(clang -print-file-name=libclang_rt.asan-x86_64.so):$(clang -print-file-name=libclang_rt.ubsan_standalone-x86_64.so)"`.
   ASan's `malloc`/`free` interceptors must also hook before Ruby's
   runtime initializes — that's why preload, not `LD_LIBRARY_PATH`.

4. **Disable LSan.** Ruby's conservative GC scans the stack for
   pointers, which trips LSan's heuristics constantly. Until we
   have a comprehensive suppressions file for Ruby internals, set
   `ASAN_OPTIONS=detect_leaks=0` and live without leak detection.
   The bounded-leak findings noted in `audit.md#A3` will surface in
   valgrind runs (separate job, see "Follow-ups" below).

5. **`abort_on_error=1`** makes ASan terminate the test process on
   the first violation, which surfaces as a CI failure. Without it,
   ASan's default is to log and continue, which can mask the
   originating violation behind cascading failures.

This is well-trodden territory — `nokogiri`, `sqlite3-ruby`, `mysql2`,
and `oxidized` all use this pattern. There just isn't a one-size-fits-all
"Ruby C extension sanitizer" reusable workflow analogous to what
exists for pure C++ projects.

## Compiler / runtime choice

The sanitize job builds with `clang` and preloads clang's
`libclang_rt.asan` + `libclang_rt.ubsan_standalone`, not gcc and gcc's
libsanitizer. Both compilers' `-fsanitize=address,undefined` options
look identical from the user's side, but the runtime libraries are
*not* ABI-compatible with each other: a clang-instrumented `.so`
linked against clang-runtime symbols will not load against gcc's
`libasan.so`, and vice versa. So compiler and runtime have to match.

We use clang because of how its libsanitizer interacts with a bug
that's present in *both* runtimes: every pthread TSD destructor on
GitHub's Ubuntu runners fires a
`CHECK failed: sanitizer_common*.cpp "((0 && \"unable to unmmap\")) != (0)"`
abort, with the runtime trying to munmap a non-page-aligned address
inside its own primary-allocator region (`0x500000000000-0x540000000000`).
This is libsanitizer-internal, not gem code:

- No preceding `==NNNN==ERROR: AddressSanitizer:` finding — the abort
  is the very first ASan message in the log.
- The tests themselves pass (`64 examples, 0 failures`) before the
  abort fires.
- Three subsystem toggles ruled out as the cause
  (`detect_stack_use_after_return=0`,
  `allocator_release_to_os_interval_ms=-1`,
  `thread_local_quarantine_size_kb=0:quarantine_size_mb=0`).
  The abort persists with all three off, so it's deeper in the
  runtime's `AsanThreadContext` / DTLS teardown path, not in any
  user-tunable subsystem.
- Three libsanitizer builds ruled out (libasan.so.8 from gcc-13 on
  ubuntu-24.04, libasan.so.6 from gcc-11 on ubuntu-22.04, and clang's
  compiler-rt 18 on ubuntu-24.04). All three abort in the same path
  with the same address pattern. This is upstream LLVM/compiler-rt
  shared by gcc's libsanitizer and clang's, not a packaging issue.

The reason clang still wins, despite the bug being present in both:
the runtimes differ in how the abort *propagates* to process exit
status.

- gcc's libsanitizer: TSD destructor's CHECK fires fatal abort
  *during* test execution, killing the process mid-suite. Real
  sanitizer findings never get a chance to surface — the abort is
  the only thing in the log.
- clang's libsanitizer: the same CHECK fires, but the way it
  interacts with Ruby's `rb_bug_for_fatal_signal` handler and
  glibc's atexit ordering, control returns to the in-progress
  `exit()` after the BUG dump and the process exits with whatever
  rspec set. Net effect: tests pass → exit 0; real finding fires
  → its abort sets exit 134 *first*, then the TSD cascade runs as
  noise during teardown. We get the right exit code in both cases,
  with the TSD cascade as visual log noise.

This is the entire reason patches 0002 and 0004 in
`ext/clickhouse_native/patches/` exist: clang's UBSan caught real UB
in the vendored `clickhouse-cpp` (an empty-`string_view` `memcpy`,
and three zero-offset-on-null patterns in lz4) that gcc's broken-CHECK
setup never let us see. Without clang, those bugs would still be in
production-shipped binaries.

### What we're depending on

The exit-code behavior is a 4-way interaction between glibc, the
clang compiler-rt 18 in `/usr/lib/llvm-18/`, libstdc++ destructor
ordering, and Ruby 4.0.3's signal handler. Ubuntu image refreshes,
Ruby version bumps, or a libsanitizer minor revision could shift it.
**Symptom of drift**: sanitize job starts failing exit 134 even on
green test runs, with no preceding `==NNNN==ERROR:` line.
**Resolution**: scope the job to non-threaded specs by tagging the
two threaded `Pool` specs `:threaded` and running
`bundle exec rspec --tag ~threaded --format progress` in the sanitize
step. That avoids the TSD destructor path entirely (no extra
pthreads exit during the test run). Cost: lose ASan coverage on the
2 threading-specific Pool specs, which mostly exercise Ruby-side
ConnectionPool semantics rather than C++ codepaths. The full test
matrix still runs them.

A more aggressive fallback if even non-threaded specs trip the bug
in the future: accept `continue-on-error: true`, never gate on the
job. Worst option — the coverage becomes permanently advisory.

### Design notes

- **Single Ruby version (4.0) and single CH version (25.3)** for the
  sanitize job, instead of the full matrix. Sanitizer findings are
  about C++ code that doesn't change across the matrix; matrix
  multiplication adds time without signal.
- **No `actions/cache`** for the compiled clickhouse-cpp static
  library. Caching it across runs would cut build time roughly in
  half, but the initial setup chose to keep the diff focused. Add it
  if iteration becomes painful.

## TSan nightly

`.github/workflows/tsan.yml` runs ThreadSanitizer on a daily cron
(plus `workflow_dispatch` for ad-hoc triggers). Same shape as the
sanitize job; `address` → `thread`, `undefined` dropped (TSan and
UBSan don't compose). Build still uses gcc and preloads `libtsan.so`
from gcc — the TSDDtor bug that pushed ASan to clang doesn't
manifest here, so no need to switch. ~10–18 min runtime per run.
Still soft-launched (`continue-on-error: true`) while findings get
triaged.

**Suppressions.** TSan reads `.tsan-suppressions` at the repo root
via `TSAN_OPTIONS=suppressions=...`. Format is one
`<rule>:<pattern>` per line. The current entry suppresses
`deadlock:rb_native_mutex_lock` — a known false positive: Ruby's
internal mutexes (GVL, ractor scheduler, waiter lists, signal
handler) acquire in different orders depending on the initiating
thread, which trips TSan's lock-order graph. The locking is correct
in practice; see the bug-tracker discussion at
[bugs.ruby-lang.org](https://bugs.ruby-lang.org/) for similar
reports. Diagnostic signature for "this is a Ruby-internals false
positive": every frame in the report is inside Ruby's
`thread_pthread.c`, no gem code on the stack.

Suppress only patterns actually seen, not preemptively. If new false
positives surface, add narrow lines to `.tsan-suppressions`; if real
findings surface, fix at the source.

## GC.stress

A separate `gc-stress` job runs the spec suite under
`GC.stress = true` — GC fires on every allocation, surfacing "the
bug only manifests when GC happens here" issues. Adjacent in risk
profile to ASan/UBSan but a different bug class (unrooted `VALUE`s
held across allocations in the C extension).

Activation: Ruby's `RUBY_GC_STRESS` env var is not reliably honored
across CRuby builds — a job that only sets that var can pass in
seconds without ever applying stress. To avoid the false-confidence
trap, `spec/spec_helper.rb` opts into `GC.stress` when
`CLICKHOUSE_NATIVE_GC_STRESS=1` is set, and prints a marker line
`[spec_helper] GC.stress = true`. **If that line is missing from a
CI log, stress was not active for that run.**

## Follow-ups

### Valgrind on a smoke subset

Valgrind is slower than any of the sanitizers (10–30× runtime) but
catches things they miss — particularly fine-grained
uninitialized-memory reads — and it doesn't need a special build of
the extension. Useful as a third opinion. Skip if MSan ends up
configured (which requires a Clang-instrumented stdlib, more setup).

## Local development

To run the suite under sanitizers locally before pushing:

```bash
# Wipe any prior build so the sanitizer flags actually apply.
rm -rf tmp/cpp-build-* lib/clickhouse_native/clickhouse_native.bundle \
       lib/clickhouse_native/clickhouse_native.so

# Same env as the CI job — clang + clang's libsanitizer (not gcc).
CC=clang CXX=clang++ \
CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -O1 -g" \
CXXFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -O1 -g" \
LDFLAGS="-fsanitize=address,undefined" \
  bundle exec rake compile

ASAN_OPTIONS="detect_leaks=0:abort_on_error=1:print_stats=1" \
UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
LD_PRELOAD="$(clang -print-file-name=libclang_rt.asan-x86_64.so):$(clang -print-file-name=libclang_rt.ubsan_standalone-x86_64.so)" \
  bundle exec rspec
```

On macOS, `LD_PRELOAD` becomes `DYLD_INSERT_LIBRARIES` and the runtime
filenames carry a `_osx_dynamic` suffix (e.g.
`libclang_rt.asan_osx_dynamic.dylib`). System Integrity Protection
strips `DYLD_*` env vars from setuid binaries and certain Apple-shipped
processes, but Ruby installed via `rvm`/`asdf`/`mise` is fine. CI runs
on Linux; macOS local runs are best-effort.
