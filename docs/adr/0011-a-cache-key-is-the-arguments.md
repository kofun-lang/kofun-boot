# 11. A cache key is the handler's arguments

Date: 2026-10-04

## Status

Accepted.

## Context

Next.js changed what it caches by default three times:

- 14 cached `fetch` by default;
- 15 reversed that;
- 16 made caching opt-in with `"use cache"`, `cacheLife`, and `cacheTag`.

In 16, the compiler infers the cache key from what the cached function
reads. An inferred key is only as complete as the inference. One input the
compiler does not see, and two requests that differ in it share an entry. The
advisories published on 2026-09-30 include a cache shared across root param
values in nested `"use cache"` (GHSA-h694-7cp9-m8p3) and a Draft Mode leak
(GHSA-3w37-wq28-93x7). The sources are in
[`docs/research/NEXT_PRISMA_DRIZZLE.md`](../research/NEXT_PRISMA_DRIZZLE.md).

A kofun-boot read handler is a pure function. It cannot read a cookie, a
header, or a param it was not passed. So its arguments are all of its inputs,
and nothing needs to be inferred.

## Decision

A cache is declared on a read endpoint with a key, a lifetime, and tags. A
write `Cmd` declares the tags it invalidates. At build time, four rules are
checked, in this order:

1. **The key holds every argument the handler takes.** Otherwise the cache
   is refused as `KeyOmits(argument)`.
2. **The key holds nothing the handler does not take.** Otherwise the cache
   is refused as `KeyForeign(argument)`.
3. **A cache that never expires carries at least one tag.** Otherwise it is
   refused as `NeverRefreshed(read)`.
4. **Every tag on such a cache is invalidated by some declared write.**
   Otherwise it is refused as `Uninvalidated(tag)`.

A finite lifetime bounds how stale an entry can be, so rules 3 and 4 do not
apply to it.

The key is checked first. A stale answer is a bug; an answer served to the
wrong caller is an incident.

At run time one more rule holds: **read your writes.** A write this binary
performs never leaves an entry it changed to be served by this binary,
whatever the entry's lifetime. A tag can be scoped by an argument:
`thing(id)` names one row, and a write to row 3 drops only row 3's entries.

## Consequences

`modules/cache` is the executable seed. It has three read endpoints and two
writes, an in-memory adapter of four slots, and a recorded session of 23
calls. `tests/cache/check.sh` checks the following:

- Each read handler's parameters, read from the source, are the arguments its
  cache declares. A declared argument list edited to agree with a short key
  fails, naming the parameter. The slice has no reflection, so the gate reads
  the signature. The canonical contract derives the key from the parameters
  instead.
- Every declared cache passes the check, and five probes show each refusal.
- Every value the session served equals what the read returns with no cache.
  A stale entry and a leaked one fail the same way, naming the step.
- Two runs, on both backends and under `env -i`, print the same trace of
  hits, misses, expiries, and invalidations, byte for byte.

`contracts/caches.txt` prints each cache with its key, lifetime, and tags, so
an operator can read them. It also projects one HTTP rule from each
declaration:

- A key that holds the caller is `private`, because a shared cache would
  serve it to the next caller.
- A cache that never expires is `no-cache`. The server keeps it fresh by
  dropping it on writes, and nothing can drop a copy a client already holds.

The cost is that a developer declares tags and writes declare what they
invalidate. A forgotten invalidation is not always visible at build time:
when every tag is still covered by some write, the check passes. The session
trace is what catches it, so the session must call the read after the write.
The gate requires the session to exercise every event and to ask one row for
two callers with different answers, so that both checks have something to
see.

The cache module stands alone today. When composition lands
([#2](https://github.com/kofun-lang/kofun-boot/issues/2),
[#17](https://github.com/kofun-lang/kofun-boot/issues/17)), these rows join
the composition root's capability manifest, and a shared backend becomes a
capability like any other.
