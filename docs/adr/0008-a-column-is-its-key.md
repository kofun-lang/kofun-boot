# 8. A column is its key, not its name

Date: 2026-10-04

## Status

Accepted.

## Context

A schema differ that compares two schemas by column name has to guess when one
name disappears and another appears. It is either a rename or a drop and an
add, and the two differ by whether the column's data survives.

- Prisma Migrate emits the drop and the add and warns about data loss; the
  developer edits the generated SQL by hand to make it a rename.
- drizzle-kit asks interactively whether the column was renamed or created.

Neither works in CI, where there is no one to answer and no one to read a
warning. And a wrong guess either way corrupts data: a rename read as a drop
loses the column, and a drop-and-add read as a rename silently relabels
unrelated data.

The same problem was solved in a different field a long time ago. A protobuf
field is identified by its number, not its name. A rename is free and needs no
guess. A deleted field's number is declared `reserved` so that a later field
cannot be handed it and be read by old clients as the old field.

kofun-boot's mock already follows the second half of that rule for rows. A
deleted id is spent and never reissued ([ADR 3](0003-mutations-return-a-new-state.md)),
because two resources that share an id are indistinguishable in a replay.

## Decision

Every column has a **key**, an integer chosen when the column is added and
never changed. The name is a label.

- A rename is `RenameColumn(key, name)`: same key, new label. It is never
  inferred.
- A drop retires the key. The declaration lists retired keys, and an add at a
  retired key is refused as `KeyRetired(key)`.
- Names are unique among live columns only. A dropped column's name may be
  used again, at a new key.
- The planner decides by key and never pairs two different keys. A label
  change at one key is planned as a rename of that key.

## Consequences

The schema gate can now check something no name-based differ can. For each
committed step, the planner is asked to get from the schema before the step to
the schema after it, and it must propose the same step at the same key. A
planner that read a rename as a drop fails that check by naming the step
(`the planner did not regenerate history step 5`).

The cost is that a developer chooses a key when adding a column, and the
declaration carries retired keys forever. Forgetting a retired key is drift,
and the gate names the key. That is the same discipline protobuf asks for, and
for the same reason: identity that is reused is identity that lies.

Keys do not appear in SQL. The DDL projection prints them as comments
(`-- key 3`) and lists retired keys at the end. The database never needs them;
the declaration and the history do.
