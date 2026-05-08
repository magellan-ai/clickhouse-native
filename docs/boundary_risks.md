# Working at the Ruby/C++ boundary: failure modes and mitigations

The non-negotiable invariants for contributions touching
`ext/clickhouse_native/`. Read before writing or reviewing any change
to the C extension.

## Why this document exists

The C extension contains substantial AI-authored code. That model
can produce excellent code; it can also produce code that *compiles,
links, and passes happy-path tests* but is subtly wrong in ways that
only manifest under load, GC pressure, signal handling, or specific
failure modes.

AI training data over-represents simple/correct C extension patterns
and under-represents the gnarly ones — exception unwinding across
language boundaries, GVL release/reacquire ordering, ownership of
native objects held by Ruby `VALUE`s. Without explicit top-of-mind
awareness of these failure modes, AI-generated code may
pattern-match against the most-common examples rather than the
correct-for-this-context ones.

The mitigations below apply equally to AI authorship and to a human
contributor who hasn't worked at this boundary before.

## The seven failure modes

In rough descending order of "looks fine, bites you in production":

### 1. C++ exceptions escaping into Ruby's stack

C++ exceptions cannot legally propagate through C stack frames. Ruby's
exception system uses `longjmp`; if a `longjmp` skips past a C++
destructor, you've leaked or corrupted state. The correct pattern:

```cpp
VALUE rb_method(VALUE self, VALUE arg) {
  try {
    auto result = some_clickhouse_cpp_call();   // may throw
    return convert_to_ruby(result);
  } catch (const std::exception& e) {
    rb_raise(rb_eRuntimeError, "%s", e.what()); // raise AFTER C++ unwinds
  } catch (...) {
    rb_raise(rb_eRuntimeError, "unknown C++ exception");
  }
  return Qnil;
}
```

The gem already uses this pattern correctly. Preserve it.

### 2. Ruby exceptions unwinding through C++ destructors

The mirror of #1. If Ruby code raises (interrupt, signal, `rb_raise`
from a deep call), the unwinding skips C++ destructors unless the
Ruby call site is wrapped in `rb_protect` or RAII guards that
explicitly handle Ruby's unwinding. Symptoms: leaked file
descriptors, leaked sockets, "the pool drained" mysteriously.

### 3. GVL release with concurrent Ruby API access

`rb_thread_call_without_gvl` lets other Ruby threads run during your
blocking syscall. The block you pass *cannot* call any function that
touches a `VALUE`, allocates Ruby memory, or invokes any Ruby C API
except a small whitelist. Doing so is undefined behavior — fine in
practice until it segfaults under load.

The classic mistake: the no-GVL block grabs `RSTRING_PTR(str)`,
releases the GVL, calls `send()` with that pointer. GC runs in
another thread, the string moves, the pointer is now garbage. The
correct pattern: copy the string into a non-Ruby buffer **before**
releasing the GVL, then pass the buffer.

### 4. Type marshaling at scale

For each of CH's 25+ types, there's a Ruby ↔ C++ conversion. Each
has edge cases — Decimal precision boundaries, Date timezone
semantics, String encoding, Nullable's three-state collapse to
nil/value, LowCardinality dictionary lookups, FixedString padding
semantics, `Array(Nullable(T))` vs. `Nullable(Array(T))` ordering.

"Works for ASCII strings up to 255 bytes" is a 90% correctness
signal that masks the 10% that doesn't.

### 5. Memory ownership at the boundary

Who owns the bytes? `RSTRING_PTR` returns a pointer valid only until
the next Ruby allocation (because GC may move strings).
clickhouse-cpp's `Block` / `Column` objects hold their own buffers;
stashing a pointer into one and using it after the `Block` is freed
is use-after-free.

### 6. Thread-safety claims that aren't

`clickhouse-cpp::Client` is not thread-safe — one connection per
thread. The `Pool` enforces this, but pool semantics break if a
callback runs after the connection is returned to the pool.

### 7. Interrupt safety

Ctrl-C raises `Interrupt`. If a long-running C extension call doesn't
periodically call `rb_thread_check_ints` or release the GVL, it's
uninterruptible — exactly the situation the native protocol is meant
to *avoid*. (CH queries take minutes; if the user can't kill them,
you've made things worse.)

The gem currently dodges this acceptably: the `unblock` functions
passed to `rb_thread_call_without_gvl` call
`client->ResetConnection()`, which kills the socket. Ctrl-C tears the
connection. The pool then discards the bad client.

## Mitigations

In rough order of cost-effectiveness:

1. **Sanitizer-instrumented CI is mandatory** for boundary changes.
   AddressSanitizer + UBSan catch use-after-free, double-free, OOB
   read/write, undefined behavior. ThreadSanitizer catches data
   races. See [ci_sanitizers.md](ci_sanitizers.md) for the setup.
2. **`GC.stress = true` in CI.** Makes GC run on every allocation.
   Bugs hiding behind "GC didn't happen this time" surface
   immediately. There's a CI job for this; the activation marker is
   `[spec_helper] GC.stress = true` in the log.
3. **Boundary-PR checklist.** Mechanical to verify:
   - Every C++ exception path is caught at the C boundary.
   - No Ruby C API call inside `rb_thread_call_without_gvl`.
   - Every `RSTRING_PTR` is either copied before the no-GVL block or
     held only while the GVL is held.
   - Every long-running loop has `rb_thread_check_ints` or releases
     the GVL.
4. **Line-by-line review of every C/C++ change**, not skim. This is
   the part that scales worst, but it's the only thing that catches
   *plausible-but-wrong* bugs. The good news: the C extension
   shouldn't grow much beyond its current ~1,200 lines, and most
   changes will be small.
5. **Stress-test under realistic concurrency.** Spawn many threads
   doing real queries on real data, with `GC.stress = true` and the
   pool sized smaller than the thread count. Most boundary bugs
   surface here.

## Conventions for boundary code for AI collaborators (and humans)

These are durable expectations for any function bridging Ruby and
C++:

1. **Be loud about uncertainty.** "I'm not 100% sure this can't
   trigger GC; let's check `pg`'s pattern" beats confident
   wrongness.
2. **Write contracts before code.** A header comment stating: who
   owns what, what can throw, who holds the GVL. If you can't write
   that comment, you don't understand it well enough to write the
   code.
3. **Use `rb_protect` / C++ exception catching even when it seems
   unnecessary.** Belt and suspenders. The cost is small; the
   alternative is a segfault.
4. **State GVL holding/releasing explicitly** in code comments. This
   is invisible at the call site but critical to correctness.
5. **Prefer small, reviewable changes.** A 500-line C++ PR is harder
   to review correctly than five 100-line PRs.
6. **Cross-check Ruby C API minutiae** — macro choice (`FIX2*`,
   `NUM2*`, `RB_*`), what triggers GC, what's safe inside a
   `without_gvl` block — against the Ruby C API docs or another
   well-maintained C extension's implementation (`pg` is a good
   reference for boundary code).

## What this gets us

These mitigations probably move boundary code from "AI-authored or
C-ext-novice code with hidden bugs" to "code with the same risk
profile as a competent contributor who hasn't worked on Ruby C
extensions before." Both still need real review and stress testing.
Neither is the same as code from someone who's spent years on this
specific boundary. That's the honest read; the project proceeds with
eyes open.
