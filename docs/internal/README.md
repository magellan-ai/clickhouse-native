# Internal working notes for `magellan-ai/clickhouse-native`

These are **fork-local working notes**, not maintainer docs. They
preload context for whoever picks the work up next — business
motivation, prioritization, in-flight thinking that doesn't
generalize to upstream or to other consumers of the gem.

For docs that *do* generalize — sanitizer CI setup, C-extension
safety patterns, audit findings — see one level up in `docs/`.

## Do not PR these to upstream

This tree must not be included in any PR to
`umbrellio/clickhouse-native`.

GitHub's web PR interface doesn't support per-path exclusion — a PR
is always "this branch vs. that branch," no `--exclude` toggle. So
the discipline is at branch construction, not PR creation: build the
PR branch off `upstream/master`, cherry-pick only the relevant
commits, and verify nothing under `docs/internal/` slipped in before
pushing.

```sh
# Branch from upstream's main (not from this fork's master).
git fetch upstream
git checkout -b upstream-feature-foo upstream/master

# Cherry-pick the commits you actually want to PR. Don't merge from
# fork/master — that drags in everything, including docs/internal/.
git cherry-pick <sha1> <sha2> ...

# Verify nothing under docs/internal/ came along:
git log --name-only HEAD ^upstream/master -- 'docs/internal/'
# Empty output = clean.

# Push to your fork, then open the PR via github.com:
#   base: umbrellio/clickhouse-native:master
#   compare: <your-fork>:upstream-feature-foo
git push origin upstream-feature-foo
```

The `:!docs/internal/` pathspec exclusion (e.g.,
`git diff master..HEAD -- ':!docs/internal/'`) is useful as an
inspection/verification tool — it shows you what a hypothetical
internal-free diff would look like. It's not a PR-construction tool;
GitHub doesn't apply pathspecs at PR time.

If upstream PRs become frequent, a pre-push hook or CI lint can
enforce the rule — neither exists yet because the convention plus
branch-from-upstream discipline has been sufficient.

## Contents

1. **[upstream_context.md](upstream_context.md)** — *why we are here*.
   The 5-minute EC2 idle-timeout problem that drives the need for a
   native-protocol Ruby ClickHouse driver, and why this gem is the
   right base.
2. **[roadmap.md](roadmap.md)** — priority-ordered list of contributions
   we want to land, with rationale for each.
