# Releasing

A release is the one artifact a stranger reads before they read anything else.
This repository's rule everywhere else is that a claim needs a gate; a release
is the largest claim it makes, so it gets the strictest one.

## The problem this document solves

`README.md` carries a pillar table, and two of its bars say *unmeasured*. A
release is where that becomes dangerous: a version number on a framework whose
README says *"the ambition is Spring Boot's"* will be read as a maturity
claim, whatever the notes say.

The naive rule — *refuse to release while any bar is unmeasured* — is
unworkable, because it means no release ever ships until the desktop lane is
done, and that lane is blocked on the language. The rule that actually holds
the line is different:

> **A release may ship with unmeasured bars. It may not ship without saying
> exactly which ones.** The set of unmeasured bars in the README and the set
> declared in the release notes must be identical, and the gate compares them.

Silence is the failure mode, not incompleteness.

## Version scheme

Semantic versioning, with maturity attached to the major and minor:

| version | what it asserts | the gate's rule |
|---|---|---|
| `0.0.x` | research preview: dossiers and decisions; anything executable is incidental | unmeasured bars allowed, must be declared |
| `0.x.0` | working slices: every pillar the README says **holds today** has a green gate in CI | unmeasured bars allowed, must be declared; every *holds today* claim must name a gate that exists |
| `1.0.0` | production: every bar in the pillar table carries a measured number | **any unmeasured bar fails the release** |

`1.0.0` is therefore not a schedule decision — it is the point where L5 and L9
have filled their rows. Nothing can talk the project into it early, because
the gate reads the README rather than a person's judgement.

## The single source of each fact

Three facts, one home each, and the gate fails if any two disagree:

| fact | lives in | read by |
|---|---|---|
| the version | `VERSION` | the tag, the CHANGELOG heading, the gate |
| what changed | `CHANGELOG.md` | the release notes |
| which bars are unmeasured | `README.md`'s pillar table | the gate, which requires CHANGELOG to match |

The README is the source of truth for measurement status, not the CHANGELOG.
That direction matters: the pillar table is the thing a reader actually sees,
so it is the thing that must not be able to drift into optimism while a
release note quietly tells the truth somewhere else.

## Cutting a release

```sh
sh scripts/dev.sh --release          # verify only; prints what would be tagged
sh scripts/dev.sh --check            # the full CI suite
```

Then, once both are green:

1. `VERSION` holds the new version, and `CHANGELOG.md` has its section, dated,
   with an `### Unmeasured at this release` list matching the README.
2. `sh scripts/migrations-lock.sh release $(cat VERSION)` locks every
   migration step not yet released, and the updated `contracts/migrations.lock`
   is committed with the release. From then on those steps are append-only.
3. Merge to `main`.
4. Tag the merge commit: `git tag -a v$(cat VERSION) -m "..."`, and push it.
5. Publish the GitHub Release from that tag, with the CHANGELOG section as the
   body and the research pack attached.

Step 5 is the only step that reaches outside the repository, and it is
deliberately last and manual. Everything before it is reversible.

## What the gate checks

`tests/release/check.sh`, run by `scripts/dev.sh --release` and by CI:

1. `VERSION` is a syntactically valid semver.
2. `CHANGELOG.md` has a section for exactly that version, and it is dated.
3. The section declares `### Unmeasured at this release`.
4. **The declared set equals the README's unmeasured set** — a bar missing from
   either side fails, naming the bar and the side it is missing from.
5. If the major version is `>= 1`, the unmeasured set must be empty.
6. Every pillar the README claims **holds today** names a gate script that
   exists in the tree — a claim whose gate was deleted is a claim with nothing
   behind it.
7. The tag that would be created does not already exist.
8. **No released migration step has changed.** Each line of
   `contracts/migrations.lock` pins a released step's executable SQL by digest.
   A changed or removed step fails, naming the step and the version that
   released it. Rewording a comment in the projection is not a change, and
   unreleased steps are listed rather than refused.

And, as everywhere else here, the gate is verified in both directions: it
proves it fails when a bar is dropped from the CHANGELOG, when a bar is added
that the README does not have, and when the version is bumped to `1.0.0` while
a bar is still unmeasured.

For the migration lock, the demonstration runs on every gate run, in a
scratch copy. It locks the whole history, and then shows three things:

- editing one statement fails, naming the step;
- dropping the last step fails, naming the step;
- rewording a comment passes.

## What a release is not

- **Not a claim that blocked lanes have landed.** L6 and L9 are blocked on the
  language; a release says nothing about them beyond what the pillar table says.
- **Not a promise of API stability below `1.0.0`.** `0.x` minors may break the
  contract surface; the CHANGELOG says when they do.
- **Not a benchmark.** No number appears in a release note that did not come
  from a gate that measured it, on a named box, with its method.
