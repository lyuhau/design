# Model H (hybrid): paper test against kernel spec v2.4

## Summary

H handles the simple write patterns (1, 2, 8, 9) with no new event type. It cannot do pattern 7 as stated, and for patterns 4, 5, 6 the only strict expansion turns approvals into data, which is model D with extra ceremony. H as stated also does not deliver the spec's own reserved use case ("a repeatable root action needs repeatable waits", section 2), because transitions stay one-shot.

History changes found:

| Change | Needed for |
|---|---|
| `DataSet.source` gains the value `wait` | H at all: v2.4 allows only start, transition, admin |
| `WaitCancelled.cause` gains `replaced` | Only if fix F8 is adopted (patterns 4, 5, 6) |
| `Overridden.actions` gains "reopen wait" | Only if fix F10 is adopted |

No new event type is needed anywhere. `WaitOpened.seq > 1` is already held.

## Rules I had to add

The stated rules do not expand any pattern without F1 to F3.

| # | Rule | Layer |
|---|---|---|
| F1 | `DataSet.source: wait` (the causing wait is found through the envelope `turn`) | History (enum value) |
| F2 | A wait's Set binds `this = {outcome, data, by, at}` and `item`; Set paths may be keyed by `item` or `this.by` | Definition language |
| F3 | The wait's Set and the reopen are part of `decide`, in the order `DataSet`, then `WaitOpened`, before any `TransitionFired`; after a fault is cleared they run for each kept input | Spec section 3, internals |
| F4 | Reading a repeatable wait in a condition is a publish error; the coverage and cycle checks are restated for conditions over data | Definition language (publish checks) |
| F5 | `pending: <CEL over data>` on a repeatable wait: while true it counts as an open obligation for the stuck check and the action-item list | Definition language, internals |
| F6 | The API may address "the current instance" so the engine picks the seq at turn time | Internals |
| F7 | A completion may open a call instance; that call has its own Set; its idempotency key includes the seq | Definition language |
| F8 | `reopens: [waits]` on a repeatable wait: cancel and reopen the named waits with the next seq and re-resolved params (for `foreach`, re-evaluate the list) | Definition language, history (enum value) |
| F9 | A close-once wait may also have a Set | Definition language |
| F10 | Admin action "reopen wait" | History (`Overridden.actions` value) |

## Patterns

Notation: `tick[a]#2` is element `tick`, key `a`, seq 2.

**1. Checkbox: clean with F1, F2; awkward without F4, F5.**
```
tick: person { foreach: data.items, repeatable, role: option,
               outcomes: [tick, untick], set { ticks[item]: this.outcome == 'tick' } }
t_go: when <approvals> && data.required.all(i, data.ticks[i]) -> Next
```
Events: `WaitCompleted tick[a]#1 tick` · `DataSet{source: wait}` · `WaitOpened tick[a]#2`.
Two problems. When the approvals are done and a tick is missing, there is no open obligation, so the stuck check appends `Faulted{stuck}` on a request that is working as designed (F5). And the publish check demands outcome coverage or an `otherwise`; `otherwise` would fire the moment the approvals complete, skipping the gate (F4).

**2. Field edit: clean.** `edit: person { repeatable, outcomes: { save: { value } }, set { form.title: this.data.value } }`. Same three events per edit.

**3. Question and answer: awkward.**
```
ask:    person { foreach: approvers, repeatable, outcomes: { ask: { text } },
                 set { qa[item].open: true, qa[item].n: data.qa[item].n + 1 } }
answer: person { foreach: approvers, assignees: [request.by], repeatable,
                 may: data.qa[item].open, set { qa[item].open: false } }
approve: ... may: !data.qa[item].open
```
The approval stays open, which is the requirement. The awkward part: the answer is really an obligation for the requester, but a repeatable wait is an option, so it is not in the action-item list and the stuck check ignores it. F5 fixes it. Telling the requester is a notification rule on `WaitCompleted ask`, which the stated rules allow. Model E is better: "on ask, open an obligation for the answer".

**4. Reassign: awkward (close to cannot).** Assignees are recorded at open. The only strict expansion is a broad assignee group plus `may: actor.id == data.owner`, with a repeatable `reassign` wait writing `data.owner`. It enforces correctly, but the action-item list and `n_task` use the recorded assignees, so the whole group sees the task. Clean fix is F8: `WaitCancelled approve#1 {cause: replaced}` · `WaitOpened approve#2` with the new assignee. E does this natively.

**5. Add a reviewer: awkward.** `foreach` is evaluated once. Strict expansion: verdicts become data.
```
addReviewer: person { repeatable, set { reviewers: data.reviewers + [this.data.user] } }
verdict:     person { repeatable, may: actor.id in data.reviewers,
                      set { verdicts[this.by]: this.outcome } }
t_ok: when data.reviewers.filter(r, data.verdicts[r] == 'approve').size() >= 2
```
It works and keeps earlier verdicts. The cost: approvals are no longer obligations (no action items, no `n_task`, false stuck faults), outcome coverage is unprovable, and a verdict can be changed unless `may` forbids it. This is model D written with waits; D does it more plainly. F8 with a live `foreach` keeps the approvals as real waits: `WaitOpened review[newUser]#1`.

**6. Invalidating edit: awkward.** Two strict routes.
- Verdicts as data with a revision counter (`verdicts[by] = {outcome, rev: data.rev}`, gate compares to `data.rev`). Same costs as pattern 5.
- A self-target transition: `edit` sets `dirty: true`; `t_redo: when data.dirty set { dirty: false } -> Review`. This re-asks every approval, and works repeatedly because each entry is a new activation. But the publish rule "every cycle passes through a condition on a wait opened inside the cycle" cannot be met, because conditions may not read the repeatable wait (F4). It also dismisses all approvals, never a subset.

F8 gives selective dismissal. E is better here.

**7. Work on every occurrence: cannot.** Calls open on stage entry and the only per-occurrence reaction allowed is a notification, whose result the workflow cannot know. With the "may open a call" extension (F7): `WaitCompleted push#2` · `DataSet` · `WaitOpened push#3` · `WaitOpened sync#2 {kind: call}`; later `WaitCompleted sync#2 ok` · `DataSet`. No history shape change. Three things must be decided:
- The default write key is per request, so the second call would return the first result. The key must include the seq.
- Two calls can be in flight and return out of order; a plain Set is then last-arrival-wins. Either write under `sync[seq]` or open the next person instance only when the call returns.
- The call's result must reach data, so the call needs its own Set.

E is clearly the best fit.

**8. Concurrent edits: clean, H's best pattern.** Turns are serialised by the request lock. A completes `edit#3`; B's submission against `edit#3` fails step 1 ("wait not open"), writes nothing, and goes to the attempts log. The seq is a free optimistic-concurrency token. With `foreach`, different items do not conflict. For actions that never conflict (ask a question, add a comment) the rejection is spurious; F6 removes it. D needs its own version token; E has no built-in conflict detection.

**9. Undo and correction: clean for correction, awkward for a window.** Correction is a second completion: `WaitCompleted edit#1 {A}` and `WaitCompleted edit#2 {B}` both stay, with `by` and `at`. A time window needs `this.at` in Set (F2) plus `now` in `may`, which is already reserved under act-time gates. Correcting a close-once wait (a wrong approval) is still an admin turn. Nothing can be undone after the stage has been left.

**10. Derived state: awkward.** `when data.required.all(i, data.ticks[i]) && !data.qa.open && data.approvedRev == data.rev` works as an exit gate, and `may` can read the same data. But "no edit since the last approval" needs the approval to stamp `approvedRev`, and a close-once wait has no Set (F9). Without F9 the author must make approvals repeatable (pattern 5 costs) or forbid edits after the first approval through `may`. There are no named derived values, so the expression is repeated; a `derive` block would be additive.

## The two rules

**"Conditions cannot read a repeatable wait."** The mechanics almost force it: the next instance opens in the same turn, so `waits.x` would always read `open` with an empty outcome. What it costs:
- Every fact (who, how many times, last outcome) is copied into data by hand (patterns 3, 5, 6, 10).
- The outcome-coverage and cycle publish checks are built on wait reads and stop working for anything a repeatable wait drives (patterns 1, 6).

Relaxing it later is additive, provided reading one is a publish error today (F4) and not a vacuous value. A later `waits.x.last` and `waits.x.count` can be folded from existing `WaitCompleted` events; no history change, no effect on published definitions.

**"Transitions stay one-shot per stage entry."** It makes impossible:
- Pattern 7 (a reaction with a result on every use).
- Selective re-asking in pattern 6 and the obligation-per-question in pattern 3.
- A repeatable root action that moves the child stage (send back to draft, used twice). The root is never re-entered, so the transition fires once. The workaround is to declare it on every child stage, with a flag reset and the failing cycle check.

Relaxing later: an opt-in, edge-triggered form ("fires on each completion of wait x") is additive in the definition language. A level-triggered repeat would loop into the 50-firing fault. In history, several `TransitionFired` with the same transition and activation already fit; state now that no consumer may treat that pair as unique. Changing the default would be breaking.

## Mechanics against the spec

- **Event order.** Section 3 lists nothing between the input and the first `TransitionFired`. H inserts `DataSet` and `WaitOpened` there (F3). `DataSet` must come first because the next instance's assignees may read it. If a transition then exits the stage, the turn contains `WaitOpened #n+1` and `WaitCancelled #n+1`. Opening the next instance at the end of the turn, only if the activation is still active, avoids that; decide before the first build because notification rules on `WaitOpened` observe it.
- **Faults.** If the wait's Set errors, the input is kept and the decisions are rolled back, so the instance is completed with no successor and the action is unavailable until an admin clears the fault. F3 makes the kept input re-run the Set and the reopen.
- **Stuck check.** Excluding repeatable waits is already implied by `role: option`. The real problem is the false `stuck` in pattern 1 (F5).
- **`otherwise`.** Excluding repeatable waits is right, but see pattern 1: `otherwise` fires past a data gate.
- **Admin skip.** `WaitSkipped #n` with no successor works and replays without the definition. It is irreversible within the activation; F10 adds the reverse. Admin jump skips the open instance as usual.
- **`foreach`.** `(element, activation, key, seq)` supports a sequence per item. The list is fixed at entry, so items cannot be added mid-stage.
- **Re-entry.** A new activation restarts seq at 1; the IDs do not collide. Data written by earlier instances survives, which is right for ticks and fields and wrong for verdicts kept as data (patterns 5, 6): they stay valid unless every entering transition clears them, and an admin jump or `RequestReopened` runs no Set. Real waits do not have this problem.
- **Two people.** Covered in pattern 8.

## Switching models later

- H to E: E's named event is a `WaitCompleted` on a repeatable wait, and its handler effects are existing decision events. No history change beyond F1.
- H to D: D needs a user write as an input event (`DataSet` is a decision event with no `by` or `evidence`). That is a new event type or a reshaped `DataSet`. H avoids it because `WaitCompleted` carries both.

## What worked without trouble

Wait IDs, per-item sequences, replay without the definition, the attempts log, audit of every occurrence, and `may` reading data at act time.
