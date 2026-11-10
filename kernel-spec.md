# Workflow engine kernel: spec v2.4

Status: proposal. The design doc summarises it; this file is the reference.

The spec covers every known use case; only the MVP is built. Three tiers:
- **Permanent layer** (event shapes, IDs, insurance fields): specified in full now. Section 5.
- **MVP behaviour:** specified in full. Sections 2 to 4, 6, 7 and 9. Its tests are in `test-cases/`.
- **Later features:** one short reserved rule each, in section 8, plus a paper case in `expansion-battery.md`. Full spec when built.

The spec stays terse. The reason an insurance field exists is the battery case it points to: if that case can no longer be expressed, the field was removed.

## 1. Scope

The change-request workflow is the refactor of the existing Change Management product: same behaviour, with the workflow part made configurable. It is the only workflow in the MVP.

| Part | MVP | Reserved (slots held, not built) |
|---|---|---|
| Stage | Root stage plus one level of child stages | Deeper nesting is not planned: a multi-step task inside a stage is a child request. History can already describe nesting (`parentActivation`). |
| Transition | Yes | |
| Wait: person | Yes, with a single `may` rule | Act-time gates; repeatable waits |
| Wait: call | Yes (directory read) | |
| Wait: timer | No | Section 8 |
| Wait: child | No | Section 8 |
| `foreach` | Yes, on person waits | On other wait kinds |
| Set | Yes | |
| Notification rules | Yes | |
| Publish through the API | Yes (a JSON POST; no composite library, one hand-written approval expansion) | Composite registry |

The event vocabulary is provisional until a second use case has been built against it. Every event carries a schema version so shapes can be upcast.

## 2. Blocks

**Definition.** `{start, root, notifications}`. `start` is `{schema, set}`: the input is validated against `schema` and `set` writes it into data. `root.initial` names the child stage a request starts in.

**Stage.** A named scope. The root stage is always active; exactly one child stage is active. Each entry creates an *activation* with a new ID. A stage declares waits, transitions, an optional display `status`, and optional `requires` (data paths that must exist on entry). Entering a stage opens all its waits. Leaving it cancels the ones still open. A `final` stage closes the request. Replay state and the request table store the active stages as a set; only `decide` enforces "exactly one active child" (battery P4).

**Transition.** `{id, when: CEL, set: {path: CEL}, to: stage}` declared on a stage.
- Level-triggered: `when` is evaluated over recorded state at the end of every turn.
- Fires at most once per activation of its declaring stage. A root transition is therefore one-shot in the MVP, which suits withdraw, cancel and deadline interrupts. A repeatable root action needs repeatable waits (reserved).
- A root transition whose target is a child stage is *local*: the root stays active, only the active child is exited.
- A self-target exits and re-enters (new activation, fresh waits).
- `otherwise` is a built-in condition: every wait of this stage is `completed` and no other transition is enabled. A skipped wait never satisfies it.
- Order: root transitions first, then the child stage's, in declared order. First true one fires.

**Wait.** ID = `(element, activation, key, seq)`; `seq` is always 1 in the MVP (battery C3). Lifecycle: `open -> completed | cancelled | skipped`.
- In CEL every wait in scope is always readable as `waits.<name>` = `{status, outcome, by}`; `outcome` is `""` unless completed; `by` is the ID of the person or connector that completed it. `waits.<name>.data` may be read only under a guard on that wait's outcome; the publish check enforces it.
- *Person:* `assignees` (user and group references, recorded at open, not expanded), `may` (optional CEL, default true; reads `data`, `request`, `actor`, waits in scope), `outcomes` (enum, each with a data schema), `role: obligation | option`. At act time the engine looks up the actor's memberships, checks `assignees` and `may`, validates data, and records the lookup as evidence. A refused attempt changes nothing and goes to an attempts log outside history.
- *Call:* `connector`, `op`, `args`, `effect: read | write`, optional `idempotencyKey`. Outcome `ok` or `failed`. Default idempotency key: reads are per activation (re-entry reads again); writes are per request. The pending call is written in the same transaction as the event that opened it; a dispatcher delivers at least once, and a reconciler re-queues anything open with no delivery in flight.
- *Connector obligations:* honour the key. For a key that already succeeded, return that result and do nothing else (look up by key before creating if the external system has no idempotency support). For a key that failed, try again. Never report a timeout or "don't know" as `failed`; keep the call pending. An author who wants a retry with different arguments sets an explicit key.
- *`foreach`:* `foreach: <CEL list>` on a person wait opens one wait per item when the stage is entered. The list is evaluated once and recorded; it is not re-evaluated if data changes later. Items must be distinct (a duplicate is a fault). `item` is available in the wait's other expressions and becomes the wait's `key`. In CEL the waits read as a list: `waits.<name>.all(w, ...)`, `.exists(w, ...)`. An empty list opens nothing, and `all` over it is true.

**Set.** Writes to the request's data document, only on a transition, on start, or by an admin.

**CEL context.** `data`; `request` = `{id, by, at}` (`by` is the starter's ID); `actor` = `{id}` (in `may` only); `waits` for the current activations of the root and the active child. Earlier activations are invisible. There is no clock. Anything that must persist goes through Set.

Waits on the root stage are open for the whole life of the request and are cancelled when it closes. The change request does not use them.

## 3. Turns

One input is one *turn*, under a per-request lock, in one Postgres transaction:

1. Validate the input against current state. If the wait is not open or the actor is not allowed, reject and write nothing to history.
2. Append the input event.
3. `decide`: fire transitions until none is enabled, appending every consequence as events.
4. Stuck check: if the request is not closed and has no open obligation and no open call, append `Faulted{kind: stuck}`.

Event order within a turn: the input; then for each firing `TransitionFired`, `DataSet`, `WaitCancelled` (declared order), `StageExited`, `StageEntered`, `WaitOpened` (declared order, `foreach` in list order); then `RequestClosed` or `Faulted` if any. Starting a request enters the root, then `root.initial`.

`evolve(state, event)` is the only code replay uses. It never evaluates CEL and never reads the definition.

**Faults.** If a CEL evaluation errors, or a turn exceeds 50 firings, the turn's decisions are rolled back, the input event is kept, and `Faulted{kind: error, element, error}` is appended. A faulted request still accepts and records inputs but runs no `decide` until an admin turn clears the fault; then `decide` runs for the kept inputs in order. A CEL error is never treated as false. Reading a waived `requires` path is a CEL error. A `stuck` fault is a flag for admins: it does not stop evaluation, and it is cleared by an admin turn or by the request closing.

## 4. Admin turns

`Overridden {by, reason, breakGlassSession?, actions, waived}` is an input event. Its consequences are ordinary events in the same turn. All actions are applied first; `decide` and the stuck check run once, at the end of the turn. Actions:

- **Skip one wait:** `WaitSkipped`. Conditions see `status: skipped`. A skip alone never decides anything: it does not satisfy `otherwise` or any outcome test. To move on, the admin also jumps, or the author writes an explicit path (`when waits.x.status == 'skipped'`).
- **Jump to a stage:** open waits in the exited stage are skipped; the event records `from` and `to`. For each path in the target's `requires`, the admin supplies a value or lists it in `waived`.
- **Set data:** `DataSet{source: admin}`.
- **Disable a transition for this request.**
- **Clear a fault.**
- **Close, or reopen at a stage:** `RequestClosed` / `RequestReopened`. Reopening creates new activations of the root and the target stage.

There is no event that rewrites an earlier one. A wrong completion stays in history as what happened; the fix is an admin turn. Break-glass users can do all of this on their own requests.

## 5. Event vocabulary

Envelope on every event: `requestId`, `seq`, `at` (the only clock), `turn` (seq of the input that caused it), `v` (schema version of this event type), `engineBuild`. Events name definition elements by stable ID; the published definition maps each element to the composite it came from.

| Kind | Event | Payload |
|---|---|---|
| Input | `RequestStarted` | definition, version, by, input, `trigger` (reserved), `parent: {requestId, wait}` (battery P1, P2) |
| Input | `WaitCompleted` | wait, outcome, data, by, evidence |
| Input | `CallResultLate` | wait, outcome, data. A call's result arriving after the wait was cancelled or skipped, or after the request closed. Never visible to conditions. |
| Input | `Overridden` | see section 4 |
| Decision | `TransitionFired` | transition ID, declaring activation, `reads` (the values the condition read) |
| Decision | `StageEntered` | activation, stage, `parentActivation` (battery P4) |
| Decision | `StageExited` | activation, mode: normal or forced |
| Decision | `WaitOpened` | wait (element, activation, key, seq), kind, role, resolved params (assignees and schemas; or connector, op, args, idempotency key; kind child, reserved: `request`, `onCancel`; battery P1 to P3) |
| Decision | `WaitCancelled` | wait, cause: stage exit or request closed |
| Decision | `WaitSkipped` | wait |
| Decision | `DataSet` | patch, source: start, transition or admin |
| Decision | `Faulted` | kind: error or stuck, element, error |
| Decision | `RequestClosed` | final stage, or closed by admin |
| Decision | `RequestReopened` | stage |

`RequestClosed` is not the end of a history: `CallResultLate` and `Overridden` can follow it.

## 6. Publish checks (MVP)

- Every CEL expression type-checks against the data schema, wait outcomes and connector result types.
- Wait reads are in scope; `.data` reads are guarded.
- A data path is read only where it is set on every path to that point or listed in the stage's `requires`.
- Outcomes are enums. Each stage's transitions cover every combination of its waits' outcomes, or the stage has an `otherwise`.
- Every stage can reach a final stage.
- Every cycle of transitions passes through a condition on a wait opened inside the cycle.
- Warning: a write call in a stage that a root transition can interrupt.

"Cannot get stuck" is not provable in general; the runtime stuck check is the backstop. Whether anybody is able to act on a person wait is not a kernel concern: the approval composite reads group membership, and a notification rule alerts on the result.

## 7. Notification rules

The definition's `notifications` block is published with the definition and never read by `decide`.

```
notifications:
  - id: <stable ID>
    on:   <event type, optionally narrowed to an element>     e.g. WaitCompleted members
    when: <CEL over that event's recorded payload, plus request>
    send: { template, to }
```

- The notifier is a separate consumer of the committed event stream. It processes events in order, at least once, and dedupes on `(requestId, seq, rule ID)`.
- A sent notification is not in the request's history; only the event that triggered it is. The workflow cannot wait on or branch on a notification.
- When an alert must affect the flow (an escalation something waits on), use a call wait in a stage instead.
- Telling assignees about a new obligation is a rule on `WaitOpened`.

Other contracts:
- The published definition format and its CEL environment are a second long-lived contract: the engine must be able to run `decide` for a definition version for as long as a request on it is open.
- Action-item list = open person waits with `role: obligation` whose assignees name the viewer or a group they belong to now. Options show on the request page only.

## 8. Reserved features (not built in the MVP)

**Child requests** (battery P1 to P3).
- Start is a call: `engine.start {workflow, version, input}`, result `{requestId}`. Default key is per request, so re-entering the stage returns the same child.
- Await is a wait of kind `child`: `{request, onCancel: detach | terminate}`. It completes with the child's final stage as outcome and the child's output as data.
- An await never completes in the turn that opens it. Completion always arrives as a later input, so `decide` never reads another request's state.
- Cancelling an await detaches or terminates the child per `onCancel`. A parent closing a child is recorded in the child's history as `Overridden` by a system identity.
- The parent definition pins the child workflow's version, so the publish check can verify the outcomes its conditions read.
- Fire-and-forget is a start whose ID nobody awaits.

**Timer waits.** Same lifecycle and events as other waits. The instant is fixed and recorded when the wait opens. A timer is for making something happen when a time arrives.

**Act-time gates** (battery C2). No event type or shape change.
- `may` on a person wait becomes per outcome: a list of named checks, each `{id, when: CEL, message}`.
- Checks run before the input is accepted. A refused attempt writes nothing to history (attempts log only).
- Checks may read the request's data, wait statuses in scope, the actor, and `now` (the time of the attempt). Transitions still cannot read the time. No external lookups other than the membership lookup.
- On an accepted attempt, `WaitCompleted.evidence` records each check's ID and the values it read.
- The UI can ask which outcomes are available to the viewer and which checks fail. That preview is advisory; the act-time check is authoritative.
- A deadline that blocks a manual move is a gate, not a timer. A gate never makes anything happen by itself.
- A workflow-level emergency override is a second outcome on the same wait, with fewer checks and a mandatory comment as its data. It is separate from the platform admin override.
- Known limit: the publish check cannot prove a gate is passable, and the stuck check will not catch an unpassable one, because an obligation is still open.

**Repeatable waits** (battery C3). A second instance of the same wait within one stage entry takes the next `seq`. Nothing else is specified yet.

## 9. The change request

The request has one primary domain and zero or more other domains, from the form. Every domain's approvers must approve. The primary domain's approver must pick the eng lead in order to approve. The request only moves forward.

```
start: { schema: changeForm, set: { form: input } }
root:
  initial: Pending
  stages:
    Pending:
      waits:
        members: call { connector: directory, op: membersOf, effect: read,
                        args: { groups: ([data.form.primaryDomain] + data.form.otherDomains)
                                          .map(d, approverGroup[d]) } }
        primary: person { assignees: [group: approverGroup[data.form.primaryDomain]],
                          may: actor.id != request.by, role: obligation,
                          outcomes: { approve: { engLead: user }, reject: { reason: string } } }
        others:  person { foreach: data.form.otherDomains,
                          assignees: [group: approverGroup[item]],
                          may: actor.id != request.by, role: obligation,
                          outcomes: { approve: {}, reject: { reason: string } } }
      transitions:
        t_reject: when waits.primary.outcome == 'reject'
                       || waits.others.exists(w, w.outcome == 'reject')           ->  Rejected
        t_accept: when waits.primary.outcome == 'approve'
                       && waits.others.all(w, w.outcome == 'approve')
                  set { engLead: waits.primary.data.engLead }                     ->  InDevelopment
    InDevelopment:  requires: [engLead]
      waits:  release: person { assignees: [user: data.engLead], role: obligation, outcomes: [released] }
      transitions:  t_release: when waits.release.outcome == 'released'  ->  Released
    Released: final     Rejected: final
notifications:
  - id: n_no_approver
    on:   WaitCompleted members
    when: outcome == 'failed' || data.groups.exists(g, !g.members.exists(m, m != request.by))
    send: { template: alertAdmins, to: group: workflowAdmins }
  - id: n_task
    on:   WaitOpened
    when: kind == 'person' && role == 'obligation'
    send: { template: newTask, to: assignees }
```

No transition reads `members`. Its result is recorded so the notifier can alert admins when a domain has nobody able to approve; the request is submitted either way and waits.

Happy path with one other domain (input first in each turn):

1. `RequestStarted` · `DataSet` · `StageEntered root` · `StageEntered Pending` · `WaitOpened members` · `WaitOpened primary` · `WaitOpened others[domainB]`
2. `WaitCompleted members ok`
3. `WaitCompleted others[domainB] approve`
4. `WaitCompleted primary approve {engLead}` · `TransitionFired t_accept` · `DataSet` · `StageExited Pending` · `StageEntered InDevelopment` · `WaitOpened release`
5. `WaitCompleted release` · `TransitionFired t_release` · `StageExited InDevelopment` · `StageEntered Released` · `RequestClosed`

The edge cases are the test cases in `test-cases/c1-change-request.yaml`.

Assumptions to confirm against the existing product: approvals for all domains run in parallel; one rejection rejects the whole request; a person in two domains' groups may approve for both.

## 10. Not addressed

- Erasing personal data from history (set aside for now).
- Date-triggered starts and scheduling (set aside; possibly a separate obligations feature later).
- A grammar and an author's guide for the definition format.
- A bulk admin action across many requests.
