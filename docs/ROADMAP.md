# Roadmap: lanes → epics → bounded children

The unit of work is a bounded child: one reviewable change, one gate, one
honest boundary statement — the granularity the Kofun repository runs at.
Lanes decompose into epics, epics into children; at production scale this
tracker is expected to pass four digits of issues, and the structure below is
what keeps that navigable rather than aspirational.

Every lane names what it is blocked on. A lane blocked on a language
capability tracks the Kofun issue and does not ship a workaround we would
have to break.

| # | lane | first epics | blocked on |
|---|---|---|---|
| [L0 #10](https://github.com/kofun-lang/kofun-boot/issues/10) | governance & evidence | issue metadata discipline; release claims + evidence pack (kofun's `release/claims.json` pattern); benchmark result provenance | — |
| [L1 #1](https://github.com/kofun-lang/kofun-boot/issues/1) | contract | route/table ADTs; validation sums; OpenAPI projection; **multi-language client generation (swagger-codegen's reach)**; drift gates between all four | — |
| [L2 #2](https://github.com/kofun-lang/kofun-boot/issues/2) | serve | dispatch-table → `framework/http` registry; config surface (bind, limits, drain) as one printed record; TLS via capability | callback C ABI (kofun #574 lane) for arbitrary handlers |
| [L3 #3](https://github.com/kofun-lang/kofun-boot/issues/3) | capabilities | clock/net/bytes/db wiring records; FCIS gate (code-only grep) over `core/`; fake-capability kit re-exported for app tests | — |
| [L4 #4](https://github.com/kofun-lang/kofun-boot/issues/4) | replay | trace format v1 (versioned, digest-pinned like tzdb fixtures); record mode; replay mode; hostile-environment gate | — |
| [L5 #5](https://github.com/kofun-lang/kofun-boot/issues/5) | speed | benchmark gate on `benchmarks/http` harness; recorded baselines; regression = failure; published same-box comparisons vs Elysia/Gin/Hono | — |
| [L6 #6](https://github.com/kofun-lang/kofun-boot/issues/6) | concurrency | scoped spawn/join surface; cancellation as typed result; deterministic schedule replay | kofun #898 RFC, #736 |
| [L7 #7](https://github.com/kofun-lang/kofun-boot/issues/7) | data | schema-as-contract (drizzle direction) — **executable for one table: key identity, migrations as a fold, drift without a database ([#45](https://github.com/kofun-lang/kofun-boot/issues/45))**; **N+1 as a measurement ([#46](https://github.com/kofun-lang/kofun-boot/issues/46))**; API derived from schema (Hasura's move); typed queries; PostgREST interop | typed queries and row codecs only: List/Text lowering maturity (kofun #919 lane) |
| [L8 #8](https://github.com/kofun-lang/kofun-boot/issues/8) | cli & dx | `boot new/dev/test/bench/openapi/gen`; **`boot mock` — json-server's convenience, replayable**; scaffolds that compile with the core/shell split; watch-reload | — |
| [L9 #9](https://github.com/kofun-lang/kofun-boot/issues/9) | desktop | webview shell (KB-scale, gated size); wasm32 guest via host ABI v1; typed IPC = the router contract; **UI quality as a discipline, not a default (taste-skill)** | kofun #906 activation lanes |
| [L10 #11](https://github.com/kofun-lang/kofun-boot/issues/11) | site & docs | tutorial that never lies (every snippet is a gated fixture); comparison pages that show their measurement | — |
| [L11 #26](https://github.com/kofun-lang/kofun-boot/issues/26) | effects & TEA | `Cmd`/`Sub` as inert data; the interpreter surface; `Result` and railway combinators; the TEA runtime; one core under every shell; effect-row migration | effect rows (kofun type-system target) for L11's final epic only |
| [L12 #27](https://github.com/kofun-lang/kofun-boot/issues/27) | domain kit | constrained types and smart constructors; deriver/outcome discipline; the outcome lint; bounded-context layout; outbox; secret types | visibility slice maturity for constructor privacy |

L11 and L12 come from the research dossiers in
[`docs/research/`](research/) and the decisions in
[`docs/architecture/`](architecture/). They are the identity lanes: L11 is
*how an application asks for something to happen*, and L12 is *how it says
what it means*. Everything else in this table is a way of running them.

## Sequencing

```
now ──► L1 contract + L3 capabilities + L4 replay      (pure, unblocked, the identity of the framework)
     ──► L11 Cmd/Sub + TEA runtime                       (pure data and one interpreter; unblocked)
     ──► L2 serve v1 + L5 first baselines               (framework/http exists; numbers start accruing)
     ──► L12 domain kit + L8 cli                         (once `boot new` output compiles under the gate)
later ─► L6, L7, L9 as their language capabilities land
```

L11 sits beside L1 rather than after it because the two meet: an endpoint
value is what a request means, and a `Cmd` is what a handler asks for. Getting
them wrong in different shapes is how frameworks end up with two dependency
stories.

## The bars, restated as numbers to be filled in

| bar | measured by | current value |
|---|---|---|
| dispatch overhead vs hand-written matcher | L5 gate | *(unmeasured — no number may appear here before the gate exists)* |
| req/s vs Elysia, same box, same handler | L5 published run | *(unmeasured)* |
| desktop binary size vs Tauri hello | L9 gate | *(unmeasured; kofun native ELF fixtures are KB-scale, which is the reason to believe the bar is reachable)* |
| replay determinism | L4 gate | seed already holds it: two runs, both backends, `env -i` — byte-identical |
| statements per request as N grows | L7 loader gate | seed: the shipped strategy costs 2 at N = 1, 2, 3, 4; the sequential control costs N + 1 and is refused |
| schema drift detected without a database | L7 schema gate | seed: a 7-step history replays to the declaration on both backends; both SQL projections build the same PostgreSQL 16 database |

## Filed and ready now

- [#12](https://github.com/kofun-lang/kofun-boot/issues/12) serve: build and smoke the vendored `framework/http` server on CI
- [#13](https://github.com/kofun-lang/kofun-boot/issues/13) contract: path captures in the seed, read by the gate
- [#14](https://github.com/kofun-lang/kofun-boot/issues/14) capabilities: the FCIS gate — core modules cannot name a capability
- [#31](https://github.com/kofun-lang/kofun-boot/issues/31) effects: the `Cmd`/`Sub` canonical contract, pinned at its boundary, with a seed that emits a trace
- [#33](https://github.com/kofun-lang/kofun-boot/issues/33) capabilities: the granted set as a printed, diffable manifest the gate reads from the binary
- [#29](https://github.com/kofun-lang/kofun-boot/issues/29) desktop: IME and accessibility are gates — no number is recorded before they pass
- [#30](https://github.com/kofun-lang/kofun-boot/issues/30) desktop: decompose the bar — two of the four webview costs are the language's win, not the renderer's

Filed 2026-10-04 from [`docs/architecture/BLUEPRINT.md`](architecture/BLUEPRINT.md):

- [#45](https://github.com/kofun-lang/kofun-boot/issues/45) data: the schema is a value — key identity, migrations as a fold, drift without a database *(landed with this design)*
- [#46](https://github.com/kofun-lang/kofun-boot/issues/46) data: N+1 as a measurement — a round is a value *(landed with this design)*
- [#47](https://github.com/kofun-lang/kofun-boot/issues/47) data: more than one table, and foreign keys that name a key
- [#48](https://github.com/kofun-lang/kofun-boot/issues/48) data: column kind changes — widening applies, narrowing needs Discard
- [#49](https://github.com/kofun-lang/kofun-boot/issues/49) data: declared shapes compile to a fixed number of statements
- [#51](https://github.com/kofun-lang/kofun-boot/issues/51) data/capabilities: the database carries its schema digest
- [#52](https://github.com/kofun-lang/kofun-boot/issues/52) data/governance: released migration history is append-only
- [#54](https://github.com/kofun-lang/kofun-boot/issues/54) capabilities: `Principal` — authorization is a value, never a layer
- [#55](https://github.com/kofun-lang/kofun-boot/issues/55) contract: wire codecs generated from closed sums
- [#56](https://github.com/kofun-lang/kofun-boot/issues/56) serve/effects: declared caches
- [#57](https://github.com/kofun-lang/kofun-boot/issues/57) cli: `boot db plan / check / sql`
- [#58](https://github.com/kofun-lang/kofun-boot/issues/58) research: the pack includes the 2026-10 dossiers

Blocked on a filed dependency, not on refinement:

- [#50](https://github.com/kofun-lang/kofun-boot/issues/50) data: typed query values and row codecs — blocked on List/Text lowering
- [#53](https://github.com/kofun-lang/kofun-boot/issues/53) data: data migrations and backfills as `Cmd` values — blocked on [#50](https://github.com/kofun-lang/kofun-boot/issues/50)

- [#32](https://github.com/kofun-lang/kofun-boot/issues/32) replay: the trace format is the `Cmd`/`Msg` sequence — blocked by [#31](https://github.com/kofun-lang/kofun-boot/issues/31)

## Waiting on a decision

- [#28](https://github.com/kofun-lang/kofun-boot/issues/28) **is the view a shared ADT, or platform-specific?** [R7 #22](https://github.com/kofun-lang/kofun-boot/issues/22) says platform-specific; the render-backend dossier argues that this decides whether L9's "lighter than Tauri" is a claim about a webview app or a native one — and that the decision is cheap now and expensive after the first renderer exists. Only the decision owner may resolve it.

## What we are learning from, and exactly what we take

Reading a reference implementation is only useful if the reading is specific.
Each row says what we take and — where it matters more — what we deliberately
do not.

| source | taken | left |
|---|---|---|
| [json-server](https://github.com/typicode/json-server) | zero-config REST from a seed; the whole developer feeling | in-place file mutation. Ours returns a new store, so a session is a fold and replays ([ADR 3](adr/0003-mutations-return-a-new-state.md)) |
| [modular-monolith-with-ddd](https://github.com/kgrzybek/modular-monolith-with-ddd) | the numbered ADR log; module = its own Application/Domain/Infrastructure/Tests; business rules as values; arch rules enforced mechanically | one test method per rule. Its own `LayersTests.cs` names Infrastructure and asserts Application, so Domain→Infrastructure was never checked — [ADR 2](adr/0002-enforce-boundaries-by-gate-not-by-named-test.md) explains why we print the offending line instead |
| [servant](https://github.com/haskell-servant/servant) / [FastAPI](https://github.com/fastapi/fastapi) / [Elysia](https://elysiajs.com/) | one declaration → routes, validation, docs, typed client; dispatch compiled rather than interpreted | type-level gymnastics for their own sake; ours stays monomorphic until measurement argues otherwise |
| [swagger-codegen](https://github.com/swagger-api/swagger-codegen) | generating clients for languages we do not own | generation as a separate tool with its own model. Ours is a projection of the same table the dispatcher runs, so drift is a build failure |
| [Hasura](https://github.com/hasura/graphql-engine) | the API derived from the schema rather than hand-written beside it | a running engine that owns your database. Ours generates, it does not sit in the path |
| [Spring Boot](https://github.com/spring-projects/spring-boot) | the ambition: the default way to build an application | the IoC container — a language without ambient authority does not have the problem it solves |
| [tonatona](https://github.com/tonatona-project/tonatona) | plugins as an environment record | the type-class machinery; plain records, plain arguments |
| [axum](https://github.com/tokio-rs/axum) / [Gin](https://github.com/gin-gonic/gin) / [Hono](https://github.com/honojs/hono) | composition over middleware onions; small fast cores | implicit extractor magic; every capability is visible in the signature |
| [Tauri](https://github.com/tauri-apps/tauri) | the system webview is already installed | the multi-megabyte binary; ours is a gated KB number |
| [taste-skill](https://github.com/Leonxlnx/taste-skill) | UI quality as an explicit discipline for generated interfaces | — |
| [Rails](https://github.com/rails/rails) | generators, conventions, the first-hour experience | convention that cannot be checked; every scaffold we emit is a tested fixture |
| [Next.js](https://github.com/vercel/next.js) | colocation; typed routes; a static shell with streamed holes | the filesystem as the route table, inferred cache keys, endpoints that look like calls, and authorization in middleware ([`BLUEPRINT.md`](architecture/BLUEPRINT.md) §1–3, §6) |
| [Prisma](https://github.com/prisma/orm) | one schema; generated migration SQL committed and reviewed; a contract digest in the database (Prisma 8) | renames guessed from names; a shadow database to compute what a history produces ([ADR 8](adr/0008-a-column-is-its-key.md), [ADR 9](adr/0009-a-migration-history-is-a-fold.md)) |
| [Drizzle](https://github.com/drizzle-team/drizzle-orm) | the schema in the host language; SQL a reader can predict; relational queries that are one statement; seeded data | interactive rename prompts; `push` without history |
| [Haxl](https://github.com/facebook/Haxl) / [DataLoader](https://github.com/graphql/dataloader) | independent fetches gathered into one round, each key once | the Applicative instance and the event-loop tick; a round is already a value here ([ADR 10](adr/0010-a-round-is-a-value.md)) |
| [protobuf](https://protobuf.dev/programming-guides/proto3/#reserved) | identity is a number; a deleted number is `reserved` | — |
