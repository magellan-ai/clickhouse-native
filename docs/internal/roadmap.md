# Contribution roadmap

Outstanding work on `clickhouse-native`, derived from the audit
(`../audit.md`). The intent is for each item to land as a
self-contained PR upstream where it makes sense, and as a fork-local
patch otherwise.

Order is rough priority, not strict dependency.

## Done

### #0. AddressSanitizer + UBSan in CI

ASan + UBSan run as a per-PR merge gate; GC.stress runs alongside;
TSan runs nightly. See `../ci_sanitizers.md` for the setup.

Two real findings caught and patched along the way:
`patches/0002-guard-empty-string-memcpy.patch` (clickhouse-cpp) and
`patches/0004-lz4-zero-offset-on-null.patch` (vendored lz4).

## Outstanding

### #1. Make `query` and `query_value` GVL-releasing

**Reference:** `../audit.md#A1`.

**Scope:** Refactor `ch_client_query` and `ch_client_query_value` to
use the same no-GVL plumbing as `query_each`, accumulating rows /
selecting the first into a buffer that's returned after GVL
reacquire. ~30 lines of C++ refactor. New spec examples that
exercise concurrent `query` calls from multiple threads.

**Why high priority:** This is the single biggest production-grade
performance limitation today. Keeping `query` GVL-held undermines
the value proposition of a native-protocol gem.

### #2. Cache `BigDecimal` and `Date` constants in `Init`

**Reference:** `../audit.md#A6`.

**Scope:** ~5 lines added to `Init_clickhouse_native`, plus updates
to the decoder sites (lines 177, 196, 202 of `client.cpp`). Pure
perf win, no behavior change.

### #3. Thread `declared_type` recursively through `value_at`

**Reference:** `../audit.md#A2`. Documented limitation in
`client.cpp` lines 109–110.

**Scope:** Modify `value_at` to take a `declared_type` parameter (a
`std::string_view` or similar). Parse out nested type names from CH
type strings (e.g., `Array(Bool)` → recurse with `"Bool"`). Apply to
the existing top-level `Bool` special-case so it works inside
`Array`, `Map`, `Tuple`, `Nullable`. ~30–50 lines.

**Tests needed:** Round-trip for `Array(Bool)`,
`Map(String, Bool)`, `Nullable(Array(Bool))`,
`Tuple(Bool, Int8, Bool)`.

### #4. `[[noreturn]]` on `raise_mapped_ex`

**Reference:** `../audit.md#A7`.

**Scope:** One attribute, plus removal of unreachable `return Qnil`
statements at `client.cpp:290`, `:633`, `:816`, `:843`. Cleans up
compiler warnings; helps the optimizer.

### #5. `String` decoder encoding policy

**Reference:** `../audit.md#A4`.

**Scope:** Decide policy for `rb_utf8_str_new` vs.
`rb_str_new(...)` with `Encoding::ASCII_8BIT` for CH `String`,
`FixedString`, and `LowCardinality(String)` decode. Compatibility-
breaking; needs a deprecation cycle and probably a 1.0 release
boundary. Worth opening an issue first to align on direction.

### #6. Backslash-escape in `Pool#settings_sql`

**Reference:** `../audit.md#A8`.

**Scope:** One-line fix in `lib/clickhouse_native/pool.rb:98`. New
spec example with a setting value containing `\\` and `'`.

### #7. Fix `rb_jump_tag` longjmp leaks in `query_each`

**Reference:** `../audit.md#A3`.

**Scope:** Replace direct `rb_jump_tag` with a stack-guard pattern
that ensures C++ destructors run before the longjmp. Two approaches:
(a) wrap the function body in `rb_protect`-style indirection;
(b) hand-roll cleanup before each `rb_jump_tag` site. Option (a) is
cleaner but adds a level of indirection.

**Why later:** Memory leak is bounded and small. Real but not
urgent. Sanitizer findings would give a concrete reproduction to
verify the fix against.

### #8. Split `client.cpp` by concern

**Scope:** Mechanical refactor of the single 1,159-line `client.cpp`
into:
- `errors.cc` — exception type defs, `raise_mapped_ex`
- `codec_decode.cc` — `value_at` and decoder helpers
- `codec_encode.cc` — `append_value`, `append_default`, coercion
  helpers
- `client.cc` — TypedData, GVL plumbing, `Init_clickhouse_native`

Total line count unchanged; behavior unchanged. Changes
`extconf.rb`'s file list. Refactor PRs of this size are easier to
merge when pre-aligned with an issue.

### #9. Replace `value_at` / `append_value` switches with a registry

**Depends on #8.**

**Scope:** Each CH type registers a pair of `(decoder, encoder)`
function pointers under its `Type::Code`. `value_at` and
`append_value` become two-line dispatches into the registry. Same
behavior; smaller per-type review surface; sets up #10.

### #10. Add a Ruby-side TypeMap for user-extensible encode/decode

**Depends on #9.**

**Scope:** Mirror `pg`'s TypeMap architecture. Common types stay in
the C registry; users can register custom encoders/decoders in Ruby
for their own types via `Client#type_map=`.

**Why valuable:** Lifts the "every type must be C++" constraint.
Long-tail or user-specific types can live in Ruby.

### #11. Move Date / Time / Decimal coercion to Ruby

**Scope:** The C-side helpers `coerce_to_time`,
`coerce_to_date_epoch`, and the `BigDecimal` round-trip in the
encoder do Ruby-flavored work in C++. Move to a Ruby-side normalizer
that runs before `insert_block`. Saves ~80 lines of C++ that's
harder to debug than its Ruby equivalent.

**Tradeoff:** Two extra Ruby-side allocations per row inserted.
Marginal performance cost; readability/maintainability win.

## Out of scope

These are valid future directions but explicitly **not** what this
fork is doing:

- **Native protocol Ruby reimplementation** without `clickhouse-cpp`.
  Months of work; not the point of using this gem.
- **`clickhouse-activerecord` backend abstraction.** Separate gem,
  separate PR. Natural follow-on once `clickhouse-native` is
  production-stable.
- **Async-insert / batching APIs.** clickhouse-cpp supports these;
  the gem doesn't expose them yet. Useful but not blocking.
- **TLS configuration beyond what `clickhouse-cpp` already
  provides.** Probably a config-passthrough exercise; revisit when
  needed.

## How to update this document

When a numbered item lands (or is rejected), move it to the **Done**
section with a one-line summary linking the PR. Don't delete; the
audit trail of what was tried and how it landed is useful for
ongoing work.
