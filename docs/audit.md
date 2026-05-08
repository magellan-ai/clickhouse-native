# Code audit findings

Performed against the codebase at v0.8.0 (April 29, 2026), focused on
the C++ extension at `ext/clickhouse_native/client.cpp` (1,159 lines)
and the thin Ruby layer above it (`lib/clickhouse_native/`, ~310 lines
total). See `boundary_risks.md` for the failure-mode taxonomy that
informed which patterns to look for.

## Codebase strengths

- **C++ exception translation pattern is the right one.** Internal
  errors are thrown as `chn::EncoderFailure` / `chn::UnsupportedType`
  / `chn::DecoderFailure` (subclasses of `clickhouse::Error`) inside
  the `try` block, then `raise_mapped_ex(e)` is called from the
  `catch` handler — only after C++ stack unwinding has run all
  destructors. The header comment at lines 36–38 of `client.cpp`
  explicitly explains: *"throwing (instead of rb_raise) lets the
  outer catch run."* That insight does not come from naively
  pattern-matching on existing code.
- **GVL release/reacquire is structured canonically.** `execute`,
  `insert_block`, `query_each`, `ping` each put their work in a
  `*_no_gvl` function. Inside those functions, no Ruby C API calls
  are made — only `client->Execute()`, `client->Insert()`, etc.
  Exceptions are captured via `std::exception_ptr` and rethrown after
  GVL reacquisition.
- **`query_each` correctly handles the bidirectional GVL transition.**
  `SelectCancelable`'s callback runs inside the no-GVL block. The
  callback uses `rb_thread_call_with_gvl(with_gvl_yield, ...)` to
  reacquire the GVL just for the duration of yielding to the user's
  Ruby block. `with_gvl_yield` then uses `rb_protect` to catch any
  Ruby exception from the user's block, captures the tag, and sets
  `aborted = true`. The C++ side observes `aborted` and stops
  streaming. This is non-trivial to get right.
- **No Ruby `VALUE`s held inside the `CHClient` struct.** No `dmark`
  is needed; no GC-marking concerns; `RUBY_TYPED_FREE_IMMEDIATELY` is
  appropriate.
- **`StringValue(value)` is called before `RSTRING_PTR(value)`
  everywhere it's used.** Resulting bytes are copied into
  `std::string` or passed to clickhouse-cpp `Append` (which copies
  internally). No call site found that holds a `RSTRING_PTR` across
  a Ruby allocation.
- **Error cleanup is paranoid in the right way.**
  `try { ResetConnection(); } catch (...) {}` wraps every error path
  so a partially-consumed protocol stream doesn't poison the next
  operation on this connection. The pool layer also discards-on-error.

## Outstanding concerns, ranked by severity

### High

**A1. `query` and `query_value` do not release the GVL.**

The doc comment at line 779 of `client.cpp` says so explicitly.
`query_each` is the GVL-releasing variant. Anyone using the simpler
`query` API blocks all other Ruby threads for the duration of the
query — defeating a central reason for choosing a native protocol
gem. For a background job worker pool running concurrent CH queries,
this is a production-grade performance limitation.

*Fix shape:* Refactor `ch_client_query` to be `query_each` + `<<` into
an array. ~20 net lines of code.

**A2. Nested `declared_type` is not propagated through decode.**

Lines 109–110 of `client.cpp` document the limitation: *"Nested
occurrences (Array(Bool), Map(_, Bool)) are not handled — the declared
type for nested children is not threaded through recursion."*

Effect: `Array(Bool)` columns decode silently as `Array<UInt8>` (you
get `[0, 1, 1]` instead of `[false, true, true]`). Same for
`Map(K, Bool)` and `Tuple(..., Bool, ...)`. Real bug; surfaces with no
exception.

*Fix shape:* `value_at` takes a recursive `declared_type` parameter and
parses out nested type names. ~30 lines.

### Medium

**A3. `rb_jump_tag` through C++ stack frames leaks bounded memory.**

`query_each`'s cleanup paths (lines 1042 and 1048 of `client.cpp`)
call `rb_jump_tag(state.exc_tag)`, which uses `longjmp` and skips
C++ destructors. Local `QueryEachState` and `QueryEachNoGVL` structs
hold `std::vector<ID>` and `std::exception_ptr`; their destructors
do not run.

The leak is small (a few hundred bytes per longjumped query) and
bounded (one per query that raises through the user's block), but
ASan/valgrind will flag it. Fixing requires either wrapping the
function body in an `rb_protect`-style stack guard or hand-writing
cleanup before `rb_jump_tag`.

**A4. `String` decoder always tags Ruby strings as UTF-8.**

Lines 184, 188, 247 of `client.cpp`: `rb_utf8_str_new(...)` for any
CH `String`, `FixedString`, or `LowCardinality(String)` content. CH
`String` is "arbitrary bytes" — binary blobs come back tagged UTF-8
and any encoding-aware operation (`String#valid_encoding?`,
regex match, `each_char`) misbehaves.

A safer default: `rb_str_new(...)` with `Encoding::ASCII_8BIT`,
opt-in `Encoding::UTF_8` for callers who know the column is text.
This is a compatibility-breaking change; needs a deprecation cycle
and probably a 1.0 release boundary.

### Low

**A6. Repeated `rb_const_get` for `BigDecimal` / `Date` on every decode.**

Each `Decimal` cell decoded calls
`rb_const_get(rb_cObject, rb_intern("BigDecimal"))`. Each `Date`
calls the same for `Date`. For wide rows over many records, this is
hundreds of thousands of redundant constant lookups.

*Fix:* Cache `rb_cBigDecimal` and `rb_cDate` as global VALUEs in
`Init_clickhouse_native`, alongside the existing cached `rb_cTime`.
~5 lines.

**A7. `raise_mapped_ex` lacks `[[noreturn]]`.**

Every branch ends in a `[[noreturn]]` Ruby call but the C++ compiler
doesn't know that, leading to unreachable-return warnings (e.g. lines
290, 633, 816, 843 of `client.cpp` have `return Qnil` after calls
that never return). Adding the attribute fixes the warnings and
helps the optimizer.

**A8. `Pool#settings_sql` SQL-literal escape only handles `'`.**

Line 98 of `lib/clickhouse_native/pool.rb`:
`"'#{v.to_s.gsub("'", "''")}'"`. Doesn't escape backslashes, which
CH parses in single-quoted literals. Low practical risk because
settings values are typically constants, but worth fixing.

**A9. Decode path tags `Enum8`/`Enum16` as Ruby symbols via `rb_intern2`.**

Symbols are immortal in Ruby; if a user's CH enum has a large value
space and they query enough distinct values, the symbol table grows
unboundedly. Probably fine for typical CH enums (small fixed sets),
but worth a release note. Could offer a kwarg to opt for strings.

### Architectural concerns (separate from correctness)

- **One 1,159-line C++ file** (`client.cpp`). Reviewing diffs in this
  file is harder than it should be. Should split into `errors.cc`,
  `codec_decode.cc`, `codec_encode.cc`, `client.cc`. Same code,
  better organization. Mechanical refactor.
- **`value_at` and `append_value` are giant `switch` statements**
  indexed by `Type::Code`. Adding a new CH type means editing two
  switches plus possibly `append_default`. A registry-based dispatch
  (function-pointer table indexed by type code) is more maintainable
  and is the basis for a Ruby-side TypeMap extension point.
- **No Ruby-side TypeMap.** Compare to `pg`'s TypeMap, which lets
  users register custom encoders/decoders in Ruby for their own
  types. With clickhouse-native today, every type must be C++.

## See also

- `boundary_risks.md` — the failure-mode taxonomy that informed which
  patterns to look for in this audit.
- `ci_sanitizers.md` — the AddressSanitizer + UBSan setup for
  catching the kinds of bugs that human review can miss.
- `ext/clickhouse_native/patches/` — the running tally of fixes
  applied to vendored code.
