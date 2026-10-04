# 12. Configuration is resolved before anything runs, and every value names its source

Date: 2026-10-04

## Status

Accepted.

## Context

Spring Boot's advantage is not its container. It is three things:

- a dependency selects useful configuration;
- the application can replace any default;
- the conditions report explains what applied and why.

The mechanism is classpath scanning, conditions evaluated against ambient
state, and reflection. kofun-boot has no reflection, and its core cannot read
ambient state, so it cannot copy the mechanism. It can still take the three
properties.

Two failure modes come with configuration that is assembled implicitly:

- **Load order.** When two auto-configurations set the same property, the
  winner depends on ordering that nobody wrote down.
- **Invisible defaults.** When a value was never set, nothing in the running
  application says where it came from.

## Decision

- **A starter is a pure pack.** It is a function from a field to the value
  it sets. There is no classpath to scan. What a pack does is what its source
  says.
- **One base pack sets every field.** So a resolved record has no hole.
- **Precedence is fixed.** An override from the application's `boot.conf`
  beats a starter pack, and a starter pack beats the base pack's default.
- **Two starters that set one field to different values are refused.** The
  refusal names the field and both packs. Two starters that agree are not a
  conflict.
- **Resolution comes first.** `BootInput` resolves to a complete
  `ResolvedBoot`, or to a refusal (`ConfigCheck`), before anything else in a
  boot runs. A refused input prints why and exits 1, and no record is printed.
- **Every field carries its source and a reason.** The reason is the pack that
  set it, or the `boot.conf` line that overrode it. `boot explain` prints every
  field, defaults included.
- **Configuration text is read at build time, once.**
  `scripts/boot-config.sh` compiles `boot.conf` into a `BootInput` value. It
  is the only place names are checked: an unknown key or pack is refused with
  the nearest real name. The binary reads no file and no environment, so the
  resolved record is the same under `env -i`.

## Consequences

`modules/config` is the executable seed. It has one `http_minimal` base pack
with five fields, three starter packs, and up to three overrides.
`tests/config/check.sh` checks the following:

- Ten probe inputs get the verdict each was written for.
- One override changes exactly one line of `boot explain`.
- An override beats the pack that set the same field.
- `contracts/boot.explain` is the projection of the resolved record.
- A configuration with two disagreeing packs stops before any record is
  printed, and names both packs.

The following are not done yet:

- An environment input that is explicitly declared. It needs a capability
  for it, and nothing reads the environment today.
- `boot doctor`.
- The serve lane's guarantee that no socket opens before resolution
  succeeds, which waits on
  [#2](https://github.com/kofun-lang/kofun-boot/issues/2).

All three remain under
[#17](https://github.com/kofun-lang/kofun-boot/issues/17).

The cost is that changing configuration means a rebuild, because `boot.conf`
is compiled into the binary. That is deliberate for this slice: configuration
that cannot change under a running binary cannot drift from what
`boot explain` printed for it. Runtime input will come as a declared
capability, never as an ambient lookup inside a pack.
