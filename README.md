# kofun-boot

Batteries-included application framework for the
[Kofun](https://github.com/kofun-lang/kofun) language.

The ambition is Spring Boot's: the de-facto way to build a production
application. The discipline is Kofun's: every claim is backed by a gate, every
dependency is a capability handed in by the caller, and a feature that cannot
be exercised deterministically does not ship.

## The one-sentence design

**An application is a pure function from its capabilities to its behaviour;
kofun-boot is the shell that wires, serves, replays, and measures it.**

Everything below follows from that sentence.

## Try it

```sh
git clone --recurse-submodules https://github.com/kofun-lang/kofun-boot
cd kofun-boot
sh scripts/dev.sh                      # 34 unit tests, a build, a golden check — about a second
sh scripts/new.sh ../my-app --name my-app   # a project that already has the boundary
cd ../my-app && sh tests/check.sh      # its own gate: boundary, suite, golden, determinism
```

| command | what |
|---|---|
| `sh scripts/dev.sh` | the inner loop: unit suite, build, golden check |
| `sh scripts/dev.sh --test` | the unit suite alone, the fastest useful loop |
| `sh scripts/dev.sh --watch` | re-run on every save |
| `sh scripts/dev.sh --serve` | a real server on a real socket |
| `sh scripts/dev.sh --openapi` | the document the route table projects |
| `sh scripts/dev.sh --research` | deterministic framework-research ZIP + SHA-256 |
| `sh scripts/dev.sh --client` | the typed client the route table projects |
| `sh scripts/dev.sh --scaffold` | generate a project and run its gate |
| `sh scripts/dev.sh --replay` | replay the recorded session trace |
| `sh scripts/dev.sh --release` | verify the release is coherent; tag nothing |
| `sh scripts/dev.sh --check` | exactly what CI runs, in CI's order |

The last row is the point: a green terminal and a green pipeline are the same
commands, so they cannot come to mean different things.

## What exists today, honestly

Kofun's Stage 2 core is deliberately small. kofun-boot follows the pattern the
language repository uses everywhere: a **canonical contract** ahead of the
compiler and pinned by a gate, beside a **bounded executable seed** that proves
the decisions on both backends, byte-for-byte.

### The router — contract-first dispatch

`modules/router/` owns its contract, core, shell, and tests. Its core compiles
a route table at build time and dispatches with a comparison count independent
of the request, so the same input can never take two paths. Failures are a
closed sum that carries what was observed:

```
GET  /hello   → Matched(handler 1)
GET  /sum     → MethodNotAllowed(allowed = POST)     ← names what would have worked
GET  /nope    → NotFound(path)
… body 4097   → PayloadTooLarge(limit = 4096)        ← names the limit
```

The dispatch order is the contract and the gate reads it: **size before route,
route before method**, so an oversized request cannot probe the route space by
watching the refusal change.

### The mock resource — json-server's five minutes, replayable

`modules/mock/` owns a second bounded context and gives a full REST resource
from a seed: list, show, create, update, delete. It edits nothing.
`apply : Store -> Operation -> StoreStep`
returns the resource *and* what happened, and there is no other way to obtain
the next store, so a session is a fold.

Three properties follow that a file-mutating mock cannot offer: the same seed
and the same requests **replay byte-identically**; a test can assert the
resource *between* two requests; and `POST` allocates from a counter carried
in the value, so ids are deterministic with **no clock and no entropy**.

Its domain answer is `MockOutcome`, a closed sum shared exactly between the
rich canonical contract and the executable seed. `Missing(id)` carries the id
that was absent and `Full(capacity)` carries the bound that was reached. These
are valid business refusals, not exceptions; adapter failures remain system
errors at the shell boundary.

### Modules — the bounded context owns its whole vertical

Every directory under `modules/` must own `contract/`, `core/`, `shell/`, and
`tests/`. The architecture gate discovers modules from the filesystem; adding
a bounded context does not require adding its name to a test. Another module
may name only `modules/<name>/contract` — a direct reference to its core,
shell, or tests fails with the offending source path and line.

`tests/architecture/check.sh` proves both directions on every run: it adds an
`orders` module without editing `router` or `mock`, then injects an import of
`router/core` and requires the gate to reject the exact line.

### Effects — the core asks by returning data

`modules/effects/` owns the canonical `Cmd` / `Sub` / `Msg` contract and its
bounded Stage 2 projection. Every effecting constructor carries the `MsgId` of
its continuation; HTTP success and timeout return different `Message`
values carrying that same id. Command and subscription interpreters receive
different capability records, so neither signature claims dependencies it
cannot use. `Custom` keeps both command and
subscription families extensible, while unscoped spawn stays absent until the
language can own its lifetime.

The executable trace covers an empty command, a batch, HTTP completion,
timeout, clock, persistence, custom command, tick, signal, and custom
subscription. Ten named assertions read all 60 lines.
Reference and C11 backends emit identical bytes twice, under a hostile time
zone and locale, and under `env -i`; emitted C is checked for ambient clock,
environment, file, and socket reach.

The structured effect trace is the same ten values, not a second log format:

```sh
sh scripts/effects-trace.sh record modules/effects/tests/effects.trace
sh scripts/effects-trace.sh replay modules/effects/tests/effects.trace
```

Its v1 header pins SHA-256 of the canonical effect contract. Replay feeds each
recorded `Msg` into the pure core and compares the next `Cmd`; a contract
digest mismatch is refused before step 1, while a divergence names the step,
fed `Msg`, expected `Cmd`, and emitted `Cmd`.

### Replay — a recorded session, run again

There was no trace format to design. `apply` already returns the resource and
what happened, so a session is a fold and a trace is the list of steps in it —
eight integers a reader can diff by eye.

```sh
sh scripts/trace.sh record            # write contracts/session.trace
sh scripts/trace.sh replay contracts/session.trace
```

Replay runs under `env -i` and refuses on the first divergence, naming the
step and printing both rows. Making `delete` rewind the id counter — the
json-server behaviour this design exists to avoid — produces:

```
trace: FAIL: the session diverged at step 5
  columns:  step op arg_id arg_value outcome payload live next_id
  recorded: 5 5 2 0 5 2 2 4
  replayed: 5 5 2 0 5 2 2 2
```

Caught where it happened, not as a mysterious id collision two steps later.
Editing the trace by hand is refused separately, by its digest.

### The capability manifest — what this binary can reach

The type already enforces: a function never handed a filesystem capability
cannot touch a filesystem, because it does not compile. That is stronger than
an ACL file, and it is still not a complete answer.

A capability set visible only by reading code is auditable by developers. One
that can be **printed and diffed** is auditable by an operator — and the person
answering "what can this reach?" during an incident is often not the person who
can read the composition root, and is never reading it for the binary actually
running. So the shell prints the effective set before anything else happens,
unconditionally:

```
kofun-boot capability manifest
contract
1
build
226362803
clock.monotonic
granted
1700000000000
...
net.listen
denied
net.connect
denied
fs
denied
end manifest
```

Three things make it worth printing rather than describing:

**Denied rows are printed.** A manifest listing only grants cannot be read for
what is *absent*, and absence is the property being checked.

**Grants carry scopes, not booleans.** A filesystem capability is not "the
filesystem" — it names its roots; a network capability names what it may reach.
Every field of `Capabilities` is a scope, and zero is how a field says the
binary was never handed that authority. A granted row without a scope fails the
gate.

**`build` is a digest of the capability declaration, not a revision.** A git
revision changes on every commit, so two manifests would differ whenever
anything had been committed between them. This changes exactly when the
capability surface changes, which is the question a deploy diff is asking.

The gate runs the binary and asserts named rows out of what it printed — never
by reading the source, because a source-derived manifest proves what the source
says and the question is what the artifact does. Dropping a row, granting
without a scope, and letting the build identity go stale each fail by name.

### The projections — one declaration, many artifacts

`scripts/openapi.sh` and `scripts/client-ts.sh` both read **the twenty lines the
router itself printed** after its capability manifest, which the gate pins as
the compiled table — four per slot, the fourth being whether the route
captures. Artifacts made from those bytes cannot describe a route the
dispatcher does not serve.

The typed client turns that into a compile error at the call site:

```ts
await client.get("/hello");   // fine
await client.get("/sum");     // TS2345: "/sum" is not assignable to GetPath
await client.get("/nope");    // TS2345: "/nope" is not assignable to GetPath
```

Editing either artifact by hand fails; a projection that drops a route fails on
the count; and widening a path type to `string` — which leaves the generated
file reading entirely correct — fails because a call the table forbids then
compiles.

## Testing, which is most of the reason to pick a framework

**Unit tests need no server.** kotest pairs module-owned tests with their
core, so tests call the core directly. Thirty-four of them run
in about a second. Assertions accumulate rather than abort, so a broken change
reports everything that is wrong at once instead of the first thing.

```
Tests  34 passed (34 total, 3 suites)
```

**Integration tests use a real socket.** `tests/integration/serve.sh` builds the
example server from the pinned checkout, waits for `READY <port>` rather than
sleeping, and asserts path capture, JSON decode, 404, 400-not-a-crash,
keep-alive across two requests, and SIGTERM drain — killing the process on
every exit path. Port 0 means parallel runs cannot collide.

**The scaffold is a tested fixture, not a template.** `tests/scaffold/check.sh`
generates a project on every CI run, runs *its* gate, and then breaks its core
and requires that gate to refuse. A scaffold verified only by having been
written once rots the first time the language moves — and rots in someone
else's afternoon rather than in this build.

**Every gate is verified in both directions.** A gate is added together with
the demonstration that it fails: making the body limit exclusive fails exactly
one named test; a handler that constructs its own clock fails with its line
number quoted; hand-editing the OpenAPI document fails with the diff.

## Pillars, each with a bar it must clear

| pillar | inherited from | the measurable bar |
|---|---|---|
| Contract-first APIs | servant, FastAPI, Elysia | routes, validation, OpenAPI, and the typed client derive from **one** declaration; drift is a build failure — **holds for the document and the TypeScript client today** |
| Capabilities, not containers | Spring DI, inverted | no container and no reflection; the core **may not construct** a capability, enforced by a gate that prints the offending line — and the effective set, with scopes and denials, is **printed by the binary at startup and read back by the gate today** |
| Functional core, imperative shell | FCIS, functional DDD | enforced by construction — **holds today** |
| Deterministic replay | Kofun's gate culture | identical bytes on both backends, twice, under a hostile `TZ`, locale, and `env -i`, **and a recorded session replays step-for-step — holds today** |
| Speed | Elysia, Gin, Hono | requests/sec published with its method — *unmeasured; no number appears here before the gate that measured it* |
| Structured concurrency | Go's ergonomics, without the leaks | scoped spawn/join, deterministic schedules — blocked on the language RFC, and says so |
| Desktop lighter than Tauri | Tauri, inverted | binary size and cold start as gated numbers — *unmeasured* |
| A CLI worth living in | Rails, Spring Initializr | `boot new / dev / test / bench / openapi / gen` — **`new`, `dev`, `test`, `openapi` and the client generator hold today** |

## Repository layout

| path | what |
|---|---|
| `modules/router/` | router bounded context: canonical contract, core, shell, unit suite, golden |
| `modules/mock/` | mock bounded context: canonical contract, core, shell, unit suite |
| `modules/effects/` | Cmd/Sub/Msg boundary and trace v1: canonical contracts, Stage 2 replay core, shell, fixtures, unit suite |
| `contracts/` | generated/projected public artifacts: OpenAPI, typed client, replay trace |
| `scripts/` | developer loop, module gate/test adapter, build and projection commands |
| `tests/architecture/` | data-driven module ownership and contract-only dependency gate, tested both ways |
| `tests/client/` | one call that must compile, two that must not |
| `tests/boot/check.sh` | contract/seed correspondence, dispatch decisions, projection, determinism |
| `tests/integration/serve.sh` | a real server on a real socket |
| `tests/scaffold/check.sh` | `boot new`'s output, generated and gated every run |
| `tests/release/check.sh` | the release gate: the declared unmeasured set must match the pillar table |
| `VERSION`, `CHANGELOG.md` | the version, and what each release changed and left unmeasured |
| `docs/RELEASING.md` | the version scheme and what the release gate refuses |
| `docs/adr/` | the numbered decision log — why, and what it cost |
| `docs/DESIGN.md`, `docs/ROADMAP.md` | the architecture; the lanes and what each is blocked on |
| `docs/BACKLOG.md` | the epic decomposition, issue shape, and labels |
| `docs/research/` | the source-linked, dated surveys behind the decisions |
| `docs/architecture/` | the resulting effect, update-loop, and domain-model decisions |
| `vendor/kofun` | the pinned language checkout |

## The three decisions worth arguing with

The research dossiers in [`docs/research/`](docs/research/) produced three
positions that shape everything else. Each links to the evidence.

**Effects are inert data, not a monad.**
[`docs/architecture/EFFECTS.md`](docs/architecture/EFFECTS.md) — the core
returns a `Cmd` describing what should happen; the shell interprets it holding
the capabilities. This needs a closed sum and a function, which is all Kofun
has today, and it is *why Elm is understandable* — the monad was never the
clear part. A recorded run then **is** the `Cmd`/`Msg` sequence, so replay
needs no instrumentation.

**One update loop, three shells.**
[`docs/architecture/TEA.md`](docs/architecture/TEA.md) — `init`, `update`,
`view`, `subscriptions`, all pure, interpreted by a server shell, a desktop
shell, or a server-driven shell. That the same core runs under all of them is
a gate, not a slogan.

**The view is an ADT, which is the only reason "replace the webview" is
schedulable.**
[`docs/research/RENDER_BACKENDS.md`](docs/research/RENDER_BACKENDS.md) — Tauri
cannot swap its renderer cheaply because its contract *is* the DOM, so a
replacement must reimplement the web platform; that is why the leading attempt
is still pre-alpha. If the view is a vocabulary we chose, a renderer is an
interpreter, and native becomes a second backend rather than a rewrite. The
same dossier records the finding that governs the desktop lane: **IME and
accessibility are gates, not features**. No performance number is recorded
until both pass under a gate.

## What we refuse

- **No reflection, ever.** Everything derived is derived at build time.
- **No middleware onion.** Cross-cutting behaviour is a function composed in
  the shell, visible in one place.
- **No unstated defaults.** Defaults exist, are few, and are printed.
- **No number without the gate that measured it.**
- **No feature without a gate**, and no gate merged without the demonstration
  that it fails.

## License

Apache-2.0 OR MIT, matching the language.
