# Architecture: the data lane

Decided 2026-10-04. Sources:
[`docs/research/NEXT_PRISMA_DRIZZLE.md`](../research/NEXT_PRISMA_DRIZZLE.md),
[`docs/research/N_PLUS_ONE.md`](../research/N_PLUS_ONE.md), and the R5 research
result in [#20](https://github.com/kofun-lang/kofun-boot/issues/20). The
canonical shapes are in `modules/schema/contract/schema.kofun` and
`modules/loader/contract/loader.kofun`; the executable evidence is in the same
two bounded contexts' `core/`, `shell/`, and `tests/` directories.

## The decision in one paragraph

The schema is a Kofun value, as in Drizzle. Each column is addressed by a
**key** that is not its name, as in a protobuf field number. A migration is a
value too, and `apply : Schema -> Migration -> SchemaStep` is pure. A history
is therefore a fold. That fold is the shadow database, and drift is a
comparison of two values. SQL is a projection of those values, committed and
gated the way Prisma commits its migration SQL.

Queries are values the core returns inside a `Cmd`. Nothing loads behind a
field read. The interpreter coalesces each round of fetches before running
any of them: one statement per source, each key sent once. Nested reads are
declared shapes, compiled to a statement count fixed at build time. The
statements a request costs are measured at several sizes of the same data,
and a count that grows with N fails the gate.

## Identity is a key, not a name

Every schema differ that compares by name has to guess. When a column
disappears and another appears, the change is either a rename or a drop and
an add. A tool that compares names cannot tell which:

- Prisma Migrate emits the drop and the add, and warns about data loss.
- drizzle-kit asks the developer interactively.

Neither answer is available to a CI job. And either way, a wrong guess
destroys a column's data.

protobuf settled this long ago. A field is identified by its number, a rename
is free, and a deleted number is `reserved` so it is never reissued. The
schema module adopts that rule directly
([ADR 8](../adr/0008-a-column-is-its-key.md)):

| change | what the declaration says | what the planner emits |
|---|---|---|
| rename | same key, new label | `RenameColumn(key, label)` |
| drop | the key is declared retired | `DropColumn(key, NoPolicy)`, which `apply` refuses until a person writes `Discard` |
| add | a new key | `AddColumn(key, ...)`, refused if the key was ever retired |
| re-add an old name | a new key with the old label | `AddColumn`; the name was never the identity |

The planner never pairs two different keys, so a rename is never emitted as a
drop and an add. The gate checks this against the real history. Asked to get
from the schema before each committed step to the schema after it, the
planner must propose the same step at the same key.

The cost is that a developer chooses a key when adding a column, the way a
protobuf author chooses a field number. The declaration carries the retired
keys forever. The schema gate treats forgetting one as drift, naming the key.

## A history is a fold

`schema_replay(history)` returns the schema the history produces, from
nothing. Prisma computes that by replaying the migrations into a shadow
database: a second server, started to compute a value. Here it is a function
call that runs at build time on both backends
([ADR 9](../adr/0009-a-migration-history-is-a-fold.md)).

Three consequences follow, and the gate holds each one:

- **Drift is a value.** `drift(declared, replayed)` returns either
  `InSync(live)` or `Diverged(key)`. On failure the gate also prints the step
  the planner would write to close the drift.
- **A refused step is not skipped.** A history containing a step that `apply`
  refuses describes no database. The replay reports the step number and the
  outcome instead of folding around it.
- **Every prefix is an earlier database.** `replay(4)` is the schema between
  step 4 and step 5. A test can ask what a column was called before the
  rename without restoring a backup.

## Data loss is a decision

Some steps destroy data or fail on existing rows. Those steps are refused
unless they name the policy that makes them safe, and a policy satisfies only
the step that asks for it:

| step | refused as | needs |
|---|---|---|
| drop a column | `Destructive(key)` | `Discard` |
| add a NOT NULL column to an existing table | `NeedsBackfill(key)` | `Backfill(expression)` |
| tighten a nullable column | `NeedsBackfill(key)` | `Backfill(expression)` |
| drop or relax the primary key | `PrimaryKey(key)` | not allowed |

The planner never supplies a policy. That makes `prisma migrate dev`'s data
loss prompt and drizzle-kit's interactive question unnecessary: the planned
step is refused, by name, until a person writes the policy into the
committed history, where a reviewer reads it.

The order of the checks is part of the contract, the way the router's "size
before route before method" is:

> table → key range → key state → primary key → name → policy

## SQL is a projection

`scripts/ddl.sh` reads the sections the schema binary printed and writes two
files:

- `contracts/schema.sql`: the declared schema as DDL
- `contracts/migrations.sql`: one statement per committed step

It follows the OpenAPI projection's rule
([ADR 4](../adr/0004-projections-read-the-table-the-dispatcher-printed.md)):
SQL generated from what the binary printed cannot describe a column the core
does not hold or a step the core refused. Every code must resolve to a name,
and an unknown code is refused before any SQL is printed.

`tests/schema/postgres.sh` checks both files against a real PostgreSQL
cluster. A throwaway cluster gets two databases: one built step by step from
the migration SQL, one built from the declared DDL in a single statement.
Their schema-only dumps must be byte-identical. The same check then removes
one `NOT NULL` from the declared DDL and requires the dumps to differ. CI
sets `SCHEMA_REQUIRE_POSTGRES=1`, so a runner without PostgreSQL fails rather
than skips.

## Queries: no lazy field, one round, measured

The N+1 problem has two causes ([`N_PLUS_ONE.md`](../research/N_PLUS_ONE.md)):

- lazy loading behind property access;
- sequencing that the data does not need.

kofun-boot removes both by construction rather than by a strict mode
([ADR 10](../adr/0010-a-round-is-a-value.md)):

- **There is no lazy field.** The core cannot perform I/O. A row is a record,
  and reading a field reads a field. There is nothing for Rails
  `strict_loading`, SQLAlchemy `raiseload`, or Django `FETCH_RAISE` to forbid.
- **A round is a value.** The core asks for everything it can ask for now in
  one `Cmd`. The interpreter sees the whole round before running it, so
  coalescing is a pure function of the round:

  ```
  coalesce : Round -> Batch    # one statement per source; each key once
  ```

  This is Haxl's batching without an Applicative instance. It is also
  DataLoader's contract without the event-loop tick that decides what a batch
  is. Because the batch depends only on the round, it is as deterministic as
  everything else in the trace.
- **Rounds are bounded by dependency depth.** A fetch that needs an earlier
  answer waits for its `Msg`, which costs a round. A fetch that does not need
  one goes in the current round. Mapping over the rows an update was handed
  produces one round, so the natural code is the batched code.
- **Nested reads are declared shapes.** A shape is compiled at build time.
  Where the dialect supports it, it becomes one `LATERAL` + `json_agg`
  statement, as in Drizzle's relational queries, Prisma's
  `relationLoadStrategy: "join"`, Hasura, and PostgREST. Otherwise it becomes
  one `IN` statement per level. Sibling collections can be split per relation
  to avoid the cartesian explosion that EF Core and Hibernate warn about.
  A missing dialect feature is a build error, not a silent fallback.
- **N+1 is a measurement.** The trace records every round. The loader gate
  runs the same request at N = 1, 2, 3 and 4, and refuses a shipped strategy
  whose statement count moves. It names the counts, for example
  `N+1: ... costs 2 3 4 5 statements`. The sequential strategy is kept in the
  output on purpose, so the detector is shown to fire on every run.

Prisma 8's ADR 003 rejects automatic batching because it brings in
non-determinism. The objection is right about tick-based loaders and does not
apply here. A round's batch is computed from the round value alone, so
kofun-boot keeps both: declared shapes compile to one statement, and dynamic
rounds coalesce.

## The capability, the transaction, and the trace

These are designed, not yet executable. Each is filed as an issue, linked
below.

- **The database is a capability.** Its manifest row names a scope: which
  database, which role, read or write. The core receives query results as
  `Msg` values and never a connection.
- **A transaction is a scoped capability.** It cannot escape the function it
  was handed to. The trace records `begin`, each statement, its rows (redacted
  by declared policy), and `commit` or `rollback`. Replaying from the trace
  needs no database. Data steps inside a migration are [#53](https://github.com/kofun-lang/kofun-boot/issues/53).
- **The database carries its digest.** Prisma 8's `db sign` writes a contract
  hash into a marker table. kofun-boot will write the schema digest the
  history replays to. The binary prints its declared digest in the capability
  manifest and refuses to start against a different one ([#51](https://github.com/kofun-lang/kofun-boot/issues/51)).
- **Seed data is deterministic.** drizzle-seed generates data from a seed
  number. The mock already allocates ids from the value, so seeds are
  digest-pinned and a trace names the seed it was recorded against.
- **No table is an endpoint by default.** A read model reaches HTTP only
  through an explicit export in the route table. That is the Hasura/PostgREST
  idea with the default inverted.

## What is executable today, and what is not

| claim | executable | where |
|---|---|---|
| key identity, retired keys, declared renames | yes, one table of four keys | `modules/schema` |
| history as a fold, drift without a database | yes | `modules/schema`, `tests/schema/check.sh` |
| planner by key, no policy supplied | yes, one step per key per pass | same |
| DDL and migration SQL as gated projections | yes, PostgreSQL | `scripts/ddl.sh`, `contracts/*.sql` |
| both SQL projections build the same database | yes, PostgreSQL 16 | `tests/schema/postgres.sh` |
| round coalescing, N-independent statements | yes, one request in three strategies | `modules/loader`, `tests/loader/check.sh` |
| multiple tables, foreign keys | no | [#47](https://github.com/kofun-lang/kofun-boot/issues/47) |
| kind changes | no | [#48](https://github.com/kofun-lang/kofun-boot/issues/48) |
| typed query values, row codecs, result types from selections | no; blocked on List/Text lowering ([#7](https://github.com/kofun-lang/kofun-boot/issues/7)) | [#50](https://github.com/kofun-lang/kofun-boot/issues/50) |
| `LATERAL` shape compilation, per-relation split | no | [#49](https://github.com/kofun-lang/kofun-boot/issues/49) |
| database capability, transactions, digest marker | no | [#51](https://github.com/kofun-lang/kofun-boot/issues/51) |
| released history is append-only | no | [#52](https://github.com/kofun-lang/kofun-boot/issues/52) |

The two executable modules follow the pattern of the router and the mock. The
canonical contract is ahead of the compiler. The executable seed uses fixed
slots and integer codes and makes the same decisions. A gate compares the
closed outcome sums of the two exactly.
