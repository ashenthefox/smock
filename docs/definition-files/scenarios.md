# Scenarios

This document is part of the [Definition-file
reference](../definition-files.md).

A *Scenario* is a named state machine within a Mock. Its current state
decides which Stubs can match, and a Stub can move it to another state.
With Scenarios, the same request can get different answers at different
points of a flow: an order is pending until the client pays, and paid
after.

A Stub takes one `scenario` clause, next to `request` and `response`:

| Member | Meaning |
|---|---|
| `name` | The Scenario. Required. |
| `requires` | The Stub matches only while the Scenario is in this state. Without it, the Stub matches in every state. |
| `moveTo` | When the Stub is chosen, the Scenario moves to this state. |

A clause gives `requires`, `moveTo` or both; a clause with neither does
nothing, so it is an error. Scenario and state names are any non-empty
text, compared byte for byte, like Mock names and Stub IDs.

- Every Scenario starts in the state `Started`, with a capital S.
- A Scenario has no declaration. It exists because Stubs name it, and its
  states are `Started` and the ones its Stubs name. The Stubs of one
  Scenario may sit in different Definition files of the same Mock. `smock
  check` warns about a [required state that no Stub moves
  to](../definition-files.md#a-state-that-no-stub-moves-to), so a typo in a
  state name is noticed.
- A Scenario belongs to its Mock. Two Mocks that use the same name each
  have their own Scenario, with its own state.
- `requires` is checked beside the request conditions. A Stub in another
  state is skipped, like a Stub that fails a condition, and the next one in
  the usual order is tried ([Which Stub
  answers](matching.md#which-stub-answers)). Scenario Stubs get no special
  priority.
- A Stub without a clause matches in every state, so adding a Scenario to a
  Mock does not disturb its other Stubs.
- A Stub with `moveTo` and no `requires`, such as a logout, moves the
  Scenario from any state. `moveTo: Started` sends it back to the start.
  Moving to the state it is already in changes nothing.

## Contents

- [An example](#an-example)
- [When the state moves](#when-the-state-moves)
- [Sessions and Ephemeral Stubs](#sessions-and-ephemeral-stubs)
- [How state grows](#how-state-grows)
- [Seeing what moved](#seeing-what-moved)

## An example

The pending and paid answers are two Stubs with the same request and
different `requires`; the one whose state holds answers:

```yaml
mocks:
  - name: payments
    hosts: [payments.svc]
stubs:
  - id: order-pending
    mock: payments
    request: { method: GET, path: /orders/42 }
    scenario: { name: checkout, requires: Started }
    response: { status: 200, json: { status: pending } }
  - id: pay
    mock: payments
    request: { method: POST, path: /orders/42/pay }
    scenario: { name: checkout, requires: Started, moveTo: Paid }
    response: { status: 200 }
  - id: order-paid
    mock: payments
    request: { method: GET, path: /orders/42 }
    scenario: { name: checkout, requires: Paid }
    response: { status: 200, json: { status: paid } }
```

1. `GET /orders/42` answers `{"status":"pending"}`: `checkout` is in
   `Started`.
2. `POST /orders/42/pay` answers 200 and moves `checkout` to `Paid`.
3. `GET /orders/42` now answers `{"status":"paid"}`.
4. A second `POST /orders/42/pay` matches no Stub, since `pay` requires
   `Started`, and gets the Mock's 404.

A chain of states gives "the first answers, then another". This retry
flow [resets the connection](faults.md#connection-faults) twice, then
answers:

```yaml
stubs:
  - id: reset-1
    mock: orders
    request: { method: GET, path: /orders/42 }
    scenario: { name: retry, requires: Started, moveTo: Reset once }
    response: { status: 200 }
    fault: { connection: { kind: reset } }
  - id: reset-2
    mock: orders
    request: { method: GET, path: /orders/42 }
    scenario: { name: retry, requires: Reset once, moveTo: Reset twice }
    response: { status: 200 }
    fault: { connection: { kind: reset } }
  - id: ok
    mock: orders
    request: { method: GET, path: /orders/42 }
    scenario: { name: retry, requires: Reset twice }
    response: { status: 200, json: { id: 42 } }
```

## When the state moves

The state moves the moment smock chooses the Stub, before it builds the
response. It moves whatever then happens to the response: a delay, a
connection Fault, a template error (a 500 that still counts as matched),
a client that disconnects, or a Journal that is off. So:

- Each request sees the moves of every request that reached smock before
  it. Two requests that race for the same step never both get it: the
  first moves the state, and the second sees the new one.
- A request on another connection sees the new state while a delayed or
  streamed response is still on its way.
- A retry flow moves on although its responses fail, as above.
- A request that matches no Stub, or that no Mock takes, moves nothing.
- The state that moves is the one of the Mock that answered. A request
  that falls through to the Default Mock moves the Default Mock's
  Scenario.
- A reload swaps the definitions between two requests, so a move never
  straddles two definition sets.
- `smock render` and the Admin render operation ignore the clause and move
  nothing.

## Sessions and Ephemeral Stubs

State is kept per Mock, per
[Session](../admin-api.md#sessions-and-ephemeral-stubs)
and per Scenario. Concurrent tests that share a Mock each walk their own
flow, as long as each sends its own Session. Requests without a Session
share one state of their own, which is the simplest for a developer
running smock locally.

Each replica keeps its own state, as it keeps its own Ephemeral Stubs,
Variables, copies of Data buckets and Journal. Tests that rely on Scenarios need one replica, or
session affinity. State is lost on restart.

Ephemeral Stubs take the same clause, including Scenarios and states that no
file names, so a test on a shared instance can build its own Scenario
without editing files. An Ephemeral Stub and a file Stub that name the same
Scenario of the same Mock share the Session's state, so an Ephemeral Stub
can replace one step of a Scenario from the files. Like the Stub, the state
belongs to the Session that added it: other Sessions never see it. Deleting
an Ephemeral Stub leaves the state as it is. A state that no Stub names any
more matches no `requires`, and the next reload that swaps in new files
sends it back to `Started` ([Reloading](../definition-files.md#reloading)).
A [reset](../admin-api.md#sessions-and-ephemeral-stubs) of the Session, of
the Mock or of everything clears the states in its scope, and sends their
Scenarios back to `Started`.

Through the Admin API, a test lists its Session's Scenarios of a Mock, with
the state each one is in, and sets the state of one, so that it can start in
the middle of a flow, or reset one Scenario by setting `Started` ([Sessions
and Ephemeral Stubs](../admin-api.md#sessions-and-ephemeral-stubs)). It can
set only a state that the files or its own Ephemeral Stubs name.

## How state grows

smock stores one small entry for each Session, Mock and Scenario whose
state is not `Started`. A move back to `Started` deletes the entry, so
Sessions that never leave `Started`, or come back to it, cost nothing.
Nothing expires an entry.

A load test that gives every request a new Session, against Stubs that
move a state, therefore adds an entry with every request, and smock's
memory grows for the whole run. Give each virtual user one Session for
its whole run instead.

## Seeing what moved

Each [Journal](../admin-api.md#the-journal) entry records the move its Stub
made, as `scenario`:

```json
{ "name": "checkout", "from": "Started", "to": "Paid" }
```

A Stub with a clause but no `moveTo` records the state it answered in as
both `from` and `to`. An entry whose Stub has no clause, or that no Stub
answered, has `null`. When the Journal is off, for the Mock or for all,
the state still moves; only the record is missing.

A request that misses only because of the state gets a Near miss that says
so ([When no Stub matches](matching.md#when-no-stub-matches)). In the
example above, the second payment gets

```http
Smock-Near-Miss: pay; failed=scenario:checkout
```

and its Journal entry holds the condition with the state `pay` requires
and the state the Session's Scenario was in:

```json
{ "condition": "scenario:checkout", "expected": "Started", "actual": ["Paid"] }
```

Only a Stub with `requires` can fail this condition. Scenarios add no
other response header, so the system under test receives what it would
receive from the real service.
