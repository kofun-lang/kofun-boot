# Research dossiers

These documents are the survey work behind the lanes in
[`docs/ROADMAP.md`](../ROADMAP.md). They exist because "kofun-boot should be
the best application framework" is not a design — it is a wish until somebody
writes down what the incumbents actually do, which of their decisions are
forced and which are accidents, and which of them Kofun can afford.

## Method, and its limits

Each dossier follows the same rules, which are the repository's rules applied
to prose:

1. **A claim about another project names its source.** Every framework
   assertion carries a link. Where a number appears it is somebody's published
   measurement, attributed, and marked as *theirs* — not ours.
2. **Third-party numbers are never our bars.** A benchmark run on somebody
   else's box, with somebody else's handler, tells us the shape of a
   difference and nothing about ours. The bar table in `docs/ROADMAP.md` stays
   empty until our own gate fills it. A comparison we did not run is a
   hypothesis.
3. **The interesting output is a decision, not a summary.** Each dossier ends
   in *What kofun-boot takes* and *What kofun-boot refuses*, with the reason.
   A survey with no refusals did not look hard enough.
4. **Surveys decay.** Every dossier is stamped with the date it was written.
   The frameworks below ship on their own schedules; a statement about
   somebody's pre-alpha is true for about a quarter.

## The dossiers

| document | question it answers | tracker |
|---|---|---|
| [`WEB_FRAMEWORKS.md`](WEB_FRAMEWORKS.md) | What do the best server frameworks get right, and what is the one declaration everything should derive from? | [R1 #16](https://github.com/kofun-lang/kofun-boot/issues/16) |
| [`SPRING_FASTAPI_GIN.md`](SPRING_FASTAPI_GIN.md) | Spring Boot 4.1, FastAPI, Ginの強みをどのように一つのKofun frameworkへ適応するか? | [R1 #16](https://github.com/kofun-lang/kofun-boot/issues/16) |
| [`MODULAR_MONOLITH_DDD.md`](MODULAR_MONOLITH_DDD.md) | modular monolithとDDD戦術パターンの何をadopt/adapt/rejectするか? | [#36](https://github.com/kofun-lang/kofun-boot/issues/36), [L12 #27](https://github.com/kofun-lang/kofun-boot/issues/27) |
| [`DESKTOP_FRAMEWORKS.md`](DESKTOP_FRAMEWORKS.md) | What does a desktop app actually cost, and which costs are the webview's fault? | [R7 #22](https://github.com/kofun-lang/kofun-boot/issues/22), [L9 #9](https://github.com/kofun-lang/kofun-boot/issues/9) |
| [`RENDER_BACKENDS.md`](RENDER_BACKENDS.md) | Can a webview be replaced by something native and faster — and what does that really require? | [R10 #28](https://github.com/kofun-lang/kofun-boot/issues/28) |
| [`EFFECT_SYSTEMS.md`](EFFECT_SYSTEMS.md) | How do languages that take effects seriously actually handle them, and which of those designs survives a language without higher-kinded types? | [R3 #18](https://github.com/kofun-lang/kofun-boot/issues/18), [L11 #26](https://github.com/kofun-lang/kofun-boot/issues/26) |
| [`NEXT_PRISMA_DRIZZLE.md`](NEXT_PRISMA_DRIZZLE.md) | Next.js 16・Prisma 7/8・Drizzle・Spring Boot 4 の何を採り、どこで真実を推測に委ねているか? | [L7 #7](https://github.com/kofun-lang/kofun-boot/issues/7), [#45](https://github.com/kofun-lang/kofun-boot/issues/45), [#54](https://github.com/kofun-lang/kofun-boot/issues/54), [#56](https://github.com/kofun-lang/kofun-boot/issues/56) |
| [`N_PLUS_ONE.md`](N_PLUS_ONE.md) | N+1 を起こさずに快適に書くには? ORM・query compiler・DataLoader・Haxl/FP の全手法と kofun-boot の決定 | [#46](https://github.com/kofun-lang/kofun-boot/issues/46), [#49](https://github.com/kofun-lang/kofun-boot/issues/49), [#50](https://github.com/kofun-lang/kofun-boot/issues/50) |

The architecture decisions these dossiers produced live one directory up, in
[`docs/architecture/`](../architecture/).

## Relationship to the R-series tracker issues

[R0 #15](https://github.com/kofun-lang/kofun-boot/issues/15) is the research
*programme*: it defines the cohorts, the seven comparison axes, and the bar
that a research issue does not close because somebody read an article. These
documents are the written output of that programme, and they are deliberately
narrower than it — four questions answered in depth rather than nine cohorts
surveyed at breadth.

Where a dossier reaches the same conclusion as an R-series issue, that is
convergence and it is recorded as such rather than restated: `EFFECT_SYSTEMS`
and R3 both land on *capabilities plus input to a closed result, not a monad
stack*, arrived at from different evidence. Where a dossier **disagrees** with
a filed decision, it says so and the disagreement is filed as a
`needs-decision` issue rather than settled in prose —
[#28](https://github.com/kofun-lang/kofun-boot/issues/28) is the one such case.

## Research pack

[`PACKAGE.md`](PACKAGE.md) defines the packaged reading order, verification,
and boundary statement. `scripts/build-research-pack.sh` creates a deterministic
ZIP; `tests/research/check.sh` builds it twice, including once under `env -i`,
and compares the bytes.

## Stamp

The series was written on 2026-08-02. `NEXT_PRISMA_DRIZZLE.md` and
`N_PLUS_ONE.md` were added on 2026-10-04 and are not yet in the research pack
([#58](https://github.com/kofun-lang/kofun-boot/issues/58)). Each dossier owns its source and version
stamp; the generated pack owns a content manifest instead of claiming one Git
commit for independently refreshed documents.
