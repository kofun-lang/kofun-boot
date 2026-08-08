# Changelog

Every release records what changed and — required by
[`tests/release/check.sh`](tests/release/check.sh) — which pillar bars were
still unmeasured when it shipped. The unmeasured list must match
[`README.md`](README.md)'s pillar table exactly; the gate compares them and
fails on either kind of drift. See [`docs/RELEASING.md`](docs/RELEASING.md).

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with
the `Unmeasured at this release` section added as a local requirement.

## [Unreleased]

### Added

- **Path captures in the Stage 2 seed** ([#13](https://github.com/hjosugi/kofun-boot/issues/13)) —
  a route slot carries a capture flag, and a dispatch reports the segment the
  route captured. `GET /things/{id}` is the first capturing slot: it matches
  the family of paths sharing its base and reports `7` out of `104007`, so the
  capture is demonstrably not the path. The canonical surface has routed on
  segments and captured `:name` since the beginning; the seed routed on codes
  and captured nothing, and this closes that half of the gap.
- **A `Dispatch` record beside `RouteResult`** — a matched route now has two
  things to report and the slice allows one payload per constructor, so the
  capture travels in a record beside the sum, the way `EffectStep` does. The
  capture is printed for every outcome, including `0` for routes that capture
  nothing: a field that appears only when interesting cannot be read for
  absence.
- **A capturing route in both projections** — the OpenAPI document declares
  `/things/{id}`'s path parameter, and the TypeScript client emits it as a
  template literal type. `` client.get(`/things/${id}`) `` compiles;
  `client.get("/things/{id}")` does not, so the one call nobody can perform is
  not the only one that type-checks.

### Changed

- **The boot gate's named router assertions read the binary's output rather
  than the golden file.** Asserting against the golden only proved the golden
  said what it said — a changed rule was caught by `cmp` as "output differs"
  and named nothing. The golden comparison now runs last, after every named
  decision, which is what lets a broken rule fail by the name of the rule.

### Gates

- 40/40 module-owned tests pass across three suites.
- The capture rule has a break test: echoing the path instead of the segment
  is rejected by name. It is the failure worth testing for, because it still
  reports a capture, still varies with the request, and still replays
  identically.
- A capturing base that collides with a literal route code fails the gate;
  nothing else forbids it yet.

## [0.4.1] - 2026-08-07

The repository moved to the `kofun-lang` organization. Documentation links now
resolve there; nothing in the framework changed.

### Fixed

- **Links follow the move** — GitHub redirects repository URLs after a transfer
  but not GitHub Pages, so documentation links had to name the organization
  directly.

### Unmeasured at this release

- Speed — L5; the benchmark harness exists and refuses to produce a number it
  does not trust, but no baseline has been recorded.
- Desktop lighter than Tauri — L9; blocked on the language's wasm32 activation
  lanes, and gated behind IME and accessibility conformance before any number
  is recorded ([#29](https://github.com/kofun-lang/kofun-boot/issues/29)).

## [0.4.0] - 2026-08-02

Effect trace v1 now records the program's own `Cmd`/`Msg` values and replays
them into the pure core. It is not a live-server capture, scheduler, or trace
diff UI.

### Added

- **Canonical trace contract** —
  `modules/effects/contract/trace.kofun` versions the format, pins the SHA-256
  of `effects.kofun`, and makes digest refusal and replay divergence closed
  results.
- **Executable replay core** — `replay_initial` emits the initial command and
  `replay_after` consumes each recorded message to emit the next command. A
  corrupted message therefore changes a decision instead of being ignored.
- **Record/replay command** — `scripts/effects-trace.sh` writes the ten-step
  fixture and replays it on both the reference and C11 backends. Divergence
  reports step, fed `Msg`, expected `Cmd`, and emitted `Cmd`.
- **Updated research pack** — the deterministic ZIP includes the implemented
  trace-v1 evidence and has SHA-256
  `25c609ec468f888b13c4a6c9de911974dedc2a96c010ed203c4ac37098ce8980`.

### Gates

- 34/34 module-owned tests pass across three suites.
- Record output is byte-identical across two C11 runs, the reference backend,
  hostile time zone and locale, and `env -i`.
- A changed contract digest is refused before replay by a named diagnostic.
- A deliberately corrupted recorded message exits non-zero and names all four
  divergence fields; both destructive cases run in `tests/boot/check.sh`.

### Unmeasured at this release

- Speed — L5; the benchmark harness exists and refuses to produce a number it
  does not trust, but no baseline has been recorded.
- Desktop lighter than Tauri — L9; blocked on the language's wasm32 activation
  lanes, and gated behind IME and accessibility conformance before any number
  is recorded ([#29](https://github.com/kofun-lang/kofun-boot/issues/29)).

### Known boundaries

- Trace capture from a live server remains in L2; this release records the
  bounded effect run.
- There is no scheduler, TEA loop, trace-diff UX, live interpreter, or scoped
  spawn in this release.
- The canonical trace uses `Bytes`, `List`, and rich sums ahead of the compiler;
  the executable projection is the current fixed-rank integer slice.

## [0.3.0] - 2026-08-02

The effect boundary is now an executable bounded context rather than a design
document alone. This is a contract addition below 1.0.0; it does not add a
runtime, scheduler, live network interpreter, or unscoped spawn.

### Added

- **Canonical effect contract** — `modules/effects/contract/effects.kofun`
  declares `Cmd`, `Sub`, `Msg`, and total interpreter surfaces. Every effecting
  constructor carries its continuation, failure and timeout are messages, and
  `Custom` is retained for both command and subscription extension. Command
  and subscription interpreters have separate capability records, so their
  signatures state only dependencies their respective sums can use.
- **Stage 2 projection** — the executable core keeps the same decisions in the
  current one-`Int`-payload slice; the shell emits a 60-line Cmd/Msg trace for
  every effecting command and subscription constructor, plus empty and batch,
  including HTTP timeout.
- **Third bounded context** — `effects` owns contract, core, shell, tests, and
  golden evidence under the module layout established in 0.2.0.
- **Updated research pack** — the deterministic ZIP includes the implemented
  effect-boundary evidence and has SHA-256
  `1311cff238853cb6818294354a0d4e07aa41ccee3010be507a00b1986c851533`.

### Gates

- 31/31 module-owned tests pass across three suites.
- The rich effect contract remains pinned at its documented compiler boundary.
- The gate names a missing continuation, lost `Custom` openness, and a timeout
  path that fails to return the required message; all three destructive checks
  were observed to fail before publication.
- Reference and C11 backends agree byte-for-byte across two runs, hostile time
  zone and locale, and `env -i`; emitted C has no ambient clock, environment,
  file, or socket reach.

### Unmeasured at this release

- Speed — L5; the benchmark harness exists and refuses to produce a number it
  does not trust, but no baseline has been recorded.
- Desktop lighter than Tauri — L9; blocked on the language's wasm32 activation
  lanes, and gated behind IME and accessibility conformance before any number
  is recorded ([#29](https://github.com/kofun-lang/kofun-boot/issues/29)).

### Known boundaries

- The rich contract uses `List`, `Bytes`, and multi-payload constructors ahead
  of the compiler; the executable projection uses fixed-rank integer values.
- No live interpreter, TEA loop, scheduler, trace serialisation, or scoped
  spawn is claimed by this release. Trace v1 remains [#32](https://github.com/kofun-lang/kofun-boot/issues/32).

## [0.2.0] - 2026-08-02

Bounded contexts now own their complete vertical. This is a breaking path
change below 1.0.0: code and tests formerly under `seed/` moved into modules,
and the router's canonical contract moved with its owner.

### Changed

- **Module ownership** — `router` and `mock` now each own `contract/`, `core/`,
  `shell/`, and `tests/` under `modules/<name>/`. The generic build and test
  adapters discover that layout instead of carrying a registry of module
  names.
- **Canonical contract location** — the router surface moved from
  `contracts/boot.kofun` to `modules/router/contract/router.kofun`.
  `contracts/` now contains projected/public artifacts rather than another
  module's source of truth.
- **Research pack** — the modular-monolith/DDD dossier now records the
  implemented evidence, ADR 5 and ADR 6 are included, and the deterministic
  archive digest is
  `bd489900e1e526a6193a2af39a6173a24547a5c070d6cb62692bd03762583e8e`.

### Added

- **Contract-only dependency gate** — a data-driven architecture gate requires
  every module to own its four layers and lets one module name only another's
  public contract. Canonical, dotted, and relative path spellings are checked.
- **Gate tested both ways** — the architecture fixture adds a third `orders`
  module without editing the existing two, then injects
  `../../router/core/router` and requires a diagnostic with the offending
  source, line, and allowed contract target.
- **Closed business outcome contract** — `modules/mock/contract/mock.kofun`
  models domain refusal as `MockOutcome`. The boot gate compares all seven
  constructors with the executable seed and requires every case to carry what
  was observed.
- **ADR 6** — records why a bounded context owns contract, core, shell, and
  tests, and why the assembly adapters are temporary compiler seams rather
  than a second ownership model.

### Gates

- 22/22 module-owned core tests pass through the filesystem-discovered test
  adapter.
- A third module passes without changes to existing modules; an internal
  cross-module reference fails with source, line, and allowed target.
- The boot gate pins the rich/executable outcome sum, all router projections,
  trace replay, and hostile-environment determinism.
- The deterministic research ZIP, real-socket integration suite, generated
  scaffold, and release coherence gate all pass.

### Unmeasured at this release

- Speed — L5; the benchmark harness exists and refuses to produce a number it
  does not trust, but no baseline has been recorded.
- Desktop lighter than Tauri — L9; blocked on the language's wasm32 activation
  lanes, and gated behind IME and accessibility conformance before any number
  is recorded ([#29](https://github.com/kofun-lang/kofun-boot/issues/29)).

### Known boundaries

- The executable Kofun slice has no module imports yet. Build and test adapters
  concatenate module-owned files in a deterministic order; generated units do
  not enter the worktree.
- Contract-only imports are gated as source references today. The first native
  import implementation must retain the same break test.
- Outbox/Inbox, module-local database schemas, and event sourcing remain
  adopt/adapt/defer decisions, not claims of executable data-lane support.

## [0.1.0] - 2026-08-02

First tagged release. A working contract-first slice, a research corpus with
its sources pinned, and the gates that hold both.

### Added

- **Router** — a route table compiled at build time, dispatched with a
  comparison count independent of the request, so the same input can never
  take two paths. Failures are a closed sum carrying what was observed:
  `MethodNotAllowed` names the methods that would have worked,
  `PayloadTooLarge` names the limit. Dispatch order is size → route → method,
  so an oversized request cannot probe the route space by watching the
  refusal change.
- **Mock resource** — a full REST resource from a seed, mutating nothing.
  `apply : Store -> Operation -> StoreStep` returns the resource and what
  happened, and is the only way to obtain the next store, so a session is a
  fold. Ids come from a counter carried in the value: deterministic with no
  clock and no entropy.
- **Replay** — a recorded session replays step-for-step under `env -i`,
  refusing on the first divergence and naming the step. The trace needed no
  format design; it is the fold the core already performs
  ([ADR 5](docs/adr/0005-a-trace-is-the-fold-the-core-already-performs.md)).
- **Projections** — the OpenAPI document and the typed TypeScript client are
  both generated from the twelve lines the router itself printed, which the
  gate pins as the compiled table. An artifact cannot describe a route the
  dispatcher does not serve.
- **Scaffold** — `scripts/new.sh` emits a project that already has the
  core/shell boundary, and CI generates one, runs its gate, then breaks its
  core and requires that gate to refuse.
- **Research corpus** — source-linked, dated dossiers on web frameworks,
  desktop frameworks, render backends, effect systems, Spring Boot/FastAPI/Gin,
  and modular-monolith DDD, plus the architecture decisions they produced:
  inert `Cmd` effects, one update loop under three shells, and functional
  domain modelling.
- **Deterministic research pack** — a byte-reproducible ZIP with a SHA-256
  sidecar and an internal manifest, built twice including once under `env -i`
  with a hostile timezone and locale, and compared.
- **Release scaffolding** — `VERSION`, this file, `docs/RELEASING.md`, and
  `tests/release/check.sh`.

### Gates

- 22 unit tests across the router and mock cores, running in about a second
  with no server.
- The boot gate: boundary, canonical contract pinned at its compiler boundary,
  every dispatch decision read by name, projections, determinism on both
  backends under hostile `TZ`, locale, and `env -i`.
- A real server on a real socket: bind, path capture, JSON decode, 404,
  malformed input, keep-alive, SIGTERM drain.
- Every gate verified in both directions — added together with the
  demonstration that it fails.

### Unmeasured at this release

These bars carry no number, and this release makes no claim about them. Each
is blocked on the lane named beside it.

- Speed — L5; the benchmark harness exists and refuses to produce a number it
  does not trust, but no baseline has been recorded.
- Desktop lighter than Tauri — L9; blocked on the language's wasm32 activation
  lanes, and gated behind IME and accessibility conformance before any number
  is recorded ([#29](https://github.com/kofun-lang/kofun-boot/issues/29)).

### Known boundaries

- Structured concurrency is blocked on the language RFC and ships nothing.
- The `Cmd`/`Sub` effect surface is a decision
  ([`docs/architecture/EFFECTS.md`](docs/architecture/EFFECTS.md)) and a filed
  contract ([#31](https://github.com/kofun-lang/kofun-boot/issues/31)), not yet
  executable code.
- Whether the view is a shared ADT or platform-specific is an open decision
  ([#28](https://github.com/kofun-lang/kofun-boot/issues/28)) and determines the
  shape of the desktop lane.
- `0.x` makes no API stability promise. Minors may break the contract surface;
  this file will say so when they do.

[Unreleased]: https://github.com/kofun-lang/kofun-boot/compare/v0.4.0...HEAD
[0.4.1]: https://github.com/kofun-lang/kofun-boot/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kofun-lang/kofun-boot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/kofun-lang/kofun-boot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kofun-lang/kofun-boot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kofun-lang/kofun-boot/releases/tag/v0.1.0
