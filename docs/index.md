---
title: kofun-boot
---

# kofun-boot

Application framework for the [Kofun](https://github.com/kofun-lang/kofun)
language.

An application is a pure function from its capabilities to its behaviour.
kofun-boot is the shell that wires, serves, replays, and measures it.

- [Install](#install)
- [Usage](#usage)
- [Writing an application](#writing-an-application)
- [Reference](#reference)

## Install

Requires `git`, a POSIX shell, and a C11 compiler. No package manager or
runtime must be installed first.

```sh
git clone --recurse-submodules https://github.com/kofun-lang/kofun-boot
cd kofun-boot
sh scripts/dev.sh
```

If you cloned without `--recurse-submodules`:

```sh
git submodule update --init vendor/kofun
```

## Usage

### Start a project

```sh
sh scripts/new.sh ../my-app --name my-app
cd ../my-app
sh tests/check.sh
```

The generated project already has the module boundary and its own gate.

### The development loop

| command | what it does |
|---|---|
| `sh scripts/dev.sh` | unit suite, build, golden check |
| `sh scripts/dev.sh --test` | the unit suite alone |
| `sh scripts/dev.sh --watch` | re-run on every save |
| `sh scripts/dev.sh --serve` | a real server on a real socket |
| `sh scripts/dev.sh --check` | exactly what CI runs, in CI's order |

### Generating artifacts

| command | what it produces |
|---|---|
| `sh scripts/dev.sh --openapi` | OpenAPI projected from the route table |
| `sh scripts/dev.sh --client` | typed TypeScript client projected from the route table |
| `sh scripts/dev.sh --schema` | DDL and migration SQL projected from the schema |
| `sh scripts/dev.sh --caches` | declared caches as manifest rows |
| `sh scripts/dev.sh --replay` | recorded session-trace replay |
| `sh scripts/dev.sh --research` | deterministic research ZIP and SHA-256 |

Both the document and client are read from the table the router prints, so
neither can describe a route the dispatcher does not serve.

### Schema and migrations

The schema is a value in `modules/schema/core/`. Columns are addressed by key,
so a rename keeps its key and a dropped key is retired for good. The migration
history is a list of values. Its replay must equal the declaration, or the
gate names the key that drifted and the step that would close it.

```sh
sh scripts/dev.sh --schema          # contracts/schema.sql and contracts/migrations.sql
sh tests/schema/check.sh            # drift, planner, refusals, projections
sh tests/schema/postgres.sh         # both SQL files build the same PostgreSQL database
```

A drop is refused until the history names `Discard`, and tightening a column
is refused until it names a backfill. The planner never supplies either.

### N+1

`tests/loader/check.sh` runs one request at N = 1 to 4. It refuses the shipped
strategy if its statement count changes with N.

### Caches

A cache is declared on a read endpoint with a key, a lifetime, and tags. The
key must be exactly the handler's arguments, and a cache that never expires
needs every tag dropped by some write.

```sh
sh scripts/dev.sh --caches          # contracts/caches.txt
sh tests/cache/check.sh             # the build-time check, the replayed session, break tests
```

### Record and replay

```sh
sh scripts/trace.sh record
sh scripts/trace.sh replay contracts/session.trace
```

The effect trace works the same way and pins the SHA-256 of its contract:

```sh
sh scripts/effects-trace.sh record modules/effects/tests/effects.trace
sh scripts/effects-trace.sh replay modules/effects/tests/effects.trace
```

## Writing an application

Every bounded context owns its complete vertical:

```text
modules/<name>/
  contract/    canonical public surface
  core/        pure functions
  shell/       capability construction and output
  tests/       unit suite and recorded golden
```

One module may name only another module's `contract/`. The architecture gate
discovers modules from the filesystem and rejects references to another
module's `core/`, `shell/`, or `tests/`.

The core receives capabilities and never constructs them. The shell is the
only place that builds the capability record and the only place that prints.

## Reference

### Design

- [Design](DESIGN.md)
- [Roadmap](ROADMAP.md)
- [Backlog](BACKLOG.md)
- [Releasing](RELEASING.md)

### Architecture

- [Functional core, imperative shell + DDD](architecture/FDDD.md)
- [The Elm Architecture](architecture/TEA.md)
- [Effects](architecture/EFFECTS.md)
- [Data](architecture/DATA.md)
- [Blueprint — the whole design, layer by layer](architecture/BLUEPRINT.md)

### Decisions

- [ADR 1 — Record architecture decisions](adr/0001-record-architecture-decisions.md)
- [ADR 2 — Enforce boundaries by gate](adr/0002-enforce-boundaries-by-gate-not-by-named-test.md)
- [ADR 3 — Mutations return a new state](adr/0003-mutations-return-a-new-state.md)
- [ADR 4 — Projections read the dispatcher table](adr/0004-projections-read-the-table-the-dispatcher-printed.md)
- [ADR 5 — A trace is the core's fold](adr/0005-a-trace-is-the-fold-the-core-already-performs.md)
- [ADR 6 — A module owns its whole vertical](adr/0006-a-module-owns-its-whole-vertical.md)
- [ADR 7 — A full resource is a conflict](adr/0007-a-full-resource-is-a-conflict-not-a-storage-failure.md)
- [ADR 8 — A column is its key](adr/0008-a-column-is-its-key.md)
- [ADR 9 — A migration history is a fold](adr/0009-a-migration-history-is-a-fold.md)
- [ADR 10 — A round of fetches is a value](adr/0010-a-round-is-a-value.md)
- [ADR 11 — A cache key is the handler's arguments](adr/0011-a-cache-key-is-the-arguments.md)

### Research

- [Overview](research/README.md) · [The package](research/PACKAGE.md)
- [Web frameworks](research/WEB_FRAMEWORKS.md)
- [Spring, FastAPI, Gin](research/SPRING_FASTAPI_GIN.md)
- [Modular monolith and DDD](research/MODULAR_MONOLITH_DDD.md)
- [Effect systems](research/EFFECT_SYSTEMS.md)
- [Desktop frameworks](research/DESKTOP_FRAMEWORKS.md)
- [Render backends](research/RENDER_BACKENDS.md)
- [Next.js, Prisma, Drizzle](research/NEXT_PRISMA_DRIZZLE.md)
- [N+1](research/N_PLUS_ONE.md)

---

Source: [github.com/kofun-lang/kofun-boot](https://github.com/kofun-lang/kofun-boot)
