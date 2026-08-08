# 7. A full resource is a conflict, not a storage failure

Date: 2026-08-07

## Status

Accepted.

## Context

The mock resource's outcomes are a closed sum, and every one of them has to
reach HTTP as a status. Five of the seven are conventions nobody argues about:

| outcome | status |
|---|---|
| `Collection(live)` | 200 |
| `Item(value)` | 200 |
| `Created(id)` | 201 |
| `Updated(id)` | 200 |
| `Missing(id)` | 404 |

Two are decisions, and [#34](https://github.com/kofun-lang/kofun-boot/issues/34)
asked for them to be made and recorded rather than picked.

### `Full(capacity)` — 507 or 409

507 Insufficient Storage is the WebDAV status for "the server is unable to
store the representation needed to complete the request", and on the surface
that is what a resource at capacity is.

Three things argue against it.

**507 is 5xx.** The server is not malfunctioning. It is behaving exactly as
specified: the resource is bounded to four rows, the bound was reached, and it
said so while carrying the capacity it reached. Putting that in the server-error
class means correct behaviour pages an operator and shows up in error budgets,
which teaches everyone to ignore the class that is supposed to mean something
is broken.

**The client can fix it.** A caller who deletes a row can retry and succeed.
That is precisely what 409 Conflict describes — a conflict with the current
state of the target resource — and precisely what 507 does not: 507 says the
problem is on the server's side of the boundary and there is nothing the caller
can do. Telling a caller that when it is not true is a lie about whose problem
it is, and the caller's correct response to each is different.

**`Full` already carries the capacity.** The bound travels in the outcome, so a
409 response can name what the limit was. A status that carried the same
information less accurately would be a downgrade.

507 is also a WebDAV extension rather than a core HTTP status, which matters
less than the above but is not nothing for a framework that means to be
predictable.

### `Deleted(id)` — 200 or 204

`Deleted` carries the id, and 204 No Content discards it.

Keeping the id is not a reason to choose 200. The id exists in the outcome
because a freed id must stay spent — it is what the trace reads to prove that a
create after a delete never reissues it — and that proof lives in the domain
answer and in `contracts/session.trace`, not in the HTTP response. A successful
delete has nothing a caller needs in a body.

So 204, and the seam is recorded here rather than discovered later: this is the
one place where the domain answer carries something the protocol drops.

## Decision

`Full` maps to **409 Conflict**. `Deleted` maps to **204 No Content**.

No outcome maps into 5xx. A refusal is an answer — a domain rule declining a
request is not the server failing, and the status class says so. Transport and
storage failures are `Result.Err` at an adapter boundary and are not
`MockOutcome` at all, which is the distinction
[`modules/mock/contract/mock.kofun`](../../modules/mock/contract/mock.kofun)
already draws.

## Consequences

`mock_status` is a match over the closed sum, so **a constructor added to
`MockOutcome` without a status does not compile**. A new domain answer cannot
reach the wire as a default 200 or an accidental 500; it has to be decided,
here, first.

The status is recorded as the ninth column of the session trace, so the mapping
is replayed and compared byte-for-byte rather than asserted once. The trace
format moves to `kofun-boot.trace/v2` for that column.

`409` will look surprising to anyone reading it as "the disk is full". That is
the cost of the decision, and it is the right way round: the surprising-but-true
status is better than the unsurprising-but-wrong one, and this file is what a
reader finds when they go looking.

Binding these statuses to real HTTP responses waits on
[#2](https://github.com/kofun-lang/kofun-boot/issues/2), which owns handler
registration in the serve lane. The mapping is decided and gated ahead of it so
that work is wiring rather than deciding.
