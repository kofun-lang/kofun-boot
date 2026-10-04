# 10. A round of fetches is a value, and N+1 is measured against N

Date: 2026-10-04

## Status

Accepted.

## Context

The N+1 query problem has two causes
([`N_PLUS_ONE.md`](../research/N_PLUS_ONE.md)):

1. **Lazy loading behind property access.** `user.posts` reads like a field
   and issues a query.
2. **Sequencing that the data does not need.** A loop awaits one fetch per row
   although no fetch depends on another.

ORMs answer the first with eager-loading APIs and switches that forbid lazy
loads at runtime: Rails `strict_loading`, SQLAlchemy `raiseload`, Django 6.1
`FETCH_RAISE`, Laravel `preventLazyLoading`.

Functional libraries answer the second. Haxl, Fetch, ZIO Query, and Effect's
`Request` batch every fetch that applicative composition makes independent.

Detection is either a runtime profiler (Bullet, nplusone, Sentry) or a
test-time count for one fixture (Django `assertNumQueries`, Hibernate
statistics). A count pinned for a three-row fixture passes a per-row loader
for as long as the fixture stays small.

Prisma 8's ADR 003 takes a third position. One query is one statement, and
automatic batching is rejected because tick-based loaders make the batch
depend on scheduling.

## Decision

- The core cannot perform I/O, so **no field loads anything**. The lazy cause
  does not exist, and nothing needs to forbid it.
- The core asks by returning a `Cmd`. Every fetch it can ask for now is in one
  **round**, which is a value.
- The interpreter coalesces the round **before** running any of it:
  `coalesce : Round -> Batch`, one statement per source, each key sent once.
  The batch is a pure function of the round, so it is as deterministic as the
  rest of the trace. That answers Prisma 8's objection without giving up
  batching.
- Rounds are bounded by dependency depth. A fetch that needs an earlier
  answer costs a round, and a fetch that does not goes in the current one.
- Nested reads are declared shapes, compiled at build time to a fixed number
  of statements.
- **N+1 is measured against N.** The loader gate runs the same request at
  N = 1 to 4 and refuses a shipped strategy whose statement count moves,
  naming the counts. The sequential strategy stays in the output so the
  detector is shown to fire.

## Consequences

The natural way to write an update, mapping over the rows it was given and
asking for what each one needs, produces one round, and that round is one
statement per source. The only way to write N+1 is to wait for each answer
before asking for the next. That is legal and visible, and the gate fails it
by name.

The executable seed (`modules/loader`) shows this for one request in three
strategies:

| strategy | statements at N=1..4 |
|---|---|
| sequential | 2, 3, 4, 5 |
| one round | 2 at every N |
| declared shape | 1 at every N |

All three return the same answer. Three break tests show the gate failing:

- the application switched to the sequential strategy;
- the interpreter's coalescing removed;
- the duplicate-key removal dropped.

Declared shapes compile to SQL ([#49](https://github.com/kofun-lang/kofun-boot/issues/49)):
one `LEFT JOIN LATERAL` + `json_agg` statement for a join, and one statement
per level for a split. `tests/loader/postgres.sh` counts what clients sent
from PostgreSQL's own statement log, at N = 1..4 authors:

| run | statements |
|---|---|
| join | 1 1 1 1 |
| split | 2 2 2 2 |
| per-row control | 2 3 4 5 |

All three give identical answers.

What remains is filed as issues:

- typed query values, blocked on List/Text lowering: [#50](https://github.com/kofun-lang/kofun-boot/issues/50).
