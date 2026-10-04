#!/bin/sh
set -eu

# boot new — scaffold a project that already has the boundary.
#
# The scaffold's whole job is to make the first compile land on the right side
# of the core/shell line, because a project that starts without the boundary
# never grows one. What it emits is not a template that hopes to still be
# valid: `tests/scaffold/check.sh` generates a project, builds it, and runs its
# tests on every CI run, so a scaffold that has rotted fails this repository's
# build rather than someone else's afternoon.
#
# usage: scripts/new.sh DIRECTORY [--name NAME]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    printf 'boot new: %s\n' "$*" >&2
    exit 1
}

target=${1:-}
test -n "$target" || fail 'usage: scripts/new.sh DIRECTORY [--name NAME]'
shift

name=$(basename -- "$target")
while test "$#" -gt 0; do
    case $1 in
        --name)
            shift
            name=${1:-}
            test -n "$name" || fail '--name needs a value'
            ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

test ! -e "$target" || fail "$target already exists"

# The pinned language checkout. A scaffolded project must reach a toolchain,
# and reaching *this* one means the project it generates is reproducible for
# the same reason this repository is.
KOFUN_DIR=${KOFUN_DIR:-"$ROOT/vendor/kofun"}
test -d "$KOFUN_DIR" ||
    fail "no language checkout at $KOFUN_DIR; set KOFUN_DIR or run: git submodule update --init vendor/kofun"
KOFUN_ABS=$(CDPATH= cd -- "$KOFUN_DIR" && pwd)

mkdir -p "$target/core" "$target/shell" "$target/tests" \
    "$target/modules/schema/core" "$target/modules/schema/shell"

# ------------------------------------------------------------------ core

cat >"$target/core/core.kofun" <<'CORE'
# The functional core.
#
# Everything here is a pure function. This file may receive a capability as an
# argument and may not construct one, and it may not own an entry point —
# `tests/check.sh` reads it with comments stripped and fails on either. That
# is not a house style: it is what makes every function below testable without
# a server, a clock, or a network.

type Capabilities = {
    now_seconds: Int,
}

type Greeting = {
    audience: Int,
    at_seconds: Int,
}

# A closed result. Each case carries what was observed, so a caller never has
# to guess why: `TooLoud` says what the limit was, not merely that one exists.
type GreetResult =
    | Greeted(audience: Int)
    | Silent(reason: Int)
    | TooLoud(limit: Int)

fn audience_limit() -> Int {
    return 100
}

fn reason_empty() -> Int {
    return 1
}

fn greet_result_kind(result: GreetResult) -> Int {
    let mut kind = 0
    match result {
        Greeted(_) => { kind = 1 },
        Silent(_) => { kind = 2 },
        TooLoud(_) => { kind = 3 },
    }
    return kind
}

fn greet_result_payload(result: GreetResult) -> Int {
    let mut payload = 0
    match result {
        Greeted(audience) => { payload = audience },
        Silent(reason) => { payload = reason },
        TooLoud(limit) => { payload = limit },
    }
    return payload
}

# The one decision this application makes. Size is checked before anything
# else, the way the framework's own dispatcher checks it, so a caller cannot
# learn about the rest by sending something oversized.
#
# It takes no capability, because it needs none — and the compiler enforces
# that honesty: a parameter this function ignored would fail the build with
# `unused parameter`. A signature here is therefore a true statement about
# what the decision depends on, which is the property that makes the core
# worth testing on its own.
fn greet(audience: Int) -> GreetResult {
    if audience > audience_limit() {
        return TooLoud(audience_limit())
    }
    if audience == 0 {
        return Silent(reason_empty())
    }
    return Greeted(audience)
}

fn greeting_at(audience: Int, capabilities: Capabilities) -> Greeting {
    let value: Greeting = Greeting(
        audience: audience,
        at_seconds: capabilities.now_seconds
    )
    return value
}
CORE

# ----------------------------------------------------------------- shell

cat >"$target/shell/shell.kofun" <<'SHELL'
# The imperative shell.
#
# Everything the core is forbidden to name lives here, in one place a reader
# can hold: the capability record, and what gets printed. The core decides;
# this decides what the outside world sees.

fn main() -> Int {
    # The only clock this program has is the one written here. A test replaces
    # this line and the whole application becomes deterministic — there is no
    # ambient time for the core to reach instead.
    let clock: Capabilities = Capabilities(now_seconds: 1700000000)

    let welcomed: GreetResult = greet(3)
    print(greet_result_kind(welcomed))
    print(greet_result_payload(welcomed))

    let silent: GreetResult = greet(0)
    print(greet_result_kind(silent))
    print(greet_result_payload(silent))

    let loud: GreetResult = greet(101)
    print(greet_result_kind(loud))
    print(greet_result_payload(loud))

    let stamped: Greeting = greeting_at(3, clock)
    print(stamped.audience)
    print(stamped.at_seconds)
    return 0
}
SHELL

# ----------------------------------------------------------------- tests

cat >"$target/core/core_test.kofun" <<'TEST'
# Unit tests for the core. No server, no clock, no network — the core is pure,
# so its tests are arithmetic. kotest pairs this file with `core.kofun`
# automatically, by name.
#
# A test returns its failed-assertion count, so 0 is a pass. Assertions
# accumulate with `+` rather than aborting, so a broken change reports
# everything that is wrong at once.

fn test_a_normal_audience_is_greeted() -> Int {
    let result: GreetResult = greet(3)
    let mut failures = 0
    failures = failures + expect_eq_int(greet_result_kind(result), 1)
    failures = failures + expect_eq_int(greet_result_payload(result), 3)
    return failures
}

fn test_an_empty_audience_is_silent_and_says_why() -> Int {
    let result: GreetResult = greet(0)
    let mut failures = 0
    failures = failures + expect_eq_int(greet_result_kind(result), 2)
    failures = failures + expect_eq_int(greet_result_payload(result), reason_empty())
    return failures
}

# The refusal carries the limit, so a caller learns the bound rather than
# being told "no".
fn test_an_oversized_audience_names_the_limit() -> Int {
    let result: GreetResult = greet(101)
    let mut failures = 0
    failures = failures + expect_eq_int(greet_result_kind(result), 3)
    failures = failures + expect_eq_int(greet_result_payload(result), audience_limit())
    return failures
}

# Half-open at the top: the limit itself is inside the limit. An off-by-one
# here refuses a caller the contract accepts.
fn test_the_limit_itself_is_accepted() -> Int {
    let at_limit: GreetResult = greet(100)
    let over: GreetResult = greet(101)
    let mut failures = 0
    failures = failures + expect_eq_int(greet_result_kind(at_limit), 1)
    failures = failures + expect_eq_int(greet_result_kind(over), 3)
    return failures
}

# The core is a function of its capabilities: the same input and the same
# record give the same answer, and the only thing that moves the timestamp is
# the injected clock. This is what makes a recorded run replayable.
fn test_the_core_is_a_function_of_its_capability() -> Int {
    let early: Capabilities = Capabilities(now_seconds: 42)
    let late: Capabilities = Capabilities(now_seconds: 43)
    let a: Greeting = greeting_at(3, early)
    let b: Greeting = greeting_at(3, early)
    let c: Greeting = greeting_at(3, late)
    let mut failures = 0
    failures = failures + expect_eq_int(a.at_seconds, b.at_seconds)
    failures = failures + expect_ne_int(a.at_seconds, c.at_seconds)
    failures = failures + expect_eq_int(c.at_seconds - a.at_seconds, 1)
    return failures
}

# Every input produces one of the three cases, including inputs the surface
# never emits. A decision with an undefined case is a decision that will one
# day be made by accident.
fn test_greet_is_total() -> Int {
    let mut failures = 0
    failures = failures + expect_between_int(greet_result_kind(greet(0)), 1, 3)
    failures = failures + expect_between_int(greet_result_kind(greet(1)), 1, 3)
    failures = failures + expect_between_int(greet_result_kind(greet(0 - 5)), 1, 3)
    failures = failures + expect_between_int(greet_result_kind(greet(999999)), 1, 3)
    return failures
}
TEST

# ---------------------------------------------------------------- schema
#
# The project owns a schema from its first commit: one table, a one-step
# history, and `db.sh`, the project's `boot db check` and `boot db sql`. The
# core is the framework's schema engine cut to one table. The language slice
# has no module imports and refuses a function nobody calls, so a project
# cannot link the framework's two-table engine and owns the part it uses.

cat >"$target/modules/schema/core/schema.kofun" <<'SCHEMA_CORE'
# The schema core: one table, declared by key, and the history that builds it.
#
# A column is identified by its key, never by its name. A rename keeps the
# key, so it is never guessed. A drop retires the key for good. The history
# is a list of migration values, and replaying it through `apply` must give
# back the declaration exactly. `sh db.sh check` reads that from the built
# binary and names the key where they disagree.
#
# This is kofun-boot's schema engine cut down to one table. The language
# slice has no module imports and refuses a function nobody calls, so a
# project owns the part of the engine it uses.
#
# To change the schema, edit `declared()` and append the step that gets the
# history there to `history_step()`. `sh db.sh check` says which key differs
# and what the planner proposes. It never supplies a policy: a drop needs
# `policy_discard()`, and a NOT NULL column added to a table needs
# `policy_backfilled()`, written by a person.

# ------------------------------------------------------------- constants

fn capacity() -> Int {
    return 4
}

fn slot_empty() -> Int {
    return 0
}

fn slot_live() -> Int {
    return 1
}

fn slot_retired() -> Int {
    return 2
}

fn kind_bigint() -> Int {
    return 1
}

fn policy_none() -> Int {
    return 0
}

fn policy_discard() -> Int {
    return 1
}

fn policy_backfilled() -> Int {
    return 2
}

fn step_create_table() -> Int {
    return 1
}

fn step_add_column() -> Int {
    return 2
}

fn step_rename_column() -> Int {
    return 3
}

fn step_drop_column() -> Int {
    return 4
}

# Column names and kinds are codes, because a record cannot hold Text in this
# slice. db.sh maps each code to its SQL name and refuses one it cannot name.
# Add a code here when a column needs it: label_title() returning 2, or
# kind_text() returning 2. The slice refuses a function nobody calls, so a
# code arrives with the column that uses it.
fn label_id() -> Int {
    return 1
}

# ---------------------------------------------------------------- values

type Schema = {
    exists: Int,
    primary: Int,
    c1_label: Int,
    c1_kind: Int,
    c1_nullable: Int,
    c1_state: Int,
    c2_label: Int,
    c2_kind: Int,
    c2_nullable: Int,
    c2_state: Int,
    c3_label: Int,
    c3_kind: Int,
    c3_nullable: Int,
    c3_state: Int,
    c4_label: Int,
    c4_kind: Int,
    c4_nullable: Int,
    c4_state: Int,
}

type Migration = {
    kind: Int,
    key: Int,
    label: Int,
    column_kind: Int,
    nullable: Int,
    policy: Int,
}

# Every refusal names what it found.
type SchemaOutcome =
    | TableCreated(key: Int)
    | ColumnAdded(key: Int)
    | ColumnRenamed(key: Int)
    | ColumnDropped(key: Int)
    | TableExists(primary: Int)
    | NoTable(key: Int)
    | KeyLive(key: Int)
    | KeyRetired(key: Int)
    | KeyUnknown(key: Int)
    | NameTaken(label: Int)
    | PrimaryKey(key: Int)
    | Destructive(key: Int)
    | NeedsBackfill(key: Int)
    | Full(capacity: Int)

type Drift =
    | InSync(live: Int)
    | Diverged(key: Int)

# ------------------------------------------------------------ accessors

fn eq(left: Int, right: Int) -> Int {
    if left == right {
        return 1
    }
    return 0
}

fn label_at(schema: Schema, key: Int) -> Int {
    if key == 1 {
        return schema.c1_label
    }
    if key == 2 {
        return schema.c2_label
    }
    if key == 3 {
        return schema.c3_label
    }
    return schema.c4_label
}

fn kind_at(schema: Schema, key: Int) -> Int {
    if key == 1 {
        return schema.c1_kind
    }
    if key == 2 {
        return schema.c2_kind
    }
    if key == 3 {
        return schema.c3_kind
    }
    return schema.c4_kind
}

fn nullable_at(schema: Schema, key: Int) -> Int {
    if key == 1 {
        return schema.c1_nullable
    }
    if key == 2 {
        return schema.c2_nullable
    }
    if key == 3 {
        return schema.c3_nullable
    }
    return schema.c4_nullable
}

fn state_at(schema: Schema, key: Int) -> Int {
    if key == 1 {
        return schema.c1_state
    }
    if key == 2 {
        return schema.c2_state
    }
    if key == 3 {
        return schema.c3_state
    }
    return schema.c4_state
}

fn live_count(schema: Schema) -> Int {
    return eq(schema.c1_state, slot_live()) + eq(schema.c2_state, slot_live())
        + eq(schema.c3_state, slot_live()) + eq(schema.c4_state, slot_live())
}

# How many live columns carry this name. Names are unique among live columns
# only: a dropped column's name may come back, at a new key.
fn label_holders(schema: Schema, label: Int) -> Int {
    return eq(schema.c1_state, slot_live()) * eq(schema.c1_label, label)
        + eq(schema.c2_state, slot_live()) * eq(schema.c2_label, label)
        + eq(schema.c3_state, slot_live()) * eq(schema.c3_label, label)
        + eq(schema.c4_state, slot_live()) * eq(schema.c4_label, label)
}

fn migration(kind: Int, key: Int, label: Int, column_kind: Int, nullable: Int, policy: Int) -> Migration {
    let step: Migration = Migration(
        kind: kind,
        key: key,
        label: label,
        column_kind: column_kind,
        nullable: nullable,
        policy: policy
    )
    return step
}

fn empty_schema() -> Schema {
    let schema: Schema = Schema(
        exists: 0, primary: 0,
        c1_label: 0, c1_kind: 0, c1_nullable: 0, c1_state: slot_empty(),
        c2_label: 0, c2_kind: 0, c2_nullable: 0, c2_state: slot_empty(),
        c3_label: 0, c3_kind: 0, c3_nullable: 0, c3_state: slot_empty(),
        c4_label: 0, c4_kind: 0, c4_nullable: 0, c4_state: slot_empty()
    )
    return schema
}

# The schema with one column replaced. `exists` and `primary` come from the
# caller, because creating the table sets them.
fn with_column(
    schema: Schema,
    primary: Int,
    key: Int,
    label: Int,
    kind: Int,
    nullable: Int,
    state: Int
) -> Schema {
    let k1: Int = eq(key, 1)
    let k2: Int = eq(key, 2)
    let k3: Int = eq(key, 3)
    let k4: Int = eq(key, 4)
    let written: Schema = Schema(
        exists: 1,
        primary: primary,
        c1_label: schema.c1_label + k1 * (label - schema.c1_label),
        c1_kind: schema.c1_kind + k1 * (kind - schema.c1_kind),
        c1_nullable: schema.c1_nullable + k1 * (nullable - schema.c1_nullable),
        c1_state: schema.c1_state + k1 * (state - schema.c1_state),
        c2_label: schema.c2_label + k2 * (label - schema.c2_label),
        c2_kind: schema.c2_kind + k2 * (kind - schema.c2_kind),
        c2_nullable: schema.c2_nullable + k2 * (nullable - schema.c2_nullable),
        c2_state: schema.c2_state + k2 * (state - schema.c2_state),
        c3_label: schema.c3_label + k3 * (label - schema.c3_label),
        c3_kind: schema.c3_kind + k3 * (kind - schema.c3_kind),
        c3_nullable: schema.c3_nullable + k3 * (nullable - schema.c3_nullable),
        c3_state: schema.c3_state + k3 * (state - schema.c3_state),
        c4_label: schema.c4_label + k4 * (label - schema.c4_label),
        c4_kind: schema.c4_kind + k4 * (kind - schema.c4_kind),
        c4_nullable: schema.c4_nullable + k4 * (nullable - schema.c4_nullable),
        c4_state: schema.c4_state + k4 * (state - schema.c4_state)
    )
    return written
}

# ----------------------------------------------------------------- apply

# What a step would do to a schema. Total: every step gets an outcome.
fn judge(schema: Schema, step: Migration) -> SchemaOutcome {
    if step.kind == step_create_table() {
        if schema.exists == 1 {
            return TableExists(schema.primary)
        }
        return TableCreated(step.key)
    }
    if schema.exists == 0 {
        return NoTable(step.key)
    }
    if step.key < 1 {
        return KeyUnknown(step.key)
    }
    if step.key > capacity() {
        return Full(capacity())
    }
    let state: Int = state_at(schema, step.key)
    if step.kind == step_add_column() {
        if state == slot_live() {
            return KeyLive(step.key)
        }
        if state == slot_retired() {
            return KeyRetired(step.key)
        }
        if label_holders(schema, step.label) > 0 {
            return NameTaken(step.label)
        }
        if step.nullable == 0 {
            if step.policy != policy_backfilled() {
                return NeedsBackfill(step.key)
            }
        }
        return ColumnAdded(step.key)
    }
    if state == slot_retired() {
        return KeyRetired(step.key)
    }
    if state != slot_live() {
        return KeyUnknown(step.key)
    }
    if step.kind == step_rename_column() {
        if label_holders(schema, step.label) > 0 {
            return NameTaken(step.label)
        }
        return ColumnRenamed(step.key)
    }
    if step.key == schema.primary {
        return PrimaryKey(step.key)
    }
    if step.policy != policy_discard() {
        return Destructive(step.key)
    }
    return ColumnDropped(step.key)
}

fn outcome_kind(outcome: SchemaOutcome) -> Int {
    let mut kind = 0
    match outcome {
        TableCreated(_) => { kind = 1 },
        ColumnAdded(_) => { kind = 2 },
        ColumnRenamed(_) => { kind = 3 },
        ColumnDropped(_) => { kind = 4 },
        TableExists(_) => { kind = 5 },
        NoTable(_) => { kind = 6 },
        KeyLive(_) => { kind = 7 },
        KeyRetired(_) => { kind = 8 },
        KeyUnknown(_) => { kind = 9 },
        NameTaken(_) => { kind = 10 },
        PrimaryKey(_) => { kind = 11 },
        Destructive(_) => { kind = 12 },
        NeedsBackfill(_) => { kind = 13 },
        Full(_) => { kind = 14 },
    }
    return kind
}

fn outcome_payload(outcome: SchemaOutcome) -> Int {
    let mut payload = 0
    match outcome {
        TableCreated(key) => { payload = key },
        ColumnAdded(key) => { payload = key },
        ColumnRenamed(key) => { payload = key },
        ColumnDropped(key) => { payload = key },
        TableExists(primary) => { payload = primary },
        NoTable(key) => { payload = key },
        KeyLive(key) => { payload = key },
        KeyRetired(key) => { payload = key },
        KeyUnknown(key) => { payload = key },
        NameTaken(label) => { payload = label },
        PrimaryKey(key) => { payload = key },
        Destructive(key) => { payload = key },
        NeedsBackfill(key) => { payload = key },
        Full(capacity) => { payload = capacity },
    }
    return payload
}

# The schema after a step. A refused step changes nothing.
fn apply(schema: Schema, step: Migration) -> Schema {
    let kind: Int = outcome_kind(judge(schema, step))
    if kind == 1 {
        return with_column(
            empty_schema(), step.key, step.key, step.label, step.column_kind, 0, slot_live()
        )
    }
    if kind == 2 {
        return with_column(
            schema, schema.primary, step.key, step.label, step.column_kind,
            step.nullable, slot_live()
        )
    }
    if kind == 3 {
        return with_column(
            schema, schema.primary, step.key, step.label, kind_at(schema, step.key),
            nullable_at(schema, step.key), slot_live()
        )
    }
    if kind == 4 {
        return with_column(schema, schema.primary, step.key, 0, 0, 0, slot_retired())
    }
    return schema
}

# ----------------------------------------------------------- the history

fn history_length() -> Int {
    return 1
}

# Append a step here for every change to `declared()`, and raise
# history_length() to match. A step, once released, is never edited.
fn history_step(number: Int) -> Migration {
    if number == 1 {
        return migration(step_create_table(), 1, label_id(), kind_bigint(), 0, policy_none())
    }
    return migration(0, 0, 0, 0, 0, policy_none())
}

# The schema after the first `last` steps: the history, folded.
fn replay(last: Int) -> Schema {
    if last == 0 {
        return empty_schema()
    }
    return apply(replay(last - 1), history_step(last))
}

# The first step that `apply` refuses, or 0.
fn refused_from(number: Int, last: Int) -> Int {
    if number > last {
        return 0
    }
    let kind: Int = outcome_kind(judge(replay(number - 1), history_step(number)))
    if kind > 4 {
        return number
    }
    return refused_from(number + 1, last)
}

# ------------------------------------------------------- the declaration

# What the application expects of its database. Retired keys stay listed,
# so a later column can never be handed one.
fn declared() -> Schema {
    let schema: Schema = Schema(
        exists: 1,
        primary: 1,
        c1_label: label_id(),
        c1_kind: kind_bigint(),
        c1_nullable: 0,
        c1_state: slot_live(),
        c2_label: 0,
        c2_kind: 0,
        c2_nullable: 0,
        c2_state: slot_empty(),
        c3_label: 0,
        c3_kind: 0,
        c3_nullable: 0,
        c3_state: slot_empty(),
        c4_label: 0,
        c4_kind: 0,
        c4_nullable: 0,
        c4_state: slot_empty()
    )
    return schema
}

# ------------------------------------------------------- drift and plan

fn differs(left: Schema, right: Schema, key: Int) -> Int {
    if label_at(left, key) != label_at(right, key) {
        return 1
    }
    if kind_at(left, key) != kind_at(right, key) {
        return 1
    }
    if nullable_at(left, key) != nullable_at(right, key) {
        return 1
    }
    if state_at(left, key) != state_at(right, key) {
        return 1
    }
    return 0
}

# The declaration against the replayed history: the first key where they
# disagree, or how many columns are live when they agree.
fn drift(wanted: Schema, replayed: Schema) -> Drift {
    if differs(wanted, replayed, 1) == 1 {
        return Diverged(1)
    }
    if differs(wanted, replayed, 2) == 1 {
        return Diverged(2)
    }
    if differs(wanted, replayed, 3) == 1 {
        return Diverged(3)
    }
    if differs(wanted, replayed, 4) == 1 {
        return Diverged(4)
    }
    return InSync(live_count(replayed))
}

fn drift_kind(found: Drift) -> Int {
    let mut kind = 0
    match found {
        InSync(_) => { kind = 1 },
        Diverged(_) => { kind = 2 },
    }
    return kind
}

fn drift_payload(found: Drift) -> Int {
    let mut payload = 0
    match found {
        InSync(live) => { payload = live },
        Diverged(key) => { payload = key },
    }
    return payload
}

# The step that moves one key from `current` toward `wanted`, decided by
# key. The planner never supplies a policy; a step that needs one is
# refused by `apply` until a person writes it. Kind 0 means nothing to do.
fn plan(current: Schema, wanted: Schema, key: Int) -> Migration {
    let label: Int = label_at(wanted, key)
    let kind: Int = kind_at(wanted, key)
    let nullable: Int = nullable_at(wanted, key)
    if current.exists == 0 {
        if wanted.exists == 1 {
            if key == wanted.primary {
                return migration(step_create_table(), key, label, kind, 0, policy_none())
            }
        }
        return migration(0, key, 0, 0, 0, policy_none())
    }
    let from: Int = state_at(current, key)
    let to: Int = state_at(wanted, key)
    if from == slot_empty() {
        if to == slot_live() {
            return migration(step_add_column(), key, label, kind, nullable, policy_none())
        }
    }
    if from == slot_live() {
        if to == slot_retired() {
            return migration(step_drop_column(), key, 0, 0, 0, policy_none())
        }
        if to == slot_live() {
            if label != label_at(current, key) {
                return migration(step_rename_column(), key, label, 0, 0, policy_none())
            }
        }
    }
    return migration(0, key, 0, 0, 0, policy_none())
}
SCHEMA_CORE

cat >"$target/modules/schema/core/schema_test.kofun" <<'SCHEMA_TEST'
# Unit tests for the schema core. kotest pairs this file with `schema.kofun`
# by name.
#
# The first two tests hold for any declaration: the history replays to it,
# and the planner rediscovers each step. The rest test the rules on a table
# of their own, so they keep passing as the application's schema grows.
# Code 2 stands for a second column's name and for text.

fn outcome_at(schema: Schema, step: Migration) -> Int {
    let outcome: SchemaOutcome = judge(schema, step)
    return outcome_kind(outcome)
}

# A table with only its primary key, built here rather than read from the
# application's history.
fn base() -> Schema {
    return apply(empty_schema(), migration(step_create_table(), 1, label_id(), kind_bigint(), 0, policy_none()))
}

# The same table with a nullable second column.
fn with_second() -> Schema {
    return apply(base(), migration(step_add_column(), 2, 2, 2, 1, policy_none()))
}

fn test_the_history_replays_to_the_declaration() -> Int {
    let found: Drift = drift(declared(), replay(history_length()))
    let mut failures = 0
    failures = failures + expect_eq_int(drift_kind(found), 1)
    failures = failures + expect_eq_int(drift_payload(found), live_count(declared()))
    failures = failures + expect_eq_int(refused_from(1, history_length()), 0)
    return failures
}

# The planner rediscovers the step that created the table, by key.
fn test_the_planner_regenerates_the_first_step() -> Int {
    let first: Migration = history_step(1)
    let planned: Migration = plan(empty_schema(), replay(1), first.key)
    let mut failures = 0
    failures = failures + expect_eq_int(planned.kind, first.kind)
    failures = failures + expect_eq_int(planned.key, first.key)
    failures = failures + expect_eq_int(planned.label, first.label)
    failures = failures + expect_eq_int(planned.policy, policy_none())
    return failures
}

# A drop loses data, so it is refused until the history names Discard; the
# key is then retired and never handed out again.
fn test_a_drop_needs_discard_and_retires_the_key() -> Int {
    let schema: Schema = with_second()
    let dropped: Schema = apply(schema, migration(step_drop_column(), 2, 0, 0, 0, policy_discard()))
    let mut failures = 0
    failures = failures + expect_eq_int(live_count(schema), 2)
    failures = failures + expect_eq_int(outcome_at(schema, migration(step_drop_column(), 2, 0, 0, 0, policy_none())), 12)
    failures = failures + expect_eq_int(state_at(dropped, 2), slot_retired())
    failures = failures + expect_eq_int(outcome_at(dropped, migration(step_add_column(), 2, 2, 2, 1, policy_none())), 8)
    return failures
}

fn test_a_not_null_column_added_later_needs_a_backfill() -> Int {
    let schema: Schema = base()
    let mut failures = 0
    failures = failures + expect_eq_int(outcome_at(schema, migration(step_add_column(), 2, 2, 2, 0, policy_none())), 13)
    failures = failures + expect_eq_int(outcome_at(schema, migration(step_add_column(), 2, 2, 2, 0, policy_backfilled())), 2)
    return failures
}

# A rename keeps the key, and the planner reads a new label at one key as a
# rename, never as a drop and an add.
fn test_a_rename_keeps_the_key() -> Int {
    let schema: Schema = with_second()
    let renamed: Schema = apply(schema, migration(step_rename_column(), 2, 3, 0, 0, policy_none()))
    let planned: Migration = plan(schema, renamed, 2)
    let mut failures = 0
    failures = failures + expect_eq_int(label_at(renamed, 2), 3)
    failures = failures + expect_eq_int(kind_at(renamed, 2), 2)
    failures = failures + expect_eq_int(planned.kind, step_rename_column())
    return failures
}

fn test_the_primary_key_cannot_be_dropped() -> Int {
    let schema: Schema = base()
    return expect_eq_int(outcome_at(schema, migration(step_drop_column(), 1, 0, 0, 0, policy_discard())), 11)
}

# A declaration edited without a migration is drift, and drift names the key.
fn test_drift_names_the_key() -> Int {
    let found: Drift = drift(with_second(), base())
    let mut failures = 0
    failures = failures + expect_eq_int(drift_kind(found), 2)
    failures = failures + expect_eq_int(drift_payload(found), 2)
    return failures
}
SCHEMA_TEST

cat >"$target/modules/schema/shell/schema.kofun" <<'SCHEMA_SHELL'
# The schema shell: replay the history and print what db.sh reads.
#
# Every section opens with its name and closes with `end <name>`:
#
#   history     a count, then nine lines per step:
#               number kind key label column_kind nullable policy outcome payload
#   drift       drift kind (1 InSync, 2 Diverged), what it carried, and the
#               first refused history step, or 0
#   schema      exists primary live, then per key: key label kind nullable state
#   plan        per key, the step that moves the replayed history toward the
#               declaration, or kind 0: kind key label column_kind nullable policy
#   regenerate  a count, then per step: the step number and what the planner
#               proposes for that step's key, from the schema before it to
#               the schema after it

fn emit_migration(step: Migration) -> Int {
    print(step.kind)
    print(step.key)
    print(step.label)
    print(step.column_kind)
    print(step.nullable)
    print(step.policy)
    return 0
}

fn emit_history_from(number: Int, last: Int) -> Int {
    if number > last {
        return 0
    }
    let step: Migration = history_step(number)
    let outcome: SchemaOutcome = judge(replay(number - 1), step)
    print(number)
    emit_migration(step)
    print(outcome_kind(outcome))
    print(outcome_payload(outcome))
    return emit_history_from(number + 1, last)
}

fn emit_column(schema: Schema, key: Int) -> Int {
    print(key)
    print(label_at(schema, key))
    print(kind_at(schema, key))
    print(nullable_at(schema, key))
    print(state_at(schema, key))
    return 0
}

fn emit_regenerated_from(number: Int, last: Int) -> Int {
    if number > last {
        return 0
    }
    let step: Migration = history_step(number)
    print(number)
    emit_migration(plan(replay(number - 1), replay(number), step.key))
    return emit_regenerated_from(number + 1, last)
}

fn main() -> Int {
    let wanted: Schema = declared()
    let replayed: Schema = replay(history_length())

    print("schema report")

    print("history")
    print(history_length())
    emit_history_from(1, history_length())
    print("end history")

    let found: Drift = drift(wanted, replayed)
    print("drift")
    print(drift_kind(found))
    print(drift_payload(found))
    print(refused_from(1, history_length()))
    print("end drift")

    print("schema")
    print(wanted.exists)
    print(wanted.primary)
    print(live_count(wanted))
    emit_column(wanted, 1)
    emit_column(wanted, 2)
    emit_column(wanted, 3)
    emit_column(wanted, 4)
    print("end schema")

    print("plan")
    emit_migration(plan(replayed, wanted, 1))
    emit_migration(plan(replayed, wanted, 2))
    emit_migration(plan(replayed, wanted, 3))
    emit_migration(plan(replayed, wanted, 4))
    print("end plan")

    print("regenerate")
    print(history_length())
    emit_regenerated_from(1, history_length())
    print("end regenerate")
    return 0
}
SCHEMA_SHELL

cat >"$target/db.sh.in" <<'DB'
#!/bin/sh
set -eu

# boot db, for this project.
#
#   sh db.sh check    every history step applies, the history replays to the
#                     declaration, and the planner regenerates every step
#   sh db.sh sql      the declared table, as PostgreSQL DDL
#
# Both read the sections the built schema binary prints, never the source,
# so the SQL cannot describe a column the core does not hold.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KOFUN=${KOFUN:-"@KOFUN@/bin/kofun"}

fail() {
    printf 'db: %s\n' "$*" >&2
    exit 1
}

mode=${1:-}
case $mode in
    check|sql) ;;
    *) printf 'usage: sh db.sh check|sql\n' >&2; exit 2 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/db.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

cat "$ROOT/modules/schema/core/schema.kofun" >"$WORK/schema.unit.kofun"
printf '\n' >>"$WORK/schema.unit.kofun"
cat "$ROOT/modules/schema/shell/schema.kofun" >>"$WORK/schema.unit.kofun"
"$KOFUN" build "$WORK/schema.unit.kofun" -o "$WORK/schema" >/dev/null 2>"$WORK/build.err" ||
    fail "the schema did not build: $(cat "$WORK/build.err")"
env -i "$WORK/schema" >"$WORK/out" || fail 'the schema binary exited non-zero'

section() {
    grep -qx "$1" "$WORK/out" || fail "the schema report has no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

# Codes become names here and only here. Add a name when the core gains a
# code; a code with no name is refused rather than printed as a number.
TABLE=items

column_name() {
    case $1 in
        1) printf 'id' ;;
        2) printf 'title' ;;
        *) return 1 ;;
    esac
}

kind_name() {
    case $1 in
        1) printf 'bigint' ;;
        2) printf 'text' ;;
        3) printf 'boolean' ;;
        *) return 1 ;;
    esac
}

step_name() {
    case $1 in
        0) printf 'nothing' ;;
        1) printf 'CreateTable' ;;
        2) printf 'AddColumn' ;;
        3) printf 'RenameColumn' ;;
        4) printf 'DropColumn' ;;
        *) printf 'step kind %s' "$1" ;;
    esac
}

outcome_name() {
    case $1 in
        5) printf 'TableExists' ;;
        6) printf 'NoTable' ;;
        7) printf 'KeyLive' ;;
        8) printf 'KeyRetired' ;;
        9) printf 'KeyUnknown' ;;
        10) printf 'NameTaken' ;;
        11) printf 'PrimaryKey' ;;
        12) printf 'Destructive: a drop needs policy_discard()' ;;
        13) printf 'NeedsBackfill: a NOT NULL column needs policy_backfilled()' ;;
        14) printf 'Full' ;;
        *) printf 'outcome %s' "$1" ;;
    esac
}

if test "$mode" = check; then
    section history | sed 1d | paste - - - - - - - - - >"$WORK/history"
    while IFS='	' read -r number kind key label column_kind nullable policy outcome payload; do
        test "$outcome" -le 4 ||
            fail "history step $number ($(step_name "$kind") at key $key) is refused: $(outcome_name "$outcome") ($payload)"
    done <"$WORK/history"

    section drift >"$WORK/drift"
    if test "$(sed -n 1p "$WORK/drift")" != 1; then
        key=$(sed -n 2p "$WORK/drift")
        planned=$(section plan | paste - - - - - - | sed -n "${key}p")
        set -- $planned
        fail "the declaration and the history disagree at key $key. Append the step the planner proposes to history_step(), or undo the declaration: $(step_name "$1") key $2 label $3 kind $4 nullable $5"
    fi

    section regenerate | sed 1d | paste - - - - - - - >"$WORK/regenerated"
    cut -f1-6 "$WORK/history" >"$WORK/committed"
    cut -f1-6 "$WORK/regenerated" >"$WORK/proposed"
    if ! cmp -s "$WORK/committed" "$WORK/proposed"; then
        step=$(diff "$WORK/committed" "$WORK/proposed" | sed -n 's/^< \([0-9]*\).*/\1/p' | head -1)
        fail "the planner did not regenerate history step ${step:-?}; a step must change the key it names and nothing else"
    fi
    awk -F'\t' '$7 != 0 { exit 1 }' "$WORK/regenerated" ||
        fail 'the planner supplied a policy; a policy is a person'"'"'s decision'

    printf 'db check: the history replays to the declaration (history steps: %s, live columns: %s), and the planner regenerates every step: PASS\n' \
        "$(wc -l <"$WORK/history" | tr -d ' ')" "$(sed -n 2p "$WORK/drift")"
    exit 0
fi

section schema >"$WORK/schema"
test "$(sed -n 1p "$WORK/schema")" = 1 || fail 'the declaration has no table'
primary=$(sed -n 2p "$WORK/schema")
sed 1,3d "$WORK/schema" | paste - - - - - >"$WORK/columns"
retired=''
{
    printf '%s\n' "-- Projected by db.sh from the declaration the schema binary printed."
    printf 'create table %s (\n' "$TABLE"
    while IFS='	' read -r key label kind nullable state; do
        if test "$state" = 2; then
            retired="$retired $key"
            continue
        fi
        test "$state" = 1 || continue
        name=$(column_name "$label") || fail "column label $label at key $key has no name; add it to db.sh"
        type=$(kind_name "$kind") || fail "column kind $kind at key $key has no SQL type; add it to db.sh"
        null=''
        if test "$nullable" = 0; then
            null=' not null'
        fi
        printf '    %s %s%s,  -- key %s\n' "$name" "$type" "$null" "$key"
    done <"$WORK/columns"
    primary_label=$(sed -n "${primary}p" "$WORK/columns" | cut -f2)
    printf '    primary key (%s)\n' "$(column_name "$primary_label")"
    printf ');\n'
    printf '%s\n' "-- retired keys:${retired:- none}"
} >"$WORK/sql"
cat "$WORK/sql"
DB
# The language checkout is the one this script used. `#` cannot appear in it
# unescaped, because sed reads it as the delimiter.
case $KOFUN_ABS in
    *'#'*) fail "the language checkout path contains '#': $KOFUN_ABS" ;;
esac
sed "s#@KOFUN@#$KOFUN_ABS#" "$target/db.sh.in" >"$target/db.sh"
rm -f "$target/db.sh.in"
chmod +x "$target/db.sh"

# ------------------------------------------------------------ build/check

cat >"$target/build.sh" <<BUILD
#!/bin/sh
set -eu

# Concatenate the core with the shell and build. The executable slice has no
# module imports, so a two-layer application is assembled by text in a fixed
# order — and that order is the dependency direction, which is the only one
# that compiles.

ROOT=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
KOFUN=\${KOFUN:-"$KOFUN_ABS/bin/kofun"}
OUT=\${1:-"\$ROOT/build/$name"}
if test "\$#" -gt 0; then shift; fi

mkdir -p "\$(dirname -- "\$OUT")"
UNIT="\$(dirname -- "\$OUT")/$name.unit.kofun"

cat "\$ROOT/core/core.kofun" >"\$UNIT"
printf '\\n' >>"\$UNIT"
cat "\$ROOT/shell/shell.kofun" >>"\$UNIT"

"\$KOFUN" build "\$UNIT" -o "\$OUT" "\$@" >/dev/null
printf '%s\\n' "\$OUT"
BUILD
chmod +x "$target/build.sh"

cat >"$target/tests/check.sh" <<CHECK
#!/bin/sh
set -eu

# The project gate: the boundary holds, the unit suite passes, and the built
# program still prints what it printed.

ROOT=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)
KOFUN_DIR=\${KOFUN_DIR:-"$KOFUN_ABS"}
KOTEST="\$KOFUN_DIR/tooling/kotest/run.sh"

WORK=\$(mktemp -d "\${TMPDIR:-/tmp}/$name.XXXXXX")
trap 'rm -rf "\$WORK"' 0 1 2 15

fail() {
    printf '$name: FAIL: %s\\n' "\$*" >&2
    exit 1
}

# The boundary, read with comments stripped: the core may receive a capability
# and may not construct one, and may not own an entry point. Both files talk
# about the boundary at length, and a grep over the whole text cannot tell an
# explanation from a violation.
for core in "\$ROOT/core/core.kofun" "\$ROOT/modules/schema/core/schema.kofun"; do
    sed 's/[[:space:]]*#.*\$//' "\$core" >"\$WORK/core.code"
    if grep -qE 'Capabilities\\(' "\$WORK/core.code"; then
        printf '%s\\n' '$name: FAIL: the core constructs a capability instead of receiving one:' >&2
        grep -nE 'Capabilities\\(' "\$WORK/core.code" >&2
        exit 1
    fi
    grep -qE '^fn main' "\$WORK/core.code" &&
        fail "\${core#"\$ROOT"/} owns an entry point; emission belongs to the shell"
done

sh "\$KOTEST" "\$ROOT/core/core_test.kofun"

# The schema: every history step applies, the history replays to the
# declaration, the planner regenerates every step, and the committed SQL is
# the projection. db check runs before the schema suite, so a declaration
# edited without its migration fails here first, naming the key and the step
# the planner proposes.
sh "\$ROOT/db.sh" check || exit 1
sh "\$KOTEST" "\$ROOT/modules/schema/core/schema_test.kofun"
sh "\$ROOT/db.sh" sql >"\$WORK/schema.sql"
if test -f "\$ROOT/modules/schema/schema.sql"; then
    cmp -s "\$ROOT/modules/schema/schema.sql" "\$WORK/schema.sql" ||
        fail "modules/schema/schema.sql is not the projection of the declaration; review it and run: sh db.sh sql >modules/schema/schema.sql
\$(diff "\$ROOT/modules/schema/schema.sql" "\$WORK/schema.sql" | head -10)"
else
    cp "\$WORK/schema.sql" "\$ROOT/modules/schema/schema.sql"
    printf '$name: recorded modules/schema/schema.sql\\n'
fi

binary=\$(sh "\$ROOT/build.sh" "\$WORK/$name")
"\$binary" >"\$WORK/out"
if test -f "\$ROOT/tests/expected.stdout"; then
    cmp "\$ROOT/tests/expected.stdout" "\$WORK/out" ||
        fail "output differs from tests/expected.stdout:
\$(diff "\$ROOT/tests/expected.stdout" "\$WORK/out" | head -10)"
else
    cp "\$WORK/out" "\$ROOT/tests/expected.stdout"
    printf '$name: recorded tests/expected.stdout\\n'
fi

# Deterministic means deterministic. If this ever fails, something ambient got
# in — which is exactly what the boundary above exists to prevent.
env -i "\$binary" >"\$WORK/bare"
cmp "\$WORK/out" "\$WORK/bare" ||
    fail 'output changed with an empty environment'

printf '$name: the boundary holds, the suites pass, the schema replays, the bytes do not move: PASS\\n'
CHECK
chmod +x "$target/tests/check.sh"

cat >"$target/README.md" <<README
# $name

Built with [kofun-boot](https://github.com/kofun-lang/kofun-boot).

\`\`\`sh
sh tests/check.sh    # the boundary, both suites, the schema, and the recorded output
sh build.sh          # build, printing the path
sh db.sh check       # the history replays to the declaration
sh db.sh sql         # the declared table, as PostgreSQL DDL
\`\`\`

## The shape

\`core/\` is pure. It may receive a capability as an argument and may not
construct one, and it may not own an entry point — \`tests/check.sh\` enforces
both, and prints the offending line when it does not hold.

\`shell/\` owns the capability record and every print. It is the only place
that decides what the outside world sees.

That split is why \`core/core_test.kofun\` needs no server, no clock, and no
network: the core is a function, so its tests are arithmetic.

## The schema

\`modules/schema/\` declares one table, \`items\`, whose columns are identified
by key, never by name. Its history is a list of migration values, and
\`sh db.sh check\` requires the history to replay to the declaration exactly.

To add a column, change \`declared()\` and append the step that gets there to
\`history_step()\`. If you change only the declaration, \`db.sh check\` names
the key and prints the step the planner proposes. It never writes a policy for
you: a drop needs \`policy_discard()\`, and a NOT NULL column added later needs
\`policy_backfilled()\`. Give each new code a name in \`db.sh\`, then review the
SQL and record it with \`sh db.sh sql >modules/schema/schema.sql\`.

## Adding a decision

Put it in \`core/\`, return a closed sum whose every case carries what was
observed, and add a test that reads each case by name. If the decision needs
something from outside, take it as an argument — the shell will hand it in.
README

printf '%s\n' \
    "boot new: created $target" \
    "" \
    "  cd $target" \
    "  sh tests/check.sh"
