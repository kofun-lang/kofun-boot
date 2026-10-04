# kofun-boot design

This document records the architecture and the reason for every load-bearing
decision. It is written before most of the code exists, in the style the Kofun
repository itself uses: contracts first, evidence gates beside them, and an
honest line between what executes today and what is specified ahead.

## 1. The shape of an application

```
            ┌────────────────────────────────────────────┐
            │              imperative shell              │
            │  boot.toml → capability wiring → runtime   │
            │  (clock, net, bytes, db, log — all values) │
            └───────────────┬────────────────────────────┘
                            │ capabilities passed as arguments
            ┌───────────────▼────────────────────────────┐
            │              functional core               │
            │   handlers: Request → RouteResult (pure)   │
            │   domain: ADTs, closed sums, no ambient    │
            └────────────────────────────────────────────┘
```

An application is a pure function from its capabilities to its behaviour. The
shell owns wiring, sockets, and the event loop; the core owns every decision.
The core cannot reach the shell, and that is not a convention — it is checked:

- **Language level.** Kofun has no ambient authority. There is no `now()`, no
  `File.open`, no global allocator; a clock is an affine handle, time-zone
  rules are injected bytes, the environment is a capability (Kofun #569, #573,
  #647, #878). A handler that wants the time must be *given* a clock.
- **Framework level.** The FCIS gate reads core modules with comments stripped
  and fails on any capability name. The same technique Kofun's tzdb gate uses,
  for the same reason: prose about not doing something must not satisfy a
  check about not doing it.

### Why not an IoC container

Spring's container solves object-graph assembly for a language with ambient
constructors and mutable state. Kofun has neither, so the problem the
container solves does not exist here. A dependency is a value; "injection" is
an argument; the "container" is the shell function that builds the capability
record once and hands it down. What Spring calls a bean definition, kofun-boot
calls a record field. What Spring calls a profile, kofun-boot calls passing a
different record. Test configuration is not a framework feature — it is the
fake clock and scripted network the stdlib already provides.

tonatona showed this shape in Haskell (plugins as an environment record);
kofun-boot adopts the shape and drops the type-class machinery: plain records,
plain functions, monomorphic until measurement says otherwise.

## 2. Contract-first routing

One declaration produces four artifacts:

```
route contract ──┬── static dispatch table (compiled, zero reflection)
                 ├── request validation (typed, closed error sum)
                 ├── OpenAPI document (projection, gated against drift)
                 └── typed client (Eden-style; drift is a build failure)
```

servant proved routes-as-types; FastAPI proved types-as-docs; Elysia proved
both can be fast if the framework compiles dispatch instead of interpreting
it. kofun-boot's dispatch is a **fixed comparison rank**: the route table is
data at build time, the matcher's comparison count is independent of the
input, and the same request can never take two paths. This is the same
technique Kofun's tzdb producer uses for transition lookup and its benchmark
producer uses for sorting — control flow independent of data is what makes
replay a proof rather than a hope.

Failures are a closed sum, never a status-code convention:

```
type RouteResult =
    | Matched(handler: HandlerId)
    | NotFound
    | MethodNotAllowed(allowed: MethodSet)
    | PayloadTooLarge(limit: Int)
```

`MethodNotAllowed` carries what *is* allowed; `PayloadTooLarge` carries the
limit. The Kofun rule: a constructor carries what was observed, and no path
defaults.

## 3. Serving

Kofun ships `framework/http`: an epoll HTTP/1.1 event loop in C with a
Kofun-facing API, integration-tested (startup, keep-alive, drain on SIGTERM)
and benchmarked (`benchmarks/http`, with recorded `results.json`). The serve
lane builds on it:

- v1: kofun-boot's compiled dispatch table registers into the framework/http
  route registry; the event loop stays C, the decisions stay Kofun.
- The current registry is callback-free (bounded handler kinds) because the C
  ABI slice has no arbitrary callbacks yet. The lane tracks Kofun's C ABI
  work; until then, handler kinds are generated from the contract rather than
  hand-numbered.
- Everything the parser refuses (transfer coding, oversized headers) is
  already a defined, tested behaviour of the runtime — kofun-boot inherits a
  parser with stated limits instead of writing an unstated one.

## 4. Deterministic replay as the test story

Because every effect is a value, a recorded run is a value too. The effect
trace is the sequence of `Cmd`s the core emitted and `Msg`s the shell fed
back, recorded once and replayed by feeding those messages into the same core.
That records decisions as well as answers, without instrumentation. The
gate discipline comes straight from Kofun's tzdb gate: run twice and `cmp`,
then run under `TZ=Pacific/Kiritimati`, a `tr_TR` locale, and `env -i`, and
`cmp` again. A framework whose tests pass only in the CI image's locale has an
ambient dependency it has not admitted.

## 5. Concurrency

Go made spawning cheap and easy — and made leaking a goroutine just as easy.
kofun-boot exposes only *scoped* spawn/join: a child cannot outlive its scope,
cancellation is a typed result (Kofun's waiter/cancellation precedent in the
clock adapters), and test schedules replay deterministically (Kofun #736
research; #898 RFC). This lane is **blocked on the language RFC** and says so;
nothing in it ships as "experimental" with leak semantics we would have to
break later.

## 6. Desktop

Tauri's insight is right: the webview is already installed, stop shipping
Chromium. Tauri still ships a multi-megabyte Rust binary. Kofun's native
images are measured in kilobytes (the native gate's ELF fixtures), and wasm32
host ABI v1 (Kofun #906) pins the guest/host contract. The desktop lane is a
thin system-webview shell whose IPC is the same typed contract the router
uses — the desktop app is the web app with a different shell, which is the
FCIS shape again. Bars: our binary in KB, cold start in ms, both gated.

## 7. The CLI

`boot new` scaffolds the two-layer shape so the first compile already has the
core/shell boundary. `boot dev` is watch-reload. `boot openapi` and
`boot gen client` are projections of the contract. `boot bench` runs the same
harness the benchmark gate runs, so a developer's number and CI's number are
the same number. Kofun's `framework/cli` (a real CLI framework with its own
gate) is the substrate.

## 8. What we refuse

- **No reflection, ever.** Everything derived is derived at build time.
- **No middleware onion.** Cross-cutting behaviour is a function composed in
  the shell, visible in one place. (Axum's tower shows composition can be
  principled; kofun-boot keeps the composition and drops the type gymnastics.)
- **No unstated defaults.** A resolver that "helpfully" picks an offset in a
  time-zone fold is the bug kofun's tzdb refuses; a framework that silently
  binds 0.0.0.0 is the same bug. Defaults exist, are few, and are printed.
- **No feature without a gate.** Inherited from the language, non-negotiable.

## 9. Data

The data lane follows the same shape as the router: a declaration, pure
decisions over it, and projections gated against drift. The schema is a
value. Each column is addressed by a key, not a name, so renames are
declared rather than guessed and dropped keys are never reissued. A
migration history is a fold over a pure `apply`, so the schema it produces
is computed at build time with no database. SQL is a projection of those
values, checked once against a real PostgreSQL.

Queries follow the effect model. The core cannot load anything behind a
field read, and it asks by returning a round of fetches as a value. The
interpreter coalesces that round to one statement per source. The statements
a request costs are measured at several sizes of the same data.

[`architecture/DATA.md`](architecture/DATA.md) holds the reasoning;
[`architecture/BLUEPRINT.md`](architecture/BLUEPRINT.md) places it in the
whole design.

## 10. Versioning and the road

kofun-boot tracks the pinned language revision in `vendor/kofun`; a language
capability landing (C ABI callbacks, structured concurrency, List/Text
lowering) unblocks the lane that names it. The roadmap (docs/ROADMAP.md) is
lanes → epics → bounded children, each child the size of one reviewable PR
with one gate — the granularity the Kofun repository already demonstrated
works at three-digit issue counts, and the only granularity that plausibly
scales to four.
