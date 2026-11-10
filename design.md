===\n./research/instage-test/brief.md\n===
# In-stage interactions: paper test brief

## Background

Read the kernel spec first: `C:\Users\HauHau\Claude\workflow-platform\kernel-spec.md` (v2.4). It defines a small workflow engine: stages, transitions, waits, Set; an append-only event history per request that is the source of truth; `decide` records its decisions as events and replay only folds events.

In the first release, a wait closes once, and data is written only on a transition, at start, or by an admin. So an action a person repeats *inside* a stage, without resetting the stage's other waits, cannot be expressed yet. "Repeatable waits" are reserved for this (spec section 8), with one field held: the wait ID carries a sequence number.

The open question: what should the semantics of repeated in-stage actions be? The worry is that this choice could become an expensive breaking change later.

## What is expensive to change

1. **History (most expensive).** Event types and payload shapes, kept forever; every future engine build must replay old events.
2. **Definition language (medium).** What a definition may say: what conditions can read, what an action can cause. Versioned per definition; a change affects new definition versions, but old versions must keep running while requests on them are open.
3. **Engine internals and UI (cheap).**

## Three candidate models

**D. Data-driven.** A user action is a validated write to the request's data document (who may write which path is declared). The workflow reacts only to what the data now is: transitions and gates are conditions over data.

**E. Event-driven.** A user action is a named event with a payload. The definition declares handlers: "on event X, when condition, do Y" (write data, open a wait, start a call, move stage). The workflow reacts to things happening.

**H. Hybrid (current proposal).** A repeatable person wait: an ordinary close-once wait with outcomes and per-outcome data. When it completes, the engine records `WaitCompleted`, applies the wait's own Set (`DataSet`), and opens the next instance (`WaitOpened`, next sequence number) in the same turn. Rules proposed so far:
- A repeatable wait must have a Set; its results reach the workflow only through data.
- Conditions cannot read a repeatable wait; they read data.
- It is an option, not an obligation; it is excluded from `otherwise` and from the stuck check.
- An admin skip closes the current instance without opening another.
- With `foreach`, each item has its own sequence.
- Transitions stay one-shot per stage entry, so a repeatable wait can change data repeatedly but cannot fire the same transition repeatedly.
- Reactions to each occurrence (for example a notification on every use) belong to consumers of the event stream, not to `decide`.
- Possible later extension: a completion may also open a call.

## The patterns

Each happens inside one stage, typically while approvals or other waits in that stage are in progress.

1. **Checkbox.** Tick, un-tick and re-tick a checklist item; a gate needs all required items ticked.
2. **Field edit.** Edit a text field several times; the latest value is used later.
3. **Question and answer.** An approver asks the requester a question; the requester answers; this can repeat; the approval stays open throughout.
4. **Reassign.** Hand an open task to a different person.
5. **Add a reviewer.** Add (or remove) a reviewer mid-review; the combining rule (all, or n of them) must account for the new set; verdicts already given are kept.
6. **Invalidating edit.** An edit to the substance of the request must dismiss approvals already given and ask for them again.
7. **Work on every occurrence.** Each time an action is used, an external system must be called (not merely notified), and the workflow must know the call's result.
8. **Concurrent edits.** Two people act on the same item at nearly the same time.
9. **Undo within a window / correction.** Someone submitted the wrong value and corrects it; audit must show both.
10. **Derived state.** A value that depends on several in-stage actions (for example "ready when all items ticked AND the answer to the latest question is in AND no edit happened since the last approval").

You may add patterns you think are missing.

## What every reviewer reports, per pattern

- A concrete sketch (definition fragment plus the events recorded) under your assigned model.
- A verdict: **clean**, **awkward** (show the awkwardness), or **cannot** (say what is missing).
- For anything awkward or impossible: the smallest fix, and which layer it touches: history (event type or payload shape), definition language, or internals.

The single most important output: any pattern where a model, or a later switch between models, would require a **history** change beyond what spec v2.4 already records. Be exact about which event or field.

Be calibrated. A criticism you cannot back with a concrete sketch should be dropped or marked as a hunch. Also list what worked without trouble.
===\n./research/instage-test/model-D.md\n===
# Model D (data-driven): paper test

## 1. The design

Close-once waits, transitions and admin turns stay exactly as in v2.4. D adds two things.

**A. Declared writes.** A stage (or the root) declares `writes`:

```
writes:
  <id>: { foreach?: CEL list,            # keyed write; item becomes the key
          path: <data path>, schema: <type>,
          assignees: [...], may: CEL,    # same rules as a person wait (act-time gates apply)
          check: CEL,                    # reads data (before), value, actor, now
          set: { path: CEL },            # derived writes; may read value, actor, now
          conflict: reject | overwrite }
```

- **Declared:** by the block above. A write is available only while its declaring stage is active.
- **Authorised:** membership lookup, `assignees`, `may`, exactly as for a person wait.
- **Validated:** schema, then `check`. A refused attempt writes nothing (attempts log). A write that changes nothing is refused.
- **Recorded:** one new input event:

```
DataWritten { write: (element, activation, key, seq), input, patch, by, evidence }
```

`input` is what the actor sent; `patch` is the resolved patch including derived `set` values (so `now` and counters are recorded, never recomputed). `evolve` applies `patch`. `seq` counts writes per `(element, activation, key)`. With `conflict: reject` the client must name the next `seq`; a stale one is refused.

Then `decide` runs as usual: transitions are level-triggered over data.

**B. Live waits (reconciliation).** `foreach` and a wait's resolved params may be marked `live`. At the end of each turn `decide` compares what the definition now asks for with what is open, and records the difference: `WaitOpened` for a new key; `WaitCancelled{cause: reconciled}` for an open wait whose key left the list; cancel plus `WaitOpened` with the next `seq` for an open wait whose params changed. Completed waits are never touched. This is how data causes waits; without it D cannot do patterns 4, 5 and 7.

Small language additions: `waits.<name>[i].key` readable in CEL; `foreach` on call waits (already reserved).

## 2. The ten patterns

**1. Checkbox: clean.**
```
writes: { tick: { foreach: data.items, path: checks[item], schema: bool,
                  assignees: [group: qa], conflict: reject } }
t_ok: when data.items.all(i, data.checks[i]) && waits.approve.outcome == 'approve' -> Next
```
Events: `DataWritten{(tick,a1,A,1), true}`, later `(…,2) false`, `(…,3) true`; the turn that makes the gate true also carries `TransitionFired t_ok{reads}` and the stage change.
One wart: if the approvals finish first and boxes are still unticked, there is no open obligation, so the stuck check raises a false `Faulted{stuck}`. Fix: a write may declare `role: obligation` and the stuck check counts it while enabled (definition language plus internals; no history). The action-item list then has to read the definition, since no event marks the obligation open.

**2. Field edit: clean.**
`writes: { note: { path: form.note, schema: string, assignees: [user: request.by] } }`. One `DataWritten` per edit; later conditions read `data.form.note`. Publish check needs one rule: a path set only by a write is optional and must be read under `has()`.

**3. Question and answer: clean as data, awkward as a task.**
```
writes:
  ask:    { path: qa[value.id], schema: {id, text}, assignees: <approvers> }
  answer: { foreach: data.qa.keys(), path: qa[item].answer, schema: string,
            assignees: [user: request.by] }
```
Events: `DataWritten ask`, `DataWritten answer`, repeated; the approval wait is untouched. Awkward: the pending answer is not in the requester's action-item list. Fix: a live person wait `answer: person { foreach live: data.qa.keys(), role: obligation, outcomes: {answered: {text}} }`, recorded as `WaitOpened answer[q1]` then `WaitCompleted`. That uses B and no new event, but the answer then lives in the wait, not in data, and cannot be corrected. E does this more directly ("on ask, open a wait").

**4. Reassign: awkward.**
`task: person { assignees live: [user: data.owner] }` plus `writes: { reassign: { path: owner, schema: user } }`.
Events: `DataWritten reassign` · `WaitCancelled task(seq 1){cause: reconciled}` · `WaitOpened task(seq 2){assignees: new}`.
It works and uses the reserved `seq`, but needs B. Without B the only option is `may: actor.id == data.owner` over a broad assignee group, which leaves the action-item list and the new-task notification wrong.

**5. Add a reviewer: awkward.**
```
writes: { reviewers: { path: reviewers, schema: list(user), check: value.size() >= 1 } }
review: person { foreach live: data.reviewers, outcomes: {approve, reject} }
t_ok: when waits.review.filter(w, w.key in data.reviewers && w.outcome == 'approve').size() >= data.quorum
```
Events on add: `DataWritten` · `WaitOpened review[carol]`. On remove: `DataWritten` · `WaitCancelled review[bob]{reconciled}`. Verdicts already given stay because completed waits are untouched; a removed reviewer's verdict is excluded by the `key in` filter. Needs B and `key` in CEL. The filter is easy to forget; a publish warning would help.

**6. Invalidating edit: clean for dismiss-all, awkward for selective.**
```
writes: { edit: { path: form.body, schema: string, set: { rev: data.rev + 1 } } }
t_redo: when data.rev > data.reviewRev  set { reviewRev: data.rev } -> Pending   # self-target
```
Events: `DataWritten{patch: {form.body, rev: 3}}` · `TransitionFired t_redo` · `DataSet{reviewRev: 3}` · `WaitCancelled` per approval (stage exit) · `StageExited` · `StageEntered Pending (a2)` · `WaitOpened…`. No history change at all. One publish-check change: the cycle rule must accept a cycle that passes through a condition on a write-only path. Checklist and answers survive because they are data; read calls run again.
Selective dismissal (only the affected domain): put the revision in the key, `foreach live: data.domains.map(d, d + '@' + string(data.rev[d]))`. It works through B but is a trick, not a statement of intent. E states it directly.

**7. Work on every occurrence: awkward.**
```
writes: { use: { path: uses[value.id], schema: {id, args} } }
sync: call { foreach live: data.uses.keys(), connector: x, op: push,
             args: data.uses[item], effect: write, idempotencyKey: request.id + item }
t_next: when ... && waits.sync.all(w, w.outcome == 'ok')
```
Events: `DataWritten use` · `WaitOpened sync[u7]`; later `WaitCompleted sync[u7] ok`. The workflow knows the result through `waits.sync`. Needs B on call waits. Limits: the result is visible only within the activation (no Set on wait completion), and the occurrence must be turned into a keyed data item first. H's "completion may also open a call" and E's handler are both more direct.

**8. Concurrent edits: clean.**
The per-request lock orders turns. `conflict: reject`: both clients send `seq 4`; the first is recorded, the second is refused with "stale" and shown the new value. `conflict: overwrite`: both recorded, last wins, both in history. Granularity is `(element, key)`, so two people ticking different boxes never collide. H gets the same from its wait `seq`; D copies that deliberately.

**9. Undo / correction: clean.**
A second `DataWritten` on the same path; history shows both with `by` and `at`. A window: `set: { submittedAt: now }` and `check: now - data.submittedAt < duration('10m')` (uses the reserved act-time `now`). After the stage has moved on, correction is an admin turn in every model.

**10. Derived state: clean, with one condition.**
`ready` is one CEL expression over data, optionally named in a `derive:` block (not recorded; `TransitionFired.reads` already records what was read). "No edit since the last approval" has two honest forms: under pattern 6 it is always true inside an activation; otherwise the approval must be a write that stamps the revision (`set: { verdicts[actor.id].rev: data.rev }`), because a `WaitCompleted` cannot write data. That forces a choice per approval between a wait (task list, `otherwise`, stuck check) and a write (stampable, survives re-entry).

**Added 11. Action with no state change ("nudge", "re-run").** D must invent state: `set: { nudges: data.nudges + 1 }`. Works, but it is an event encoded as a counter. E is the natural fit.

**Added 12. Multi-field atomic save.** One write on a subtree with a `check` over the whole object. Clean.

## 3. What worked without trouble

Patterns 1, 2, 8, 9, 10 and 12 need only `DataWritten`. Pattern 6 (dismiss-all) needs no history change. Replay stays a fold. Faulted requests still record writes. Audit of who wrote what is one event per action.

## 4. Where D falls short

- **D alone cannot cause waits.** Four patterns (3 as a task, 4, 5, 7) depend on B, which is a second mechanism with its own cost: `decide` re-evaluates every live list and param each turn.
- **Obligations.** The task list, `otherwise`, the stuck check and the new-task notification all key off wait events. A write is none of these. H as proposed has the same gap (repeatable waits are options); E does not.
- **Occurrences must become data.** Patterns 7 and 11 work only by keying or counting. If many such patterns are expected, E is the better base.
- **Root-level repeats.** A root transition is one-shot, so "every time X changes, do Y at request level" is reachable only through live waits.
- **Discoverability.** H records each available action as `WaitOpened`, so the UI, notifier and admin skip work from history. In D, availability is implicit in the definition.
- **Selective effects** (pattern 6 per domain) are encodings. Hunch, not shown: authors will get the key trick wrong.

## 5. History changes beyond v2.4

1. **New input event** `DataWritten { write: (element, activation, key, seq), input, patch, by, evidence }`. Required.
2. **`WaitCancelled.cause`** gains `reconciled`. Required for patterns 4, 5, 7. I believe H and E need the same value for 4 and 5.
3. **`Overridden.actions`** gains "disable a write for this request" if parity with H's admin skip is wanted. Optional.
4. **`DataSet.patch` / `DataWritten.patch` format must be pinned now**: keyed-map set and remove, no array positions. v2.4 does not define it. All models need this; D depends on it most.
5. Observation about H: its wait Set needs `DataSet.source` to gain `wait`; v2.4 lists only start, transition, admin.

Nothing else changes: `WaitOpened`, `WaitCompleted`, `TransitionFired`, the envelope and the reserved `seq` are used as they are.

## 6. Switching cost

No direction requires rewriting old events. The cost is always "carry two encodings forever".

**D then H.**
- History: add `DataSet.source: wait`; `DataWritten` stays foldable forever. Because `DataWritten.write` is wait-shaped with a `seq`, each one is information-equivalent to H's triple (`WaitCompleted`, `DataSet`, `WaitOpened seq+1`), so projections can present one model.
- Language: a D write is a repeatable wait with one outcome whose Set copies its data, so old definitions translate mechanically; the `writes` block must still run for open requests.
- Internals: the instance lifecycle and admin skip.

**D then E.**
- History: additive but larger. A named-event input (or reuse `DataWritten` with `input` as payload), a decision event for a handler firing with its `reads`, `DataSet.source: handler`.
- Language: the expensive part. Edge-triggered handlers beside level-triggered transitions; the coverage and cycle publish checks must be redone.
- Internals: dispatch inside `decide`.

**H then D.**
- History: nothing. `writes` can be definition sugar that compiles to a single-outcome repeatable wait.
- Language: add `writes` and, if wanted, B.
- Internals: the compiler, and optionally hiding the per-write `WaitOpened`.

So H then D is the cheapest switch and D then H the next. The asymmetry is one event type. If the team wants D's authoring model with the least history risk, ship D's `writes` syntax over H's events and accept three events per write instead of one.
===\n./research/instage-test/adversary.md\n===
# Adversary report: "the v2.4 history is neutral between D, E and H"

## Verdict

The claim holds in its strong, important sense and fails on its letter.

- **Holds:** I found no scenario where an old history becomes unreplayable or has to be reinterpreted under a later D or E engine. `evolve` folds explicit events and never reads the definition, so a new model only changes how `decide` produces events. Because H forces every in-stage result into data via `DataSet`, both a D reader ("the write is the fact") and an E reader ("the WaitCompleted is the fact, the DataSet is its effect") find what they need.
- **Fails on the letter:** "no event type or payload shape would need to change" is false in three places, and "linked by the turn" is false on the fault path. All are fixable now with small additions. None needs a new event type.

Everything I propose is one new optional field, one widened field, or one written rule. Later changes that are purely additive (a new optional field, a new event type) I do not count as breaks, but note that old events never gain the missing information.

## Findings

### 1. `DataSet.source` is a closed three-value enum with no element reference. BREAKS (letter)

Spec section 5: `source: start, transition or admin`; section 2: Set writes "only on a transition, on start, or by an admin". The hybrid's own wait-Set already needs a fourth value, so the claim is false the day H ships. Further values are foreseeable: a call wait's Set (pattern 7, result written back), a materialised derived value under D (pattern 10), a handler under E.

Scenario for the missing reference: under E, one "edit submitted" event runs two handlers, each writing data. History shows two `DataSet{source: ?}` in one turn with nothing saying which rule wrote which. Under H today the same arises when a wait-Set and a transition-Set land in one turn; order relative to `TransitionFired` disambiguates, but only by convention.

**Add now:** `DataSet {patch, source, element?}` where `source` is declared an open enum (`start | transition | admin | wait`, more may follow) and `element` is the stable ID of the transition or wait whose Set produced the patch (absent for start and admin). This also gives E its "handler identity" without a new event type.

### 2. "Linked by the turn" fails when `decide` is deferred or rolled back. CHEAP INSURANCE

Section 3: on a CEL error the turn's decisions are rolled back and the input is kept; a faulted request "still accepts and records inputs but runs no decide until an admin turn clears the fault; then decide runs for the kept inputs in order."

Scenario: request is faulted. Cara ticks item A (`WaitCompleted` seq 40), Dev edits the title (`WaitCompleted` seq 41). No `DataSet`, no next instance. Admin clears the fault at seq 42; `decide` now emits two `DataSet` events. If their `turn` is 42, the action-to-effect link the claim rests on is gone: two writes, both attributed to the admin's turn, matched to 40 and 41 only by order. The same happens if the wait's own Set expression errors.

**Add now (rule, no field):** `turn` is the seq of the input whose consequences these are, not the transaction's first event. Consequences of a kept input that are produced in a later admin turn carry the kept input's seq. Add a test case. With finding 1's `element` this makes the pair recoverable in every path.

Side effect to note (behaviour, not history): while faulted, a repeatable wait accepts one input and then is closed with no successor, so "still accepts inputs" is not true for it. Decide whether the wait-Set and reopen are part of the input step or of `decide`.

### 3. `seq` is defined only for "complete, then next". Three foreseeable uses contradict that. CHEAP INSURANCE

Section 8 says only: a second instance "takes the next seq". The brief's reading is one open instance at a time, successor opened on completion. But:

- **Reassign (pattern 4) and remove/add reviewer (5).** Assignees are resolved and recorded in `WaitOpened`; a later `DataSet` cannot change an open wait. Without a new event type the only encoding is `WaitCancelled` + `WaitOpened seq+1` with new params. That is a seq 2 whose seq 1 was never completed, in a wait that is not "repeatable".
- **Invalidating edit (6) without full stage re-entry.** A completed approval is reopened by a decision, not by the approver repeating it.
- **Call per occurrence (7).** Three quick uses open three call instances that are all in flight at once: several open instances of one (element, activation, key).

If consumers or `evolve` assume "at most one open instance" or "seq n-1 is completed when n opens", the first of these redefines seq.

**Add now (rules):** (a) `seq` is an ordinal, unique within (element, activation, key), assigned in open order, for any cause; it restarts at 1 in a new activation. (b) Nothing in `evolve` or in stream consumers may assume a single open instance or that the predecessor is `completed`. (c) Which instance `waits.<name>` reads is a definition-language matter. (d) The default idempotency key for a write call ("per request") must include seq for a repeated call, or every occurrence dedupes into the first; it is recorded in `WaitOpened`, so this is a rule, not a shape.

### 4. `WaitCancelled.cause` (and other enums) are closed. BREAKS (letter), trivially

`cause: stage exit or request closed`. Reassign, reviewer removal, a foreach list re-evaluated under D, and a conditionally open wait under E ("open the answer task when a question exists") all cancel a wait for another reason. Any model needs this for patterns 4 and 5.

**Add now (rule):** every payload enum (`DataSet.source`, `WaitCancelled.cause`, `WaitOpened.kind`, `StageExited.mode`, `Faulted.kind`) is open; `evolve` depends only on event type, IDs and patch; consumers must tolerate unknown values. Reserve `cause: replaced` now.

### 5. `patch` is not specified. BREAKS (letter) for list-shaped data

The only evidence of the format is the test files: a map of top-level key to whole value. Nothing says whether nested paths are allowed, whether a value replaces or merges, how a key is removed (matters for `requires`, which tests existence), or how a list grows.

Scenario: Q&A thread or comments (pattern 3). Each action appends one entry to `data.thread`. With whole-value replacement each `DataSet` re-records the whole list: history grows quadratically, and a D-reader cannot tell "appended one entry" from "rewrote the thread". Same for add-a-reviewer on a list. Two people appending concurrently is safe only because the engine recomputes the list under the lock; the patch itself says nothing.

**Add now:** define patch as an ordered list of `{op: set | remove, path, value}`; `set` replaces the whole value at `path`; a path may address a nested key and a not-yet-existing map key; no merge semantics ever. Recommend (definition guidance) that growing collections are maps keyed by a stable ID, which makes append, edit-one and remove-one all plain `set`/`remove` and avoids a list-operation vocabulary. Old top-level-map patches upcast mechanically.

### 6. Conflict evidence: what the writer had seen. CHEAP INSURANCE

The lock serialises turns, and naming `seq` in the input gives a free stale-write rejection per wait instance (the refused attempt goes to the attempts log). But where the definition chooses last-write-wins, or where two different waits or a transition write the same path, history shows two writes in order and nothing about whether the second writer had seen the first. A D model treats that as core; an auditor asking "did Dev overwrite Cara knowingly?" cannot answer.

**Add now:** optional `basis` on `WaitCompleted` and `Overridden`: the request history seq the actor's client had rendered. Not used by `decide` in H. It is additive later too, but all histories written before then lack it for good.

### 7. Principal type in `by`. CHEAP INSURANCE (minor)

`by` is "the ID of the person or connector"; section 8 also mentions "a system identity". An inbound integration write (CI result pushed, not polled) fits as a completion of a standing wait by a connector, but only if a reader can tell the kinds apart without an ID-format convention. **Add now:** `by` is `{type: user | connector | system, id}` everywhere it appears.

### 8. Ordering of the reopen. CHEAP INSURANCE (rule)

If the completion also enables a transition out of the stage, the brief's order yields `WaitOpened seq+1` then `WaitCancelled seq+1` in one turn, and notification rules on `WaitOpened` fire for a wait that never existed for the user. **Rule:** the successor is opened as the last step of the turn, only if its activation is still active. Extend the section 3 order accordingly.

## Attacks that failed (NOT A PROBLEM)

- **A write with no wait behind it (pure D).** Expressible as a standing option wait synthesised by the definition compiler, on the root stage if it must outlive stages. Cost is noise (three events per write), not shape. A later dedicated input event would be additive.
- **An event no wait solicited (pure E).** Same answer: a standing option wait. A late or post-close signal is refused to the attempts log; a `CallResultLate` analogue would be additive.
- **Previous value; which fields actually changed; intent versus side effect.** Previous state is the fold up to seq-1; changed fields are the diff; intent is `WaitCompleted.data`, effect is `DataSet`, and with findings 1 and 2 a side effect is distinguishable from a direct write.
- **One event, several effects; effect later than the turn.** Several decision events per turn already exist. A later effect is a call wait whose own completion writes data; correlation is by turn and seq.
- **Re-entry.** New activation, seq restarts, data survives. H's "results only through data" rule is exactly what keeps earlier activations from mattering.
- **Admin corrections and undo.** A correction is another completion or `DataSet{source: admin}`; both values stay in history. Reopening after an admin skip is a new action inside `Overridden.actions`, additive.
- **foreach.** Key and per-key seq are in the wait ID; a dynamic list needs only finding 3 and 4.
- **Per-path write permission, undo windows, derived state, obligation-or-option for repeatables.** Definition language and act-time gates; `role` and `evidence` are already recorded per instance.
- **Drafts, mentions, watchers, attachments, bulk actions.** Drafts are outside history; mentions and watchers are notifier concerns or data; attachments are references in data; a bulk correlation ID is additive. Comments force finding 5 and nothing else.

## Hunches, not backed by a scenario

- Recording every payload twice (`WaitCompleted.data` and `DataSet.patch`) doubles the surface for the personal-data erasure problem that section 10 sets aside.
- A reader cannot tell from `WaitOpened` alone that a wait is repeatable; nothing I tried needed it.
===\n./research/instage-test/model-H.md\n===
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
===\n./research/instage-test/model-E.md\n===
# Model E (event-driven): paper test against kernel spec v2.4

## Summary

- The best E I can build keeps H's history shape (an occurrence is a `WaitCompleted` on a repeatable wait, then `WaitOpened` at the next `seq`) and differs from H only in what a completion may cause.
- History additions E needs beyond v2.4: one enum value on `DataSet.source`, one enum value on `WaitCancelled.cause`, and one new decision event `HandlerRan` (needed for audit, not for replay). No input event changes.
- E is clearly better than H and D on patterns 3, 4, 5, 6, 7 and an added pattern 11 (repeatable stage move). It is no better than H on 1, 2, 8, 9, and worse than D on 10.
- Switching E to H or D costs no history change. Switching H to E costs none either, provided three cheap rules are fixed now (last section).

## The model

**Declaring and authorising an event.** An event is not a free-floating message. It is an outcome of a *repeatable person wait* (`role: option`, `repeat: true`) declared on a stage, with the usual `assignees`, `may` (later: act-time gates) and per-outcome schema. Entering the stage opens instance `seq 1`. So every inbound fact still closes a wait the engine opened, and authorisation, evidence and the attempts log are unchanged. Completions of ordinary waits (approvals, calls) are events too.

**Handlers.** `on <wait>.<outcome>: [{id, when, do}]`, declared on the stage. `when` reads `data`, `request`, waits in scope and `event` = `{outcome, data, by, seq, at}`. `do` is a list of:

| Effect | Recorded as |
|---|---|
| `set {path: CEL}` | `DataSet {source: wait}` |
| `open <wait>[key]` (a wait declared `opened: by handler`) | `WaitOpened` |
| `call <wait>[key]` | `WaitOpened` kind call |
| `reopen <wait>` (re-resolves params; next `seq`) | `WaitCancelled {cause: handler}` if still open, then `WaitOpened` |
| `cancel <wait>[key]` (open instances only) | `WaitCancelled {cause: handler}` |
| `fire <transition>` (last effect only) | ordinary `TransitionFired` and stage events |

**Turn order.** (1) Validate and append the input. (2) Run that wait's handlers in declared order; each `when` sees the effects of the previous handler; each one that runs appends `HandlerRan {handler, activation, trigger: wait ID, reads}` followed by its effects. (3) If the stage is still active, open the next instance of the repeatable wait. (4) Level-triggered transitions to a fixed point, as today. (5) Stuck check.

**Coexistence rules.**
- Handlers are the only edge-triggered part. They produce recorded state only; transitions read recorded state only. Conditions cannot read a repeatable wait.
- A handler cannot emit an event. Anything it opens completes in a later turn, so there is no handler cascade and no new loop limit.
- For every wait, the instance with the highest `seq` per `(element, activation, key)` is the current one in `waits.<name>` and in `evolve`.
- A handler CEL error is an ordinary fault: decisions rolled back, input kept. On clear, handlers run per kept input in order (spec section 3 already says so). While faulted, the next instance is not open, so the action is unavailable.
- An admin `DataSet` runs no handler. An admin skip closes the instance without reopening.
- Repeatable waits are excluded from `otherwise` and the stuck check; handler-opened obligations are included.

## Patterns

**1. Checkbox: clean (same as H).**
```
tick: person { repeat, role: option, outcomes: { set: { id: string, on: bool } } }
on tick.set: [{ id: h_tick, do: [ set { checks[event.data.id]: event.data.on } ] }]
t_go: when data.required.all(i, data.checks[i]) && ...
```
`WaitCompleted tick#3 {a, false}` · `HandlerRan h_tick` · `DataSet` · `WaitOpened tick#4`. The handler adds nothing over H's wait Set. D says it most directly.

**2. Field edit: clean (same as H).** Same shape with `set { form.title: event.data.value }`. Later stages read data.

**3. Question and answer: clean, better than H.**
```
ask:    person { repeat, role: option, assignees: approvers, outcomes: { ask: { text } } }
answer: person { opened: by handler, role: obligation, assignees: [user: request.by], outcomes: { reply: { text } } }
on ask.ask:      [ set { q[event.seq]: event.data.text }, open answer[event.seq] ]
on answer.reply: [ set { a[key]: event.data.text } ]
```
`WaitCompleted ask#1` · `HandlerRan` · `DataSet` · `WaitOpened answer[1]#1` · `WaitOpened ask#2`. The approval is untouched. The answer is a real obligation in the requester's action list, tied to its question by key. Under H the answer can only be a standing option, matched to the question through data.

**4. Reassign: clean in language; needs a history enum value.**
```
on reassign.to: [ set { engLead: event.data.user }, reopen release ]
```
`WaitCompleted reassign#1` · `HandlerRan` · `DataSet` · `WaitCancelled release#1 {cause: handler}` · `WaitOpened release#2 {assignees: new}`. **History:** `WaitCancelled.cause` gains a value (v2.4 allows only stage exit or request closed). H cannot do this with a Set alone, because assignees are recorded at open. Any model that reassigns needs the same value.

**5. Add a reviewer: clean for add; remove is awkward.**
```
on addReviewer.add: [{ when: !(event.data.user in data.reviewers),
                       do: [ set { reviewers: data.reviewers + [event.data.user] }, open reviews[event.data.user] ] }]
t_ok: when waits.reviews.filter(w, w.key in data.reviewers).all(w, w.outcome == 'approve')
```
`WaitOpened reviews[u]#1` uses the existing shape; given verdicts are untouched. Removing a reviewer whose wait is open is `cancel` (same enum value as pattern 4). Removing one who already gave a verdict cannot cancel a completed wait, so the rule must filter by `data.reviewers`. Fix: expose `w.key` in CEL and drop handler-cancelled instances from the list (definition language).

**6. Invalidating edit: clean, E's best case.**
```
on edit.save: [{ id: h_save,  do: [ set { form[event.data.field]: event.data.value } ] },
               { id: h_reset, when: event.data.field in substantive, do: [ reopen primary, reopen others ] }]
```
`WaitCompleted edit#2` · `HandlerRan h_save` · `DataSet` · `HandlerRan h_reset` · `WaitOpened primary#2` · `WaitOpened others[B]#2` · `WaitOpened edit#3`. `waits.primary` now reads instance 2 (open); instance 1 stays in history as the dismissed verdict. No new event, but it depends on the highest-`seq` rule. H and D can only do this with a self-transition on a data revision, which resets every wait in the stage.

**7. Work on every occurrence: clean.**
```
on publish.go: [ call sync[event.seq] { connector: cms, op: push, effect: write, args: ..., idempotencyKey: request.id + '/' + event.seq } ]
on sync.failed: [ set { syncFailed: data.syncFailed + [key] } ]
```
`WaitOpened sync[4]#1` with the key in resolved params; later `WaitCompleted sync[4] ok {data}` · `HandlerRan` · `DataSet`. An open call counts in the stuck check. This is H's "possible later extension", built in. D is awkward: it must infer occurrences from data changes, and two identical writes look like none. Limit: if the stage exits first, the result is `CallResultLate` and no handler sees it (the existing publish warning covers this).

**8. Concurrent edits: clean (same as H).** The per-request lock orders the two. Both name `tick#3`; the first completes it and opens `#4`; the second is rejected to the attempts log and the client retries. The `seq` is an optimistic-concurrency token for free. Where both should succeed (two different checklist items), give each item its own key with `foreach`, or declare `conflict: latest` so the engine resolves the current instance at act time. Definition language and internals only.

**9. Undo and correction: clean; the window is awkward.** A correction is another occurrence: `amount#1 {500}` and `amount#2 {50}` are both in history with both `DataSet` patches. Retracting a close-once verdict is `on retract.go: [ reopen primary ]`. A time window needs the submit time in data; CEL has no clock. Fix: let handlers read `event.at` (the recorded envelope time, so deterministic) and compare it to `now` in an act-time gate. Definition language only. After the transition has fired, correction is an admin turn, as today.

**10. Derived state: awkward; D is better.** Handlers can maintain a `ready` flag, but every handler must remember to update it and an admin `DataSet` bypasses them all, so the flag drifts silently. The workable discipline is: handlers record facts, conditions derive.
```
t_go: when data.required.all(i, data.checks[i])
        && !waits.answer.exists(w, w.status == 'open')
        && waits.primary.outcome == 'approve'      # pattern 6 makes "no edit since approval" structural
```
That is model D's style inside E, and nothing enforces it. Fix: named derived expressions (`let ready = ...`) and a publish warning when a handler sets a path that is computable from other data. Definition language.

**11 (added). Repeatable stage move: clean; H and D cannot.** "Send back for rework", used several times from the root: `on sendBack.go: [ fire t_rework ]`. It records an ordinary `TransitionFired`; the one-shot rule applies only to level-triggered firing. H's rules forbid this outright.

## Where E falls short

- **State depends on order, not only on data.** Reordering handlers, or moving an open request to a new definition version, does not re-derive anything. Under D, changing a condition changes the answer immediately.
- **Publish checks weaken.** A path set only by a handler may never be set, so "set on every path" fails unless such paths have defaults. Outcome coverage over handler-opened waits is over a set unknown at publish time.
- **Admin repair is thinner.** Setting data does not replay a handler's `open` or `reopen`. `Overridden.actions` would need "open wait" and "reopen wait" kinds (an additive payload change). Hunch: this will be wanted within the first year.
- **More language surface than H.** Six effects against one. For patterns 1, 2, 8 and 9 that surface buys nothing.
- **Recommendation as E's advocate:** ship H's rules as the first cut of E's history, and add handlers when pattern 3, 4, 6 or 7 is actually needed.

## History changes beyond v2.4

| Change | Needed for | Needed by H or D too? |
|---|---|---|
| `DataSet.source` gains `wait` | every pattern | H yes; D yes |
| `WaitCancelled.cause` gains `handler` | 4, 5 (remove) | Any model doing reassign |
| New decision event `HandlerRan {handler, activation, trigger, reads}` | Audit of which handler ran and why; `evolve` ignores it | No |
| `WaitOpened` with `seq > 1` on non-repeatable waits | 4, 6, 9 | Same shape; semantics only |

No change to any input event. `WaitCompleted` already carries the wait ID with `seq`.

## Switching cost

**Shipped E, want H.** History: none; H's events are a subset. Language: remove `on` blocks from new definition versions; a wait's own Set is one unguarded `set` handler. Internals: the handler interpreter stays until requests on old versions close.

**Shipped E, want D.** History: none if a write is a completion of a repeatable wait whose data is the patch. A dedicated input event for raw writes (for example `DataWritten {patch, by, evidence}`) would be new under any starting point, and would break the rule that every input closes a wait. Language: add per-path write permissions; re-express `reopen`, `open` and `call` as reactions to data, which is the hard part (pattern 7). Internals: cheap.

**Shipped H, want E.** History: add `HandlerRan` and the `cause` value, both additive with no upcast. Language: additive; H's rule "results reach the workflow only through data" loosens to "through data or through waits a handler opens". Internals: a handler phase before the transition loop.

This switch is cheap only if three things are fixed in H now:
1. `evolve` and CEL treat the highest `seq` per `(element, activation, key)` as the current instance for every wait kind, not only repeatable ones.
2. `DataSet.source` and `WaitCancelled.cause` are open enums that old builds tolerate.
3. H's wait Set is evaluated per kept input, in order, when a fault clears.

If H's `evolve` assumes a close-once wait always has `seq 1`, patterns 4 and 6 become a replay change later. That is the one expensive trap I found.
===\n./composites/composites.md\n===
# Composites (first release)

A composite is something a workflow author configures. It is code in the repository, has a version, and expands into kernel parts when a definition is published. The engine never sees a composite, only its expansion. The rules every composite must follow (derived element IDs, recorded name, version and parameters, a version bump on any expansion change) are in `kernel/kernel-spec.md`, section 7.

Below, `x` is the instance ID the author gives. Element IDs are `x.<local name>`, prefixed with the stage in the published definition.

## Approval (kind: approval)

| Parameter | Default | Meaning |
|---|---|---|
| `group` | required | The approver group. With `over`, an expression that reads `item`. |
| `over` | none | A list. One approval per item. |
| `approveData` | `{}` | Schema of the data an approver must give to approve. |
| `allowRequester` | false | Whether the requester may decide. |
| `outcomes` | approve, reject | Outcome names. |
| `optional` | false | The decision is recorded but nothing has to wait for it. |
| `notify` | false | Only for an optional approval: tell the assignees when it opens. |

Expands to:

- `x.decision`: a person wait. Assignees are the group. `may: actor != request.by` unless `allowRequester`. Outcomes are approve (with `approveData`) and reject (with a reason). `role: obligation`, or `option` when `optional`. With `over`, `foreach` over the list.
- `x.members`: a directory `membersOf` read for the group, or for every item's group with `over`. Declared `onFailure: outcome`, because the check is advisory: a failed lookup must not stop the request, and the `noApprover` rule reports it. Not emitted when `optional`.
- Rule `x.noApprover`: on `WaitCompleted x.members`, alert the workflow admins when the call failed or a group has nobody able to approve. Not emitted when `optional`.
- Rule `x.notify`: on `WaitOpened x.decision`, tell the assignees. Emitted only when `optional` and `notify`.

Exposes to the workflow's transitions:

- `x.approved`: the decision is approve. With `over`: every item is approved (true for an empty list).
- `x.rejected`: the decision is reject. With `over`: any item is rejected.
- `x.data`: the approve data (not with `over`).

An approval owns no transition. The workflow decides what approved and rejected do, and a workflow may simply not read them.

## Task (kind: task)

| Parameter | Default | Meaning |
|---|---|---|
| `assignee` | required | A user or group. |
| `outcomes` | done | Outcome names. |
| `doneData` | `{}` | Schema of the data given on completion. |

Expands to `x.task`: one person wait, `role: obligation`.

## Default notification rule

Every definition gets the rule `n_task`: on `WaitOpened`, when the wait is a person wait with `role: obligation`, tell the assignees. It is not a composite.

## Example composite: DomainApprovals (kind: approval)

Built as a worked example of how to write a composite. It is a fork of Approval for a primary group plus other groups. When a workflow needs something Approval's parameters do not cover, fork it; do not add parameters. Forks declare the same `kind`, so pages and reports treat them alike. The change request does not use this composite in the first release.

- Parameters: `primaryGroup`; `otherGroups` (a list); `primaryApproveData`; `allowRequester` (default false); `outcomes`.
- Expands to: `x.members` (one directory call for all the groups), `x.primary` (the primary's person wait), `x.others` (one person wait per other group), and one rule `x.noApprover`.
- Exposes `x.approved` and `x.rejected`, as Approval does.
- Compared with two Approval instances, it makes one directory call and sends one alert per request.
===\n./design-doc.html\n===
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Workflow Platform Design</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
/* Layout idea: one reading column with a sticky section list on wide screens; tables and diagrams carry the structure. */
:root {
  --bg: #f5f6f8; --surface: #ffffff; --ink: #1b2330; --muted: #5d6878; --line: #d9dee6;
  --accent: #2357c6; --accent-soft: #e7eefc;
  --good: #1f7a4d; --good-soft: #e3f3ea; --warn: #9a6200; --warn-soft: #fbf0d9; --later: #6b4fbb; --later-soft: #f0ebfb;
  --font-body: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  --font-mono: "IBM Plex Mono", ui-monospace, Consolas, monospace;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #12161d; --surface: #1a2029; --ink: #e6eaf0; --muted: #9aa5b5; --line: #2e3744;
    --accent: #7aa2f7; --accent-soft: #1f2a44;
    --good: #5cc98f; --good-soft: #17302a; --warn: #e5b45a; --warn-soft: #362b14; --later: #b9a3f5; --later-soft: #2a2340;
    color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --bg: #12161d; --surface: #1a2029; --ink: #e6eaf0; --muted: #9aa5b5; --line: #2e3744;
  --accent: #7aa2f7; --accent-soft: #1f2a44;
  --good: #5cc98f; --good-soft: #17302a; --warn: #e5b45a; --warn-soft: #362b14; --later: #b9a3f5; --later-soft: #2a2340;
  color-scheme: dark;
}
* { box-sizing: border-box; }
html, body { margin: 0; }
body { background: var(--bg); color: var(--ink); font: 15px/1.6 var(--font-body); }
a { color: var(--accent); }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
code, pre { font-family: var(--font-mono); font-size: 13px; }
code { background: var(--accent-soft); padding: 0 4px; border-radius: 4px; }
pre { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; overflow-x: auto; line-height: 1.5; }
pre code { background: none; padding: 0; }

.wrap { display: grid; grid-template-columns: 220px minmax(0, 1fr); gap: 32px; max-width: 1120px; margin: 0 auto; padding: 32px 24px 64px; }
nav.toc { position: sticky; top: 24px; align-self: start; font-size: 13.5px; }
nav.toc ol { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
nav.toc a { color: var(--muted); text-decoration: none; display: block; padding: 2px 0; }
nav.toc a:hover { color: var(--accent); }
nav.toc .t { font-weight: 600; color: var(--ink); margin-bottom: 8px; }
@media (max-width: 860px) { .wrap { grid-template-columns: 1fr; padding: 20px 16px 48px; } nav.toc { position: static; } }

main { min-width: 0; }
header.doc h1 { font-size: 28px; font-weight: 600; margin: 0 0 6px; text-wrap: balance; }
header.doc p { margin: 0; color: var(--muted); }
.meta { display: flex; flex-wrap: wrap; gap: 8px; margin: 14px 0 0; }
.pill { display: inline-block; border-radius: 999px; padding: 1px 10px; font-size: 12.5px; font-weight: 500; white-space: nowrap; }
.pill.mvp { background: var(--good-soft); color: var(--good); }
.pill.later { background: var(--later-soft); color: var(--later); }
.pill.open { background: var(--warn-soft); color: var(--warn); }
.pill.plain { border: 1px solid var(--line); color: var(--muted); }

section { margin-top: 40px; }
h2 { font-size: 20px; font-weight: 600; margin: 0 0 10px; padding-top: 8px; border-top: 1px solid var(--line); text-wrap: balance; }
h3 { font-size: 15.5px; font-weight: 600; margin: 22px 0 6px; }
p, ul, ol { max-width: 72ch; }
ul, ol { padding-left: 20px; }
li { margin: 3px 0; }
.lead { font-size: 16.5px; }
.tablewrap { overflow-x: auto; margin: 12px 0; }
table { border-collapse: collapse; width: 100%; font-size: 14px; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; }
th, td { text-align: left; vertical-align: top; padding: 8px 10px; border-bottom: 1px solid var(--line); }
th { font-weight: 600; font-size: 13px; color: var(--muted); }
tr:last-child td { border-bottom: 0; }
td.n { font-variant-numeric: tabular-nums; white-space: nowrap; }
.note { background: var(--surface); border: 1px solid var(--line); border-left: 3px solid var(--accent); border-radius: 6px; padding: 10px 14px; margin: 12px 0; max-width: 72ch; }

/* diagrams */
.diagram { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 16px; overflow-x: auto; margin: 12px 0; }
.boxes { display: grid; gap: 12px; min-width: 620px; }
.row { display: grid; gap: 12px; }
.row.c3 { grid-template-columns: repeat(3, 1fr); }
.row.c4 { grid-template-columns: repeat(4, 1fr); }
.box { border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; font-size: 13.5px; }
.box b { display: block; font-size: 14px; }
.box span { color: var(--muted); }
.box.core { border: 2px solid var(--accent); background: var(--accent-soft); }
.box.ext { border-style: dashed; }
.cap { font-size: 12.5px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; margin: 4px 0 -4px; }
.flow { display: flex; align-items: stretch; gap: 0; min-width: 620px; }
.flow .st { flex: 1; border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; font-size: 13.5px; }
.flow .st.final { border-style: dashed; }
.flow .st b { display: block; font-size: 14.5px; }
.flow .st span { color: var(--muted); }
.flow .ar { align-self: center; padding: 0 8px; color: var(--muted); font-size: 12.5px; white-space: nowrap; text-align: center; }
.flow .ar::after { content: "→"; display: block; font-size: 18px; line-height: 1; }
dl.gloss { display: grid; grid-template-columns: 190px 1fr; gap: 6px 16px; max-width: 86ch; }
dl.gloss dt { font-weight: 600; }
dl.gloss dd { margin: 0; }
@media (max-width: 600px) { dl.gloss { grid-template-columns: 1fr; } dl.gloss dd { margin-bottom: 8px; } }
</style>
</head>
<body>
<div class="wrap">
<nav class="toc" aria-label="Sections">
  <div class="t">Sections</div>
  <ol>
    <li><a href="#summary">1. Summary</a></li>
    <li><a href="#scope">2. Scope</a></li>
    <li><a href="#architecture">3. Architecture</a></li>
    <li><a href="#kernel">4. The kernel</a></li>
    <li><a href="#change-request">5. The change request</a></li>
    <li><a href="#people">6. People and permissions</a></li>
    <li><a href="#definitions">7. Definitions and versions</a></li>
    <li><a href="#integrations">8. Integrations</a></li>
    <li><a href="#data">9. Data model</a></li>
    <li><a href="#operations">10. Operations and cutover</a></li>
    <li><a href="#plan">11. Plan</a></li>
    <li><a href="#later">12. Later features</a></li>
    <li><a href="#decisions">13. Decisions</a></li>
    <li><a href="#open">14. Open questions</a></li>
    <li><a href="#glossary">15. Glossary</a></li>
  </ol>
</nav>

<main>
<header class="doc">
  <h1>Workflow Platform Design</h1>
  <p>Version 3. Covers the first release and what it must leave room for.</p>
  <div class="meta">
    <span class="pill mvp">MVP: change request</span>
    <span class="pill plain">Next.js · Node · Postgres</span>
    <span class="pill plain">Kernel spec v2.9</span>
  </div>
</header>

<section id="summary">
  <h2>1. Summary</h2>
  <p class="lead">We are rebuilding the Change Management intake as the first workflow on a small, generic workflow engine. The first release ships only that workflow, at parity with the existing product, with the workflow part made configurable.</p>
  <ul>
    <li><strong>The engine runs a small kernel:</strong> stages, transitions, waits and data writes. Everything an owner configures, such as an approval, expands into those parts.</li>
    <li><strong>Each request has an append-only history,</strong> kept forever, that is the source of truth. The engine records its decisions as events, so replaying a history never re-runs workflow logic.</li>
    <li><strong>Definitions are data,</strong> published through an API. A request stays on the version it started on.</li>
    <li><strong>Later workflows shaped the permanent parts</strong> (event shapes and IDs) but are not built. Five more use cases are recorded in the use cases doc.</li>
  </ul>
  <div class="note">
    This doc is the overview. The reference material lives in the <code>workflow-platform</code> folder:
    each level referring only to the ones before it. <code>kernel/</code> holds the engine: <code>kernel-spec.md</code> (the rules, in full), <code>expansion-battery.md</code> (workflows expanded on paper to test the kernel) and <code>replay-only.yaml</code>. <code>composites/composites.md</code> describes the composites. <code>workflows/change-request/</code> holds the change request's definition and its test cases. <code>research/</code> keeps the reports from test rounds. Version 2.1 of this doc, with the earlier design and the detail for later use cases, is in this page's version history.
  </div>
</section>

<section id="scope">
  <h2>2. Scope</h2>
  <div class="tablewrap"><table>
    <thead><tr><th>In the first release</th><th>Not in the first release</th></tr></thead>
    <tbody>
      <tr><td>The change request workflow, at parity with the existing product (with intentional exceptions where it is bad)</td><td>The five later use cases: tech debt initiatives, architecture review, metrics recertification, domain routing with Jira, metadata changes</td></tr>
      <tr><td>Three approval paths, chosen by primary domain: all domains approve (the platform domain), the primary domain alone decides, or no approval (one domain)</td><td>Updating a request in flight to a newer definition (migrations)</td></tr>
      <tr><td>Publishing a definition through the API and an admin page that accepts JSON</td><td>A visual workflow editor, and composites beyond Approval and Task</td></tr>
      <tr><td>Admin override and break-glass access</td><td>Timers, child requests, date-triggered starts</td></tr>
      <tr><td>Notifications through the existing email and Slack service</td><td>Attachments (no file storage yet)</td></tr>
      <tr><td>The form renderer for the intake form</td><td>Importing legacy requests</td></tr>
    </tbody>
  </table></div>
  <p>Scale is small: about one request every 10 seconds at most, across all future apps. Simplicity and correctness matter more than throughput.</p>
  <h3>Why build</h3>
  <p>The existing Change Management product is ours; this is its refactor. No product we reviewed covers the fixed needs without adding a JVM or a cluster to run: definitions as data published without a deployment, a permanent audit history as the source of truth, authorization checked when a person acts, and admin overrides recorded as skipped. Open-source BPMN engines (Operaton, Flowable) come closest and would still leave those four to build. Durable-execution engines (Temporal and similar) define workflows in code and do not keep history forever.</p>
</section>

<section id="architecture">
  <h2>3. Architecture</h2>
  <div class="diagram">
    <div class="boxes">
      <div class="cap">Our app</div>
      <div class="row c3">
        <div class="box"><b>Change Management pages</b><span>Request list, request page, my action items, intake form. Uses the company component library.</span></div>
        <div class="box"><b>Admin pages</b><span>Publish a definition (JSON), inspect a request's history, override.</span></div>
        <div class="box core"><b>Engine API</b><span>Start, act, admin turn, publish. One transaction per input.</span></div>
      </div>
      <div class="cap">Background workers</div>
      <div class="row c3">
        <div class="box"><b>Call dispatcher</b><span>Delivers pending calls at least once; a reconciler re-queues stalled ones.</span></div>
        <div class="box"><b>Notifier</b><span>Reads committed events in order and applies the definition's notification rules.</span></div>
        <div class="box"><b>Projection</b><span>Keeps the request table and action-item lists up to date from events.</span></div>
      </div>
      <div class="cap">Storage and outside systems</div>
      <div class="row c3">
        <div class="box core"><b>Postgres</b><span>Events, definitions, request table, pending calls, attempts log.</span></div>
        <div class="box ext"><b>User directory</b><span>Group membership and people search.</span></div>
        <div class="box ext"><b>Email and Slack service</b><span>Already in the codebase.</span></div>
      </div>
    </div>
  </div>
  <p>One engine hosts several apps. Each app is a <em>namespace</em> with its own pages and its own action-item list; apps share the engine and its tables, separated by a namespace column. There is no inbox shared across apps.</p>
  <p>The UI is layered so later apps can reuse it: a headless client for the API, a set of UI components kept as a folder inside the app for now, and the Change Management pages on top.</p>
</section>

<section id="kernel">
  <h2>4. The kernel</h2>
  <p>The kernel is the small set of parts the engine executes. The full rules are in <code>kernel/kernel-spec.md</code>, which describes the engine only and names no workflow or composite.</p>
  <div class="tablewrap"><table>
    <thead><tr><th>Part</th><th>What it is</th><th>First release</th></tr></thead>
    <tbody>
      <tr><td><strong>Stage</strong></td><td>A named scope. The root stage is always active, and exactly one child stage is active. Entering a stage opens its waits; leaving it cancels the ones still open. A final stage closes the request.</td><td>Root plus one level</td></tr>
      <tr><td><strong>Transition</strong></td><td>A condition and a target stage. The condition is checked against recorded state after every input; there are no trigger events. It can write data when it fires.</td><td>Yes</td></tr>
      <tr><td><strong>Wait</strong></td><td>The only thing that blocks. It opens, then closes once as completed, cancelled or skipped. A <em>person</em> wait is closed by an authorised person submitting an outcome and data. A <em>call</em> wait is closed by a connector's result.</td><td>Person and call</td></tr>
      <tr><td><strong>Set</strong></td><td>A write to the request's data document, on a transition, at start, or by an admin.</td><td>Yes</td></tr>
      <tr><td><strong>For each</strong></td><td>Opens one person wait per item of a list fixed when the stage is entered.</td><td>On person waits</td></tr>
    </tbody>
  </table></div>

  <h3>How an input is processed</h3>
  <ol>
    <li>One input (a start, a person acting, a call result, an admin action) is one <em>turn</em>, under a per-request lock, in one database transaction.</li>
    <li>The input is validated. A refused attempt writes nothing to history; it goes to a separate attempts log.</li>
    <li><code>decide</code> reads the definition, evaluates conditions and writes events that spell out every consequence: which transition fired and what it read, which stage was entered, which waits opened with which resolved parameters.</li>
    <li><code>evolve</code> folds events into state. Replay uses only <code>evolve</code>: it never evaluates a condition and never reads the definition.</li>
  </ol>
  <p>The cost of recording decisions is that a bug in <code>decide</code> is recorded as fact. It is repaired by an admin turn, never by rewriting history.</p>

  <h3>Rules that shape everything else</h3>
  <ul>
    <li><strong>No unsolicited input.</strong> Every inbound fact closes a wait the engine opened. There are no signals or correlation keys.</li>
    <li><strong>Joins are conditions.</strong> "All approved" or "any rejected" is an expression over the waits in the stage. An open wait always has a readable status, so these expressions are safe.</li>
    <li><strong>Results belong to one entry of a stage.</strong> Re-entering a stage gives fresh waits. Anything that must persist is written to data.</li>
    <li><strong>No clock.</strong> Each event carries its timestamp, and that is the only time the engine knows.</li>
    <li><strong>Errors never count as false.</strong> A failed condition rolls the turn back and marks the request faulted until an admin acts.</li>
    <li><strong>A stuck check runs after every turn.</strong> An open request with no open obligation and no open call is flagged for admins.</li>
  </ul>

  <h3>Events</h3>
  <p>Every event carries the request ID, a sequence number, a timestamp, the turn it belongs to, a schema version and the engine build. The vocabulary is provisional until a second workflow has been built on it.</p>
  <div class="tablewrap"><table>
    <thead><tr><th>Kind</th><th>Events</th></tr></thead>
    <tbody>
      <tr><td>Inputs from outside</td><td><code>RequestStarted</code>, <code>WaitCompleted</code>, <code>CallResultLate</code>, <code>Overridden</code></td></tr>
      <tr><td>Decisions the engine recorded</td><td><code>TransitionFired</code>, <code>StageEntered</code>, <code>StageExited</code>, <code>WaitOpened</code>, <code>WaitCancelled</code>, <code>WaitSkipped</code>, <code>DataSet</code>, <code>Faulted</code>, <code>RequestClosed</code>, <code>RequestReopened</code></td></tr>
    </tbody>
  </table></div>
  <p>A few fields exist only so later features need no change to old history: a stage entry records its parent entry, a wait ID carries a sequence number, and a request can record the request that started it. Each points to a case in the expansion battery.</p>
</section>

<section id="change-request">
  <h2>5. The change request</h2>
  <p>A request has one primary domain and zero or more other domains, taken from the form. It only moves forward. As in the existing product, it takes one of three paths, chosen by its primary domain when it is submitted. The platform is a domain like any other; which domains get which path is a list in the definition.</p>
  <div class="tablewrap"><table>
    <thead><tr><th>Request</th><th>Approval</th><th>Eng lead</th></tr></thead>
    <tbody>
      <tr><td><strong>Primary domain is the platform</strong></td><td>Every domain's approvers must approve. Any one rejection rejects the request.</td><td>Picked by the primary domain's approver, who must pick one to approve.</td></tr>
      <tr><td><strong>Primary domain is any other domain</strong></td><td>Only the primary domain's decision counts. Other domains are told and may record a decision, which has no effect. Their actions close when the primary decides.</td><td>Picked by the primary domain's approver.</td></tr>
      <tr><td><strong>Primary domain is the no-approval domain</strong></td><td>None.</td><td>The first member of that domain's eng-lead group, read from the directory.</td></tr>
    </tbody>
  </table></div>
  <div class="diagram">
    <div class="flow">
      <div class="st"><b>Pending approval</b><span>Platform and domain requests. Two stages in the definition, one per approval rule.</span></div>
      <div class="ar">approved</div>
      <div class="st"><b>In development</b><span>The eng lead marks the request released.</span></div>
      <div class="ar">released</div>
      <div class="st final"><b>Released</b><span>Final.</span></div>
    </div>
    <p style="margin:12px 0 0;font-size:13.5px;color:var(--muted)">A rejection that counts moves the request to <strong>Rejected</strong> (final). A no-approval request skips Pending approval: it passes through <strong>Assigning eng lead</strong> for as long as the directory lookup takes, then enters In development.</p>
  </div>
  <ul>
    <li><strong>The paths are stages, not a special approval.</strong> A routing stage with no waits sends the request to one of three stages in the turn it is submitted. The approval rule for each path is that stage's own transitions.</li>
    <li><strong>Submission never blocks.</strong> If a domain has nobody able to approve, the request still waits in Pending approval, and a notification rule alerts the workflow admins from the recorded directory result.</li>
    <li><strong>Requesters cannot approve their own request.</strong> Group membership is checked when the person acts, and the lookup is recorded with the approval.</li>
    <li><strong>An admin can skip one domain's approval,</strong> but a skip never counts as an approval. To move the request on, the admin also jumps it forward and supplies the eng lead if nobody picked one.</li>
    <li><strong>A failed lookup or an empty eng-lead group faults the request</strong> on the no-approval path. A failed call is an error by default, not a case the workflow handles; only the approvals' advisory membership check opts out. An admin either re-enters the stage, which asks the directory again, or sets the eng lead and jumps forward.</li>
  </ul>
  <h3>Composites</h3>
  <p>The definition is written with two composites, described in full in <code>composites/composites.md</code>. Each is code in the repository, has a version, and expands into kernel parts when the definition is published.</p>
  <ul>
    <li><strong>Approval</strong> asks a group for a decision. It can run once per item of a list, can be optional (the decision is recorded but nothing waits for it), and can notify the people it asks. It owns no transition: it exposes <code>approved</code> and <code>rejected</code>, and the workflow decides what they do.</li>
    <li><strong>Task</strong> asks one assignee to do something and say it is done.</li>
    <li><strong>DomainApprovals</strong> is a third composite built only as a worked example of how to write one. The change request does not use it.</li>
  </ul>
  <p>History never names a composite. The published definition records which composite, version and parameters each element came from, and element IDs are derived from the composite instance (<code>primary.decision</code>, <code>release.task</code>) so a later migration can find the approval an old event belongs to.</p>
  <p>The definition is in <code>workflows/change-request/definition.md</code>. Seventeen cases covering all three paths, refused attempts, admin skips and jumps, late call results and faults are written as test data next to it. They have not been run; no engine exists yet.</p>
  <p><span class="pill open">To confirm</span> Whether one person in two domains' approver groups may approve for both (assumed yes).</p></section>

<section id="people">
  <h2>6. People and permissions</h2>
  <ul>
    <li><strong>Who may act</strong> is decided when they act: the engine looks up the actor's group memberships, checks them against the wait's assignees and its rule, and records the lookup as evidence.</li>
    <li><strong>Who is being asked</strong> is recorded when the wait opens, as user and group references.</li>
    <li><strong>My action items</strong> are the open person waits marked as obligations whose assignees name me or a group I belong to now. Each app has its own list.</li>
    <li><strong>Viewing</strong> follows roles on the request: requester, approver, eng lead. Someone who used to hold a role keeps view access only.</li>
  </ul>
  <h3>Admin turns</h3>
  <p>An admin action is one recorded event followed by its consequences. An admin can skip one wait, jump to a stage, set data, disable a transition for one request, clear a fault, and close or reopen a request. Jumping into a stage requires the admin to supply, or explicitly waive, the data that stage needs. What was skipped is recorded as skipped, never as done.</p>
  <h3>Break-glass</h3>
  <p>The dev team holds standing super-admin access so a production problem never waits on a deployment or an entitlement request. A break-glass user can do anything an admin can, including on their own requests. Safeguards come from accountability (a required reason, a time-boxed session, a team alert, an after-the-fact review list), not from hard-coded limits. The first super-admins are seeded by a database migration.</p>
</section>

<section id="definitions">
  <h2>7. Definitions and versions</h2>
  <ul>
    <li>A definition is a JSON document stored in the platform database and published through the API. There is no server CLI access, so the admin page that accepts JSON is the publishing tool.</li>
    <li>A published version is immutable. <strong>A request stays on the version it started on, forever.</strong></li>
    <li>A saved draft of the intake form is not a request yet. It is checked against the latest version when submitted.</li>
    <li>Conditions and computed values use CEL. Approver routing by domain is a CEL lookup, not a separate decision-table feature.</li>
    <li>Publishing runs checks: expressions type-check, data is read only where it exists, every stage can reach a final stage, and every outcome leads somewhere. "Can never get stuck" cannot be proven in general; the runtime stuck check is the backstop.</li>
    <li>The first release has two composites, Approval and Task, and one example composite, all written as code (section 5). Changing what a composite expands to requires a new composite version; a build test compares each expansion with a stored copy and fails otherwise.</li>
  </ul>
  <p>The definition format and its CEL environment are a second long-lived contract: the engine must be able to run a version for as long as a request on it is open.</p>
</section>

<section id="integrations">
  <h2>8. Integrations</h2>
  <div class="tablewrap"><table>
    <thead><tr><th>System</th><th>How it connects</th></tr></thead>
    <tbody>
      <tr><td>User directory</td><td>A call wait reads group members. The act-time membership check reads it too. The people picker for the eng lead searches it.</td></tr>
      <tr><td>Email and Slack</td><td>The notifier consumes committed events and applies the definition's notification rules, delivering through the existing service. A sent notification is not part of a request's history.</td></tr>
      <tr><td>Other systems, later</td><td>A call wait through a connector. A connector must honour the idempotency key and must never report "don't know" as a failure.</td></tr>
    </tbody>
  </table></div>
  <p>A call's result is recorded in history when it arrives, so replay never calls out. A result that arrives after its wait was cancelled is still recorded, as a late result that no condition can see.</p>
  <p><strong>Forms.</strong> The first release renders the intake form itself. Using the internal form creator app through its API remains the preferred long-term route and has not been evaluated.</p>
</section>

<section id="data">
  <h2>9. Data model</h2>
  <div class="tablewrap"><table>
    <thead><tr><th>Table</th><th>Holds</th><th>Notes</th></tr></thead>
    <tbody>
      <tr><td><code>events</code></td><td>Every request's history</td><td>Append-only. The source of truth.</td></tr>
      <tr><td><code>definitions</code></td><td>Published definition versions</td><td>Immutable rows.</td></tr>
      <tr><td><code>requests</code></td><td>Current state of each request</td><td>Rebuildable from events. Data is one jsonb column with a general index, so publishing never changes the schema. Stores the active stages as a set, the readable ID, and a reserved legacy ID.</td></tr>
      <tr><td><code>open_waits</code></td><td>Open waits and their assignees</td><td>Rebuildable. Feeds action-item lists.</td></tr>
      <tr><td><code>pending_calls</code></td><td>Calls waiting for delivery</td><td>Written in the same transaction as the event that opened the call.</td></tr>
      <tr><td><code>attempts_log</code></td><td>Refused attempts</td><td>Outside history.</td></tr>
      <tr><td><code>super_admins</code></td><td>Break-glass membership and sessions</td><td>Seeded by migration.</td></tr>
    </tbody>
  </table></div>
  <p>All tables carry the namespace. History is kept forever; there are no snapshots, because replay is a cheap fold over a few dozen events.</p>
</section>

<section id="operations">
  <h2>10. Operations and cutover</h2>
  <ul>
    <li><strong>Faults.</strong> A faulted request shows in an admin list with the element and error. It keeps recording inputs and resumes after an admin turn.</li>
    <li><strong>Stuck requests.</strong> Flagged automatically after any turn that leaves nothing open.</li>
    <li><strong>Calls.</strong> Delivered by a Postgres job queue that can enqueue inside the same transaction (Graphile Worker or pg-boss). A reconciler re-queues any open call with no delivery in flight.</li>
    <li><strong>Request inspector.</strong> An admin page showing a request's events, including which transition fired and the values it read.</li>
  </ul>
  <h3>Cutover</h3>
  <ul>
    <li>Requests already in flight finish in the existing product. New requests start in the new one.</li>
    <li>Readable IDs in the new system start above the legacy maximum, so the two never collide.</li>
    <li>Importing legacy requests is reconsidered after release. The request table reserves a legacy ID so it needs no schema change.</li>
  </ul>
</section>

<section id="plan">
  <h2>11. Plan</h2>
  <div class="tablewrap"><table>
    <thead><tr><th></th><th>Milestone</th><th>Done when</th></tr></thead>
    <tbody>
      <tr><td class="n">M0</td><td>Parity checklist</td><td>The existing product's behaviours are listed from its code, each marked keep or drop.</td></tr>
      <tr><td class="n">M1</td><td>Walking skeleton</td><td>The engine passes test case T1, and the request table rebuilds from events.</td></tr>
      <tr><td class="n">M2</td><td>Change request behaviour</td><td>The Approval and Task composites are built, plus the domain-approvals example, each with a version and the stored-expansion build test. All cases in <code>workflows/change-request/test-cases.yaml</code> pass, plus cases added from the parity checklist.</td></tr>
      <tr><td class="n">M3</td><td>The app</td><td>Intake form, request page, action items and admin pages work end to end.</td></tr>
      <tr><td class="n">M4</td><td>Operability</td><td>A staged incident is fixed through the admin pages alone, with no server access.</td></tr>
      <tr><td class="n">M5</td><td>Cutover</td><td>New requests start in the new system.</td></tr>
    </tbody>
  </table></div>
  <p>The kernel is a small share of the work. Most of the effort is the form renderer and app, integration with the existing codebase, parity, operability and cutover.</p>
</section>

<section id="later">
  <h2>12. Later features</h2>
  <p>Each has a short reserved rule in the kernel spec and a paper case in the expansion battery. None is built in the first release.</p>
  <div class="tablewrap"><table>
    <thead><tr><th>Feature</th><th>What it adds</th><th>Needed by</th></tr></thead>
    <tbody>
      <tr><td><span class="pill later">Later</span> Child requests</td><td>Start another workflow, optionally wait for it, and let it outlive the stage that started it. Also the answer for a multi-step task inside a stage.</td><td>Tech debt initiatives, architecture review</td></tr>
      <tr><td><span class="pill later">Later</span> Timer waits</td><td>Make something happen when a time arrives.</td><td>Deadlines, reminders</td></tr>
      <tr><td><span class="pill later">Later</span> Act-time gates</td><td>Named checks per outcome, with messages, run when a person acts. They can read the time of the attempt.</td><td>Metric change control</td></tr>
      <tr><td><span class="pill later">Later</span> Repeatable waits</td><td>An action a person can repeat within one stage entry, such as ticking a box or editing a field. Each use writes data.</td><td>Checklists that can be un-ticked</td></tr>
      <tr><td><span class="pill later">Later</span> In-flight updates</td><td>Moving a request to a newer definition version.</td><td>Architecture review</td></tr>
      <tr><td><span class="pill later">Later</span> Scheduling</td><td>Date-triggered starts and recurring duties, possibly as a separate "obligations" feature.</td><td>Metrics recertification</td></tr>
      <tr><td><span class="pill later">Later</span> Workflow editor and more composites</td><td>Owners configure workflows in a UI from ready-made parts.</td><td>Every later app</td></tr>
    </tbody>
  </table></div>
  <p>The metric change-control requirements were expanded on paper as a second workflow. They fit the model with no new event type; they need act-time gates and child requests, and one loop (revise and re-approve) is a known weak spot to revisit when that workflow is built.</p>
</section>

<section id="decisions">
  <h2>13. Decisions</h2>
  <div class="tablewrap"><table>
    <thead><tr><th>#</th><th>Decision</th><th>Replaces</th></tr></thead>
    <tbody>
      <tr><td class="n">1</td><td>Build a small engine; do not adopt a product.</td><td></td></tr>
      <tr><td class="n">2</td><td>Kernel of stages, transitions, waits and Set. Approvals and forms are composites.</td><td>Separate node types for approval, task, action, branch and subflow</td></tr>
      <tr><td class="n">3</td><td>History is the source of truth. The engine records its decisions; replay is a fold.</td><td>Replaying inputs through a version-gated reducer; snapshots; state hashes</td></tr>
      <tr><td class="n">4</td><td>No unsolicited input; conditions read recorded state.</td><td>Events matched to waiters by correlation key</td></tr>
      <tr><td class="n">5</td><td>Joins are CEL conditions.</td><td>A table of join policies</td></tr>
      <tr><td class="n">6</td><td>External data enters history as call results and act-time evidence.</td><td>Prefetching data before each engine run</td></tr>
      <tr><td class="n">7</td><td>CEL for all conditions and computed values.</td><td></td></tr>
      <tr><td class="n">8</td><td>Definitions are data in the database, published through the API.</td><td></td></tr>
      <tr><td class="n">9</td><td>A request stays on its definition version forever. Drafts follow the latest version at submit.</td><td>Configurable change policies</td></tr>
      <tr><td class="n">10</td><td>One engine, many apps, separated by namespace. No shared inbox.</td><td></td></tr>
      <tr><td class="n">11</td><td>An empty approver group never blocks submission. The alert is a notification rule.</td><td>Routing and alerting stages in the flow</td></tr>
      <tr><td class="n">12</td><td>Admin override records what was skipped; a skip never counts as done.</td><td></td></tr>
      <tr><td class="n">13</td><td>Break-glass can act on its own requests; safeguards are accountability, not hard limits.</td><td></td></tr>
      <tr><td class="n">14</td><td>Notifications are a consumer of the event stream, outside history.</td><td>Notifications as engine effects</td></tr>
      <tr><td class="n">15</td><td>Calls are delivered from a Postgres job queue in the same transaction as their event.</td><td></td></tr>
      <tr><td class="n">16</td><td>Stages nest one level. A multi-step task inside a stage is a child request.</td><td>A node graph inside each stage</td></tr>
      <tr><td class="n">17</td><td>No attachments in the first release.</td><td></td></tr>
      <tr><td class="n">18</td><td>Cutover by draining the existing product; import later if it proves easy.</td><td></td></tr>
      <tr><td class="n">19</td><td>The spec covers every known use case; only the first release is built. Test cases as data are the engine's first tests.</td><td></td></tr>
    </tbody>
  </table></div>
</section>

<section id="open">
  <h2>14. Open questions</h2>
  <ul>
    <li>May one person in two domains' approver groups approve for both? Assumed yes.</li>
    <li>Which directory API backs group membership and the people picker?</li>
    <li>After what date are requests still open in the existing product imported or closed?</li>
    <li>Does the existing product have saved drafts, SLA reminders or reports that must carry over? The parity checklist (M0) answers this.</li>
    <li>Which JavaScript CEL library? It needs a short trial for conformance and custom functions.</li>
    <li>Approvers editing a request's domain: the existing behaviour has known problems and is set aside for now.</li>
    <li>Erasing personal data from a history that is kept forever: set aside for now.</li>
  </ul>
</section>

<section id="glossary">
  <h2>15. Glossary</h2>
  <dl class="gloss">
    <dt>Request</dt><dd>One running instance of a workflow, such as a single change request.</dd>
    <dt>Definition</dt><dd>The published description of a workflow: its stages, waits, transitions and notification rules.</dd>
    <dt>Kernel</dt><dd>The small set of parts the engine executes: stage, transition, wait, Set.</dd>
    <dt>Composite</dt><dd>Something an owner configures, such as an approval, that expands into kernel parts when published.</dd>
    <dt>Stage</dt><dd>Where a request is. Shown to users as its status.</dd>
    <dt>Activation</dt><dd>One entry of a stage. Re-entering a stage creates a new activation with fresh waits.</dd>
    <dt>Wait</dt><dd>Something the request is waiting on: a person's action or a call's result.</dd>
    <dt>Obligation / option</dt><dd>A person wait that someone is being asked to do, versus one they may do. Only obligations appear in action-item lists.</dd>
    <dt>Transition</dt><dd>A condition that, when true, moves the request to another stage.</dd>
    <dt>Turn</dt><dd>The processing of one input, in one database transaction.</dd>
    <dt>History</dt><dd>The append-only list of a request's events. The source of truth.</dd>
    <dt>Decide / evolve</dt><dd><code>decide</code> works out what an input causes and records it as events. <code>evolve</code> applies events to state and is all that replay uses.</dd>
    <dt>Replay</dt><dd>Rebuilding a request's state by applying its events in order.</dd>
    <dt>Call</dt><dd>A request to an outside system through a connector, with a key that makes repeats safe.</dd>
    <dt>Idempotency key</dt><dd>An identifier sent with a call so the outside system can recognise a repeat and not act twice.</dd>
    <dt>Fault</dt><dd>A request the engine has flagged for an admin: an expression failed, or nothing is left open.</dd>
    <dt>Admin turn</dt><dd>An admin's recorded intervention: skip, jump, set data, close or reopen.</dd>
    <dt>Break-glass</dt><dd>Standing super-admin access for the dev team, for emergencies.</dd>
    <dt>Namespace</dt><dd>One workflow app on the shared engine, with its own pages and lists.</dd>
    <dt>CEL</dt><dd>Common Expression Language, used for conditions and computed values.</dd>
    <dt>Expansion battery</dt><dd>Workflows expanded on paper into kernel parts and events, to test that the kernel can express them.</dd>
    <dt>Insurance field</dt><dd>A field recorded now only so a later feature needs no change to old history.</dd>
    <dt>Drain</dt><dd>Letting in-flight requests finish in the old system while new ones start in the new one.</dd>
  </dl>
</section>
</main>
</div>
</body>
</html>
===\n./kernel/replay-only.yaml\n===
# Replay-only cases, against kernel-spec.md v2.9.
# `by` shorthand is as in workflows/change-request/test-cases.yaml.
#
# The MVP's `decide` never produces these histories. Each case checks that `evolve` can replay a
# history that uses an insurance field, so the field is not dropped. Given the events, replay must
# produce the expected state.

cases:

  - id: R1
    name: Two child stages active at once (battery P4)
    needs: [StageEntered.parentActivation, "active stages stored as a set"]
    history:
      - [RequestStarted, { by: rita }]
      - [StageEntered, { activation: a1, stage: root, parentActivation: null }]
      - [StageEntered, { activation: a2, stage: Legal, parentActivation: a1 }]
      - [StageEntered, { activation: a3, stage: Security, parentActivation: a1 }]
      - [WaitOpened, { wait: Legal.review@a2, kind: person, role: obligation }]
      - [WaitOpened, { wait: Security.review@a3, kind: person, role: obligation }]
      - [WaitCompleted, { wait: Legal.review@a2, outcome: approve, by: lena }]
      - [StageExited, { activation: a2, mode: normal }]
    expectState:
      activeStages: [ { activation: a1, stage: root }, { activation: a3, stage: Security, parent: a1 } ]
      open: [Security.review@a3]

  - id: R2
    name: A second instance of the same wait in one stage entry (battery C3)
    needs: [wait ID seq]
    history:
      - [RequestStarted, { by: rita }]
      - [StageEntered, { activation: a1, stage: root, parentActivation: null }]
      - [StageEntered, { activation: a2, stage: PendingApproval, parentActivation: a1 }]
      - [WaitOpened, { wait: "PendingApproval.items[lineage]@a2", seq: 1, kind: person }]
      - [WaitOpened, { wait: PendingApproval.approval@a2, seq: 1, kind: person }]
      - [WaitCompleted, { wait: "PendingApproval.items[lineage]@a2", seq: 1, outcome: done, by: cara }]
      - [WaitOpened, { wait: "PendingApproval.items[lineage]@a2", seq: 2, kind: person }]
    expectState:
      activeStages: [ { activation: a1, stage: root }, { activation: a2, stage: PendingApproval, parent: a1 } ]
      waits:
        - { wait: "PendingApproval.items[lineage]@a2", seq: 1, status: completed }
        - { wait: "PendingApproval.items[lineage]@a2", seq: 2, status: open }
        - { wait: PendingApproval.approval@a2, seq: 1, status: open }

  - id: R3
    name: A child request records its parent (battery P1, P2)
    needs: [RequestStarted.parent]
    history:
      - [RequestStarted, { by: "system:engine", parent: { requestId: req-100, wait: Build.start@a4 } }]
      - [StageEntered, { activation: a1, stage: root, parentActivation: null }]
    expectState:
      parent: { requestId: req-100, wait: Build.start@a4 }
===\n./kernel/expansion-battery.md\n===
# Expansion test battery

Each case is a workflow expanded into the kernel's blocks and events on paper. A case passes when it uses only what the kernel spec defines. The battery is also the record of why fields exist: if a case can no longer be expressed, something it needs was removed.

Cases the MVP builds have a definition and test cases as data under `workflows/` (inputs and the exact events expected). The others stay on paper, with small replay-only cases for the insurance fields.

| Case | Workflow | Built in the MVP | Status | Test data |
|---|---|---|---|---|
| C1 | Change request | Yes | Passes on spec v2.9 | `workflows/change-request/` (T1 to T12) |
| C2 | Metric change control | No | Expressible with reserved features; the revise-and-reapprove loop is a known weak spot | Paper |
| C3 | Checklist item ticked, un-ticked, re-ticked | No | Representation only | `replay-only.yaml` R2 |
| P1 | Start without waiting, join later | No | Passes with child requests | Paper; R3 covers the parent field |
| P2 | Work that survives a send-back | No | Passes with child requests | Paper; R3 |
| P3 | Fan-out where each leg runs several steps | No | Passes with child requests | Paper |
| P4 | Two stage paths active at once | No | Representation only | `replay-only.yaml` R1 |
| I1 | Ten repeated in-stage actions | No | 3 of 10 clean with repeatable waits; the rest need an undesigned layer; history is safe for all | Paper; reports in `research/instage-test/` |

## C1. Change request

The definition is `workflows/change-request/definition.md`; its cases are T1 to T12 in `workflows/change-request/test-cases.yaml`. It has three paths: all domains approve, the primary domain alone approves, and no approval.

Passes if: every trace uses only the events in section 5 of the spec.

Needs: `foreach` on person waits; the guarded wait-status record; `CallResultLate`; admin skip of a single wait; stage `requires` with supply-or-waive on a jump; notification rules; a stage with no waits; an admin jump to the current stage.

## C2. Metric change control

Source: `~/Downloads/ETIP_Change_Control_Governance_TRD.md`. A card moves through New Request, Discovery, Pending Approval, Pending Implementation, Deployed and Archived, operated by a Concierge.

How it maps:
- Each lane is a stage. Cancel is a wait on the root stage.
- The Concierge moving a card is a person wait whose outcome fires the transition.
- Discovery edits re-enter the stage. Nothing is lost, because no approvals exist there.
- In Pending Approval, each checklist item is its own person wait (`foreach` over the items for the change type), and each forum outcome is a wait. Notes and links are comments, outside the kernel.
- The AE approval round is a child request, awaited in Pending Approval with `onCancel: terminate`.
- The move to Pending Implementation is one wait with two outcomes, each with act-time gates.

```
PendingApproval:
  waits:
    items:   person { foreach: data.checklist, assignees: [group: concierge], outcomes: [done] }
    forums:  person { foreach: data.forums, assignees: [group: concierge], outcomes: { recorded: {...} } }
    approval: child { request: data.approvalId, onCancel: terminate }
    advance: person { assignees: [group: concierge], outcomes:
      { advance:   { may: [ { id: checklist, when: required items done },
                            { id: ae,        when: waits.approval.outcome == 'approved' },
                            { id: curation,  when: now >= data.minGoLive } ] },
        fastTrack: { may: [ { id: ae, when: waits.approval.outcome == 'approved' } ],
                     data: { comment: string } } } }
  t: when waits.advance.outcome in ['advance', 'fastTrack']  set { override: ... }  -> PendingImplementation
```

Passes if: ticking a checklist item does not disturb an AE approval in progress; a blocked move tells the Concierge which check failed; a fast track records its comment; a rejection keeps the card in Pending Approval.

Needs: act-time gates; child requests; `foreach` on person waits.

Known weak spot: revise and re-approve. After a rejection the approval child has closed, and a second approval round in the same stage entry needs either a second instance of the await (repeatable waits) or a re-entry that resets the checklist. The child also holds a snapshot of the card from when it started. Revisit when change control is built.

## C3. Checklist item ticked, un-ticked, re-ticked

In C2's Pending Approval, the Concierge ticks an item, un-ticks it, and ticks it again, while an AE approval is in progress.

Passes if: the history can hold a second instance of the same wait in the same stage entry (`seq` 2), and the AE approval is not reset.

Needs: `seq` in the wait ID.

## I1. Repeated in-stage actions

Ten patterns, each expanded under three models: data-driven (an action is a validated write), event-driven (named events with handlers), and the hybrid in the spec (a repeatable wait with its own Set). A fourth agent tried to show that the history favours one model. Reports: `research/instage-test/`.

1. Checkbox: tick, un-tick, re-tick; a gate needs all required items.
2. Field edit, several times; the latest value is used.
3. Question and answer while an approval stays open.
4. Reassign an open task.
5. Add or remove a reviewer mid-review.
6. An edit that dismisses approvals already given.
7. An external call on every use, with its result known to the workflow.
8. Two people act on the same item at once.
9. A correction; audit shows both values.
10. A value derived from several in-stage actions.

Result: the three models differ in the definition language, not in the history. Each action records the action and its data write, linked by `turn`; no old history becomes unreplayable under any model. From the hybrid, moving to data-driven needs no history change, and moving to event-driven needs only additions. The hybrid alone handles 3 of the 10 cleanly; the limits are listed in the spec, section 8.

Needs: the patch format in `DataSet`; `DataSet.element` and source `wait`; open payload enums; `seq` as an ordinal with "highest is current"; `turn` as the causing input on the fault path; typed `by`.

## Child rules assumed (to be written into the spec as reserved)

- **Start** is a call: `call { connector: engine, op: start, args: { workflow, version, input }, effect: write }`. Its result is `{ requestId }`. Default idempotency key is per request, so re-entering the stage returns the same child. The child's `RequestStarted` carries `parent: { requestId, wait }`.
- **Await** is a wait of kind `child`: `{ request: <CEL -> requestId>, onCancel: detach | terminate }`. It completes with the child's final stage as outcome and the child's output as data.
- An await **never completes in the turn that opens it**. Completion always arrives as a later input, through the same delivery path whether the child closed long ago or just now. `decide` never reads another request's state.
- Cancelling an await (its stage is exited) leaves the child running when `detach`, and closes it when `terminate`. A parent closing a child is recorded in the child's history as `Overridden` by a system identity.
- A parent's definition pins the child workflow's version, so the publish check can verify the outcomes its conditions read.

## P1. Start without waiting, join later (initiative intake)

A starts S and moves on; A goes to one of B, C, D; E needs one of B/C/D and also S; S's outcome can divert the parent.

```
A:       waits: a: person {...}                          t: when a done -> StartS
StartS:  waits: start: call { engine.start, workflow: S }
         t: when start ok  set { sId: waits.start.data.requestId }  -> B | C | D (by data)
B:       waits: b: person {...}
                s: child { request: data.sId, onCancel: detach }
         t_div:  when waits.s.outcome == 'declined'  -> F
         t_done: when waits.b.outcome == 'done'      -> E
(C, D likewise)
E:       waits: s: child { request: data.sId, onCancel: detach }
         t_div: when waits.s.outcome == 'declined'  -> F
         t_go:  when waits.s.outcome == 'approved'  -> Work
```

Events used: `WaitOpened {kind: call}`, `WaitCompleted`, `DataSet`, `WaitOpened {kind: child}`, `WaitCancelled {cause: stage exit}` (the await in B when moving to E), `WaitOpened {kind: child}` again in E, `WaitCompleted`. In S's history: `RequestStarted {parent}`.

Passes if: S finishing before, during or after B gives the same parent path; leaving B never closes S.

Needs: `RequestStarted.parent`; `WaitOpened` params for kind child (`request`, `onCancel`).

## P2. Work that survives a send-back (design review)

Stage Build starts a prototype; stage 10 sends the request back to Draft; the prototype keeps running with its own status; a later stage reads its result.

```
Build:   waits: start: call { engine.start, workflow: Prototype }      (key: per request)
         t: when start ok  set { protoId: waits.start.data.requestId }  -> Next
...
Late:    waits: lead: person { outcomes: [advance, sendBack] }
         t_back: when waits.lead.outcome == 'sendBack'  -> Draft
Final:   waits: proto: child { request: data.protoId, onCancel: detach }
```

Passes if: after `t_back` the prototype's history shows no event caused by the parent; re-entering Build returns the same `requestId` (no second prototype); the parent's page can list the prototype and its current stage through `parent`.

Needs: per-request idempotency key on write calls; `RequestStarted.parent`.

## P3. Fan-out where each leg runs several steps (design review)

Each reviewer gets a thread (question, answer, verdict). Verdicts combine: one veto sends back; two approvals accept.

```
StartThreads: waits: start: call { foreach: data.reviewers, engine.start, workflow: ReviewerThread,
                                   key: item + '/' + string(data.round) }
              t: when waits.start.all(w, w.outcome == 'ok')
                 set { threads: waits.start.map(w, w.data.requestId) }  -> Review
Review:       waits: threads: child { foreach: data.threads, request: item, onCancel: terminate }
              t_veto: when waits.threads.exists(w, w.outcome == 'veto')
                      set { round: data.round + 1 }                      -> Draft
              t_ok:   when waits.threads.filter(w, w.outcome == 'approve').size() >= 2  -> Accepted
```

Passes if: each thread has its own visible stage; a veto closes the other threads (their reviewers' tasks disappear) and each closed thread's history shows `Overridden` by the system identity; the second round starts new threads, not the closed ones.

Needs: `foreach` on call and child waits; `onCancel: terminate`; the round counter in the start key.

## P4. Two stage paths active at once in one request (representation only)

Not supported by the spec's rules: exactly one child stage is active. This case checks only that the history and stored state could represent it, so that adding it later needs no change to old events.

Passes if: a history containing `StageEntered {activation: a2, parent: a1}` and `StageEntered {activation: a3, parent: a1}` with neither exited replays to a state holding both; the request table stores active stages as a list.

Needs: `StageEntered.parentActivation`; active stages stored as a set.

## Result of the first run (paper)

- P1, P2, P3 are expressible with child requests. No new event type.
- P4 is representable once `StageEntered` carries its parent activation.
- Fields to add: `RequestStarted.parent`; `StageEntered.parentActivation`; child params on `WaitOpened`.
- Rules to add: the five child rules above.
- Costs seen: the await on S is repeated in every stage that needs it (or needs a third nesting level); a fan-out takes two stages (start, then await); fan-out re-entry needs a round counter in the key, which a composite should own; a child gets the parent's data only as a snapshot at start.
===\n./kernel/kernel-spec.md\n===
# Workflow engine kernel: spec v2.9

Status: proposal. This file is the reference for the engine. It does not describe any workflow or composite; those live in `composites/` and `workflows/` and refer to this file, never the reverse.

The spec covers every known use case; only the MVP is built. Three tiers:
- **Permanent layer** (event shapes, IDs, insurance fields): specified in full now. Section 5.
- **MVP behaviour:** specified in full. Sections 2 to 7.
- **Later features:** one short reserved rule each, in section 8, plus a paper case in `expansion-battery.md`. Full spec when built.

The spec stays terse. The reason an insurance field exists is the battery case it points to: if that case can no longer be expressed, the field was removed.

## 1. Scope

| Part | MVP | Reserved (slots held, not built) |
|---|---|---|
| Stage | Root stage plus one level of child stages | Deeper nesting is not planned: a multi-step task inside a stage is a child request. History can already describe nesting (`parentActivation`). |
| Transition | Yes | |
| Wait: person | Yes, with a single `may` rule | Act-time gates; repeatable waits |
| Wait: call | Yes | |
| Wait: timer | No | Section 8 |
| Wait: child | No | Section 8 |
| `foreach` | Yes, on person waits | On other wait kinds |
| Set | Yes | |
| Notification rules | Yes | |
| Publish through the API | Yes (a JSON POST; composites are code and expand at publish, section 7) | Composite registry |

The event vocabulary is provisional until a second use case has been built against it. Every event carries a schema version so shapes can be upcast.

## 2. Blocks

**Definition.** `{start, root, notifications}`. `start` is `{schema, set}`: the input is validated against `schema` and `set` writes it into data. `root.initial` names the child stage a request starts in.

**Stage.** A named scope. The root stage is always active; exactly one child stage is active. Each entry creates an *activation* with a new ID. A stage declares waits, transitions, an optional display `status`, and optional `requires` (data paths that must exist on entry). Entering a stage opens all its waits. Leaving it cancels the ones still open. A stage may have no waits: its transitions are evaluated in the turn that enters it, so it works as a routing step. A `final` stage closes the request. Replay state and the request table store the active stages as a set; only `decide` enforces "exactly one active child" (battery P4).

**Transition.** `{id, when: CEL, set: {path: CEL}, to: stage}` declared on a stage.
- Level-triggered: `when` is evaluated over recorded state at the end of every turn.
- Fires at most once per activation of its declaring stage. A root transition is therefore one-shot in the MVP, which suits withdraw, cancel and deadline interrupts. A repeatable root action needs repeatable waits (reserved).
- A root transition whose target is a child stage is *local*: the root stays active, only the active child is exited.
- A self-target exits and re-enters (new activation, fresh waits).
- `otherwise` is a built-in condition: every wait of this stage is `completed` and no other transition is enabled. A skipped wait never satisfies it.
- Order: root transitions first, then the child stage's, in declared order. First true one fires.

**Wait.** ID = `(element, activation, key, seq)`. Lifecycle: `open -> completed | cancelled | skipped`.
- `seq` is an ordinal per `(element, activation, key)`, whatever caused the new instance. The highest `seq` is the current instance, for every wait kind, in `evolve` and in CEL. The MVP's `decide` only ever writes 1, but no code may assume `seq` is 1, that one instance exists, or that a predecessor completed (battery C3, I1). A repeated write call's idempotency key includes `seq`.
- In CEL every wait in scope is always readable as `waits.<element ID>` (for example `waits.primary.decision`) = `{status, outcome, by}`; `outcome` is `""` unless completed; `by` is who completed it, `{type, id}`. `waits.<name>.data` may be read only under a guard on that wait's outcome; the publish check enforces it.
- *Person:* `assignees` (user and group references, recorded at open, not expanded), `may` (optional CEL, default true; reads `data`, `request`, `actor`, waits in scope), `outcomes` (enum, each with a data schema), `role: obligation | option`. At act time the engine looks up the actor's memberships, checks `assignees` and `may`, validates data, and records the lookup as evidence. A refused attempt changes nothing and goes to an attempts log outside history.
- *Call:* `connector`, `op`, `args`, `effect: read | write`, optional `idempotencyKey`, optional `onFailure: fault | outcome` (default `fault`). A result is `ok` or `failed`. By default a failed call is an error, not a case the workflow handles: the request faults (section 3). With `onFailure: outcome`, `failed` is an ordinary outcome that conditions may read and the stage's transitions must cover. Default idempotency key: reads are per activation (re-entry reads again); writes are per request. The pending call is written in the same transaction as the event that opened it; a dispatcher delivers at least once, and a reconciler re-queues anything open with no delivery in flight.
- *Connector obligations:* honour the key. For a key that already succeeded, return that result and do nothing else (look up by key before creating if the external system has no idempotency support). For a key that failed, try again. Never report a timeout or "don't know" as `failed`; keep the call pending. An author who wants a retry with different arguments sets an explicit key.
- *`foreach`:* `foreach: <CEL list>` on a person wait opens one wait per item when the stage is entered. The list is evaluated once and recorded; it is not re-evaluated if data changes later. Items must be distinct (a duplicate is a fault). `item` is available in the wait's other expressions and becomes the wait's `key`. In CEL the waits read as a list: `waits.<name>.all(w, ...)`, `.exists(w, ...)`. An empty list opens nothing, and `all` over it is true.

**Set.** Writes to the request's data document, only on a transition, on start, or by an admin.

**CEL context.** `data`; `request` = `{id, by, at}` (`by` is the starter, `{type, id}`); `actor` = `{type, id}` (in `may` only); `waits` for the current activations of the root and the active child. Earlier activations are invisible. There is no clock. Anything that must persist goes through Set.

Waits on the root stage are open for the whole life of the request and are cancelled when it closes.

## 3. Turns

One input is one *turn*, under a per-request lock, in one Postgres transaction:

1. Validate the input against current state. If the wait is not open or the actor is not allowed, reject and write nothing to history.
2. Append the input event.
3. `decide`: fire transitions until none is enabled, appending every consequence as events.
4. Stuck check: if the request is not closed and has no open obligation and no open call, append `Faulted{kind: stuck}`.

Event order within a turn: the input; then for each firing `TransitionFired`, `DataSet`, `WaitCancelled` (declared order), `StageExited`, `StageEntered`, `WaitOpened` (declared order, `foreach` in list order); then `RequestClosed` or `Faulted` if any. Starting a request enters the root, then `root.initial`.

`evolve(state, event)` is the only code replay uses. It never evaluates CEL and never reads the definition.

**Faults.** If a CEL evaluation errors, a turn exceeds 50 firings, or a call without `onFailure: outcome` returns `failed`, the turn's decisions are rolled back, the input event is kept, and `Faulted{kind: error, element, error}` is appended. For a failed call the input is its `WaitCompleted{outcome: failed}` and the element is the wait; the fault is raised once, when the result is accepted, and an admin retries by re-entering the stage. A faulted request still accepts and records inputs but runs no `decide` until an admin turn clears the fault; then `decide` runs for the kept inputs in order. A CEL error is never treated as false. Reading a waived `requires` path is a CEL error. A `stuck` fault is a flag for admins: it does not stop evaluation, and it is cleared by an admin turn or by the request closing.

## 4. Admin turns

`Overridden {by, reason, breakGlassSession?, actions, waived}` is an input event. Its consequences are ordinary events in the same turn. All actions are applied first; `decide` and the stuck check run once, at the end of the turn. Actions:

- **Skip one wait:** `WaitSkipped`. Conditions see `status: skipped`. A skip alone never decides anything: it does not satisfy `otherwise` or any outcome test. To move on, the admin also jumps, or the author writes an explicit path (`when waits.x.status == 'skipped'`).
- **Jump to a stage:** open waits in the exited stage are skipped; the event records `from` and `to`. The target may be the stage the request is already in: that re-enters it (new activation, fresh waits, read calls made again). For each path in the target's `requires`, the admin supplies a value or lists it in `waived`.
- **Set data:** `DataSet{source: admin}`.
- **Disable a transition for this request.**
- **Clear a fault.**
- **Close, or reopen at a stage:** `RequestClosed` / `RequestReopened`. Reopening creates new activations of the root and the target stage.

There is no event that rewrites an earlier one. A wrong completion stays in history as what happened; the fix is an admin turn. Break-glass users can do all of this on their own requests.

## 5. Event vocabulary

Envelope on every event: `requestId`, `seq`, `at` (the only clock), `turn`, `v` (schema version of this event type), `engineBuild`. Events name definition elements by stable ID; the published definition maps each element to the composite instance it came from (section 7, composites).

- `turn` is the seq of the input that caused the event, even when `decide` ran later, after an admin cleared a fault.
- `by` is always a typed value: `{type: user | connector | system, id}`.
- Payload enums (`DataSet.source`, `WaitCancelled.cause`, `Faulted.kind`, `StageExited.mode`, wait `kind` and `role`) are open: `evolve` never branches on them, and values may be added.
- A patch is an ordered list of `{op: set | remove, path, value}`. `set` replaces the value at the path; there is no merge and no array position. A collection that is edited per item is a map keyed by ID.

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
| Decision | `DataSet` | patch, source: start, transition or admin (`wait` reserved), `element` (optional: the transition or wait whose Set wrote it) |
| Decision | `Faulted` | kind: error or stuck, element, error |
| Decision | `RequestClosed` | final stage, or closed by admin |
| Decision | `RequestReopened` | stage |

`RequestClosed` is not the end of a history: `CallResultLate` and `Overridden` can follow it.

## 6. Publish checks (MVP)

- Every CEL expression type-checks against the data schema, wait outcomes and connector result types.
- Wait reads are in scope; `.data` reads are guarded.
- A data path is read only where it is set on every path to that point or listed in the stage's `requires`.
- Outcomes are enums. Each stage's transitions cover every combination of its waits' outcomes, or the stage has an `otherwise`. A call's `failed` counts, and may be read, only with `onFailure: outcome`.
- Every stage can reach a final stage.
- Every cycle of transitions passes through a condition on a wait opened inside the cycle.
- Warning: a write call in a stage that a root transition can interrupt.

"Cannot get stuck" is not provable in general; the runtime stuck check is the backstop. Whether anybody is able to act on a person wait is not a kernel concern; a composite can check it with a call and a notification rule.

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
- Composites are expanded at publish; history never names one. A later migration finds the composite through the definition (history -> definition version -> element -> composite instance). Replay still never reads the definition. Three rules keep that lookup usable:
  - An expanded element's ID is the composite instance ID plus a local name (`primary.decision`, `primary.members`), never positional. It stays the same across composite versions when the element means the same thing. Instance IDs are unique within a stage; an element's full ID, and the ID of any notification rule a composite emits, is prefixed with the stage (`Pending.primary.decision`).
  - The published definition records, for each composite instance: composite name, composite version, and the parameters used.
  - Any change to a composite's expansion needs a new composite version. In the MVP composites are code: a build test compares each expansion with a stored copy and fails if it changed without a version bump.
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

**Repeatable waits** (battery C3, I1). A person wait that can be completed many times in one stage entry: a checkbox, a field edit. No new event type.
- Each completion records `WaitCompleted`, then `DataSet{source: wait, element}` from the wait's own Set, then opens the next instance (next `seq`) last, and only if the stage is still active.
- The Set is mandatory. It reads the completion (`outcome`, `data`, `by`, `at`) and the `foreach` item. Writing an unchanged value still records a `DataSet`.
- Conditions cannot read a repeatable wait (publish error). They read the data its Set wrote.
- An optional `pending` condition (for example "this item is not ticked"). While true, the wait counts as an obligation in the stuck check, in `otherwise` and on the action-item list. While false, it is only an available action on the request page.
- With `foreach`, each item has its own sequence, and the Set writes to a path keyed by the item.
- An admin skip closes the current instance and opens no successor.
- After a fault clears, the Set runs once per kept input.
- "Confirmed since the last edit" is done by stamping the item with what it was confirmed against (a revision number), not by counting completions.
- Transitions stay one-shot per stage entry.
- Known limits: work on every occurrence, dismissing some approvals after an edit, a repeatable stage move, reassignment, adding to a `foreach` list, and question-and-answer as a real task. These need a completion that can open or replace waits and calls. That layer is not designed; it must be opt-in so it stays additive.

## 9. Not addressed

- Erasing personal data from history (set aside for now).
- Date-triggered starts and scheduling (set aside; possibly a separate obligations feature later).
- A grammar and an author's guide for the definition format.
- A bulk admin action across many requests.
===\n./workflows/change-request/definition.md\n===
# Change request: workflow definition

The first workflow on the engine. It reproduces the existing Change Management product. It is written with the composites in `composites/composites.md` and runs on the kernel in `kernel/kernel-spec.md`. Its test cases are in `test-cases.yaml`, next to this file.

## Behaviour

A request has one primary domain and zero or more other domains, from the form. It only moves forward. It takes one of three paths, chosen by its primary domain. The platform is a domain like any other; the two special cases are lists of domains in the definition's constants.

| Request | Approval | Eng lead |
|---|---|---|
| Primary domain is the platform | Every domain's approvers must approve. Any one rejection rejects the request. | Picked by the primary domain's approver, who must pick one to approve. |
| Primary domain is any other domain | Only the primary domain's decision counts. Other domains are told and may record a decision, which has no effect. Their actions close when the primary decides. | Picked by the primary domain's approver. |
| Primary domain is the no-approval domain | None. | The first member of that domain's eng-lead group. |

After approval the eng lead marks the request released.

## Definition (as authored)

```
start: { schema: changeForm, set: { form: input } }
constants: approverGroup, engLeadGroup, allApprovalDomains, noApprovalDomains
root:
  initial: Route
  stages:
    Route:                                  # no waits; passed through in the start turn
      transitions:
        t_skip:     when data.form.primaryDomain in noApprovalDomains     ->  AssignLead
        t_all:      when data.form.primaryDomain in allApprovalDomains    ->  PendingAll
        t_domain:   otherwise                                             ->  PendingPrimary

    AssignLead:     status: Assigning eng lead
      waits:
        leads: call { connector: directory, op: membersOf, effect: read,
                      args: { groups: [engLeadGroup[data.form.primaryDomain]] } }
      transitions:
        t_lead: when waits.leads.outcome == 'ok'
                set { engLead: waits.leads.data.groups[0].members[0] }    ->  InDevelopment

    PendingAll:     status: Pending approval
      primary: Approval { group: approverGroup[data.form.primaryDomain], approveData: { engLead: user } }
      others:  Approval { over: data.form.otherDomains, group: approverGroup[item] }
      transitions:
        t_reject: when primary.rejected || others.rejected                ->  Rejected
        t_accept: when primary.approved && others.approved
                  set { engLead: primary.data.engLead }                   ->  InDevelopment

    PendingPrimary: status: Pending approval
      primary: Approval { group: approverGroup[data.form.primaryDomain], approveData: { engLead: user } }
      others:  Approval { over: data.form.otherDomains, group: approverGroup[item],
                          optional: true, notify: true }
      transitions:
        t_reject: when primary.rejected                                   ->  Rejected
        t_accept: when primary.approved
                  set { engLead: primary.data.engLead }                   ->  InDevelopment

    InDevelopment:  requires: [engLead]
      release: Task { assignee: user data.engLead, outcomes: [released] }
      transitions:
        t_release: when waits.release.task.outcome == 'released'          ->  Released

    Released: final
    Rejected: final
```

## Published elements

| Stage | Waits, in declared order | Notification rules |
|---|---|---|
| Route | none | |
| AssignLead | `leads` (call) | |
| PendingAll | `primary.members` (call), `primary.decision`, `others.members` (call), `others.decision[item]` | `PendingAll.primary.noApprover`, `PendingAll.others.noApprover` |
| PendingPrimary | `primary.members` (call), `primary.decision`, `others.decision[item]` (option) | `PendingPrimary.primary.noApprover`, `PendingPrimary.others.notify` |
| InDevelopment | `release.task` | |
| every stage | | `n_task` (default) |

## Notes

- **Route** is never seen: its transition fires in the turn that starts the request.
- **AssignLead** lasts as long as the directory call. If the call fails, or the group is empty (`members[0]` is an expression error), the request faults. Either way an admin fixes it in one admin turn: clear the fault and jump to AssignLead again (the directory is asked afresh), or set the eng lead and jump to InDevelopment.
- **Cancelling the others' actions** needs nothing on the transition: leaving a stage cancels the waits still open in it.
- **No eligible approver** never blocks submission. The request waits, and the `noApprover` rule alerts the workflow admins.
- **In PendingAll, `others.members` is opened even with no other domains** (an empty group list), because the expansion is static.

## Open

- May one person in two domains' approver groups approve for both? Assumed yes.
- "First member" depends on the order the directory returns.
===\n./workflows/change-request/test-cases.yaml\n===
# Test cases for the change request, against kernel/kernel-spec.md v2.9.
#
# These are data, not code. Each case is: a list of inputs, and for each input either the exact
# events the engine must append (in order) or a refusal. No harness exists yet.
#
# Conventions
# - The definition under test is definition.md, next to this file.
# - Element IDs are <composite instance>.<local name>: primary.decision, others.members, release.task.
# - Activation IDs are symbolic: a1 is the root, a2 is Route, a3 the next stage entered, and so on.
# - A wait is written <stage>.<element>[<foreach key>]@<activation>. seq is 1 everywhere and omitted.
# - Envelope fields (requestId, seq, at, turn, v, engineBuild) are not listed. `turn` of every
#   event in a block is the seq of that block's first event.
# - Payload fields not listed are not asserted.
# - `by: rita` is short for { type: user, id: rita }; `by: "connector:directory"` for
#   { type: connector, id: directory }; `by: "system:engine"` for { type: system, id: engine }.
# - `patch: { engLead: lee }` is short for [ { op: set, path: engLead, value: lee } ].
# - `notify` lists the notification rules the notifier must match for that turn. It is checked
#   against the notifier, not the engine: notifications are not history events.
#
# Paths are chosen by the primary domain. T1 to T7b: primary A, all domains approve (PendingAll).
# T8 to T10: any other primary, the primary alone decides (PendingPrimary). T11 and T12: primary D, no approval (AssignLead).

fixtures:
  constants:
    approverGroup: { A: grp-a, B: grp-b, C: grp-c }
    engLeadGroup: { D: grp-d-leads }
    allApprovalDomains: [A]          # A plays the platform domain
    noApprovalDomains: [D]
  directory:
    grp-a: [alice, rita]
    grp-b: [bob]
    grp-c: []
    grp-d-leads: [lee, lara]
  people: { requester: rita, engLead: lee, admin: root-admin }
  membersA: &members_a { groups: [ { id: grp-a, members: [alice, rita] } ] }
  membersB: &members_b { groups: [ { id: grp-b, members: [bob] } ] }
  membersC: &members_c { groups: [ { id: grp-c, members: [] } ] }
  leadsD: &leads_d { groups: [ { id: grp-d-leads, members: [lee, lara] } ] }
  leadsEmpty: &leads_empty { groups: [ { id: grp-d-leads, members: [] } ] }

# Shared turns.
openings:
  # Primary domain A (all domains approve), one other domain B.
  start_ab: &start_ab
    input: { start: { by: rita, input: { title: "Rotate keys", primaryDomain: A, otherDomains: [B] } } }
    expect:
      - [RequestStarted, { by: rita }]
      - [DataSet, { source: start, patch: { form: { title: "Rotate keys", primaryDomain: A, otherDomains: [B] } } }]
      - [StageEntered, { activation: a1, stage: root, parentActivation: null }]
      - [StageEntered, { activation: a2, stage: Route, parentActivation: a1 }]
      - [TransitionFired, { transition: t_all, activation: a2 }]
      - [StageExited, { activation: a2, mode: normal }]
      - [StageEntered, { activation: a3, stage: PendingAll, parentActivation: a1 }]
      - [WaitOpened, { wait: PendingAll.primary.members@a3, kind: call, connector: directory, op: membersOf, args: { groups: [grp-a] } }]
      - [WaitOpened, { wait: PendingAll.primary.decision@a3, kind: person, role: obligation, assignees: ["group:grp-a"] }]
      - [WaitOpened, { wait: PendingAll.others.members@a3, kind: call, connector: directory, op: membersOf, args: { groups: [grp-b] } }]
      - [WaitOpened, { wait: "PendingAll.others.decision[B]@a3", kind: person, role: obligation, assignees: ["group:grp-b"] }]
    notify: [n_task, n_task]
  # Primary domain A (all domains approve), one other domain C whose group is empty.
  start_ac: &start_ac
    input: { start: { by: rita, input: { title: "New dashboard", primaryDomain: A, otherDomains: [C] } } }
    expect:
      - [RequestStarted, { by: rita }]
      - [DataSet, { source: start }]
      - [StageEntered, { activation: a1, stage: root }]
      - [StageEntered, { activation: a2, stage: Route }]
      - [TransitionFired, { transition: t_all, activation: a2 }]
      - [StageExited, { activation: a2, mode: normal }]
      - [StageEntered, { activation: a3, stage: PendingAll }]
      - [WaitOpened, { wait: PendingAll.primary.members@a3, args: { groups: [grp-a] } }]
      - [WaitOpened, { wait: PendingAll.primary.decision@a3 }]
      - [WaitOpened, { wait: PendingAll.others.members@a3, args: { groups: [grp-c] } }]
      - [WaitOpened, { wait: "PendingAll.others.decision[C]@a3", assignees: ["group:grp-c"] }]
  primary_members_ok: &primary_members_ok
    input: { callResult: { wait: PendingAll.primary.members@a3, outcome: ok, data: *members_a } }
    expect:
      - [WaitCompleted, { wait: PendingAll.primary.members@a3, outcome: ok, by: "connector:directory" }]
    notify: []          # alice can approve; rita is the requester
  others_members_b_ok: &others_members_b_ok
    input: { callResult: { wait: PendingAll.others.members@a3, outcome: ok, data: *members_b } }
    expect:
      - [WaitCompleted, { wait: PendingAll.others.members@a3, outcome: ok, by: "connector:directory" }]
    notify: []
  others_members_c_ok: &others_members_c_ok
    input: { callResult: { wait: PendingAll.others.members@a3, outcome: ok, data: *members_c } }
    expect:
      - [WaitCompleted, { wait: PendingAll.others.members@a3, outcome: ok, by: "connector:directory" }]
    notify: [PendingAll.others.noApprover]
  # Primary domain B (the primary alone decides), one other domain A.
  start_domain_ab: &start_domain_ab
    input: { start: { by: rita, input: { title: "Add column", primaryDomain: B, otherDomains: [A] } } }
    expect:
      - [RequestStarted, { by: rita }]
      - [DataSet, { source: start }]
      - [StageEntered, { activation: a1, stage: root }]
      - [StageEntered, { activation: a2, stage: Route }]
      - [TransitionFired, { transition: t_domain, activation: a2 }]
      - [StageExited, { activation: a2, mode: normal }]
      - [StageEntered, { activation: a3, stage: PendingPrimary }]
      - [WaitOpened, { wait: PendingPrimary.primary.members@a3, args: { groups: [grp-b] } }]
      - [WaitOpened, { wait: PendingPrimary.primary.decision@a3, role: obligation, assignees: ["group:grp-b"] }]
      - [WaitOpened, { wait: "PendingPrimary.others.decision[A]@a3", role: option, assignees: ["group:grp-a"] }]
    notify: [n_task, PendingPrimary.others.notify]     # no members call and no noApprover rule for the optional approval
  # No-approval domain D.
  start_d: &start_d
    input: { start: { by: rita, input: { title: "Fix label", primaryDomain: D, otherDomains: [] } } }
    expect:
      - [RequestStarted, { by: rita }]
      - [DataSet, { source: start }]
      - [StageEntered, { activation: a1, stage: root }]
      - [StageEntered, { activation: a2, stage: Route }]
      - [TransitionFired, { transition: t_skip, activation: a2 }]
      - [StageExited, { activation: a2, mode: normal }]
      - [StageEntered, { activation: a3, stage: AssignLead }]
      - [WaitOpened, { wait: AssignLead.leads@a3, kind: call, connector: directory, op: membersOf, args: { groups: [grp-d-leads] } }]
    notify: []          # nobody is asked to approve

cases:

  - id: T1
    name: All-approve path, happy path with one other domain
    turns:
      - *start_ab
      - *primary_members_ok
      - *others_members_b_ok
      - input: { act: { by: bob, wait: "PendingAll.others.decision[B]@a3", outcome: approve, data: {} } }
        expect:
          - [WaitCompleted, { wait: "PendingAll.others.decision[B]@a3", outcome: approve, by: bob, evidence: { memberOf: [grp-b] } }]
      - input: { act: { by: alice, wait: PendingAll.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: PendingAll.primary.decision@a3, outcome: approve, by: alice, evidence: { memberOf: [grp-a] } }]
          - [TransitionFired, { transition: t_accept, activation: a3 }]
          - [DataSet, { source: transition, element: t_accept, patch: { engLead: lee } }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4, kind: person, role: obligation, assignees: ["user:lee"] }]
        notify: [n_task]
      - input: { act: { by: lee, wait: InDevelopment.release.task@a4, outcome: released, data: {} } }
        expect:
          - [WaitCompleted, { wait: InDevelopment.release.task@a4, outcome: released, by: lee }]
          - [TransitionFired, { transition: t_release, activation: a4 }]
          - [StageExited, { activation: a4, mode: normal }]
          - [StageEntered, { activation: a5, stage: Released, parentActivation: a1 }]
          - [RequestClosed, { stage: Released }]

  - id: T2
    name: All-approve path, no other domains; the primary approval alone accepts
    turns:
      - input: { start: { by: rita, input: { title: "Tune alert", primaryDomain: A, otherDomains: [] } } }
        expect:
          - [RequestStarted, { by: rita }]
          - [DataSet, { source: start }]
          - [StageEntered, { activation: a1, stage: root }]
          - [StageEntered, { activation: a2, stage: Route }]
          - [TransitionFired, { transition: t_all, activation: a2 }]
          - [StageExited, { activation: a2, mode: normal }]
          - [StageEntered, { activation: a3, stage: PendingAll }]
          - [WaitOpened, { wait: PendingAll.primary.members@a3, args: { groups: [grp-a] } }]
          - [WaitOpened, { wait: PendingAll.primary.decision@a3 }]
          - [WaitOpened, { wait: PendingAll.others.members@a3, args: { groups: [] } }]   # opened even for an empty list; no others.decision waits
      - input: { act: { by: alice, wait: PendingAll.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: PendingAll.primary.decision@a3, outcome: approve, by: alice }]
          - [TransitionFired, { transition: t_accept, activation: a3 }]
          - [DataSet, { source: transition, patch: { engLead: lee } }]
          - [WaitCancelled, { wait: PendingAll.primary.members@a3, cause: stage exit }]   # both directory calls were still in flight
          - [WaitCancelled, { wait: PendingAll.others.members@a3, cause: stage exit }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: InDevelopment }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4 }]
      - input: { callResult: { wait: PendingAll.primary.members@a3, outcome: ok, data: *members_a } }
        expect:
          - [CallResultLate, { wait: PendingAll.primary.members@a3, outcome: ok }]
        notify: []          # a late result does not trigger a no-approver rule

  - id: T3
    name: All-approve path, a domain has no eligible approver; the request is submitted and waits
    turns:
      - *start_ac
      - *primary_members_ok
      - *others_members_c_ok
    finalState: { activeStages: [root, PendingAll], open: [PendingAll.primary.decision@a3, "PendingAll.others.decision[C]@a3"], faulted: false }

  - id: T4
    name: Refused attempts write nothing to history
    turns:
      - *start_ab
      - input: { act: { by: rita, wait: PendingAll.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        refuse: { reason: may }              # rita is in grp-a but is the requester
        expect: []
      - input: { act: { by: bob, wait: PendingAll.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        refuse: { reason: not-assignee }     # bob is not in grp-a
        expect: []
      - input: { act: { by: alice, wait: PendingAll.primary.decision@a3, outcome: approve, data: {} } }
        refuse: { reason: invalid-data }     # engLead is required to approve
        expect: []

  - id: T5
    name: All-approve path, one rejection rejects the request and cancels the approvals still open
    turns:
      - *start_ab
      - *primary_members_ok
      - *others_members_b_ok
      - input: { act: { by: bob, wait: "PendingAll.others.decision[B]@a3", outcome: reject, data: { reason: "Out of scope" } } }
        expect:
          - [WaitCompleted, { wait: "PendingAll.others.decision[B]@a3", outcome: reject, by: bob }]
          - [TransitionFired, { transition: t_reject, activation: a3 }]
          - [WaitCancelled, { wait: PendingAll.primary.decision@a3, cause: stage exit }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: Rejected, parentActivation: a1 }]
          - [RequestClosed, { stage: Rejected }]
      - input: { act: { by: alice, wait: PendingAll.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        refuse: { reason: wait-not-open }
        expect: []

  - id: T6
    name: Admin skips a domain's approval and jumps, in one turn
    turns:
      - *start_ac
      - *primary_members_ok
      - *others_members_c_ok
      - input: { act: { by: alice, wait: PendingAll.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: PendingAll.primary.decision@a3, outcome: approve, by: alice }]   # t_accept is false: others.decision[C] is open
      - input:
          admin:
            by: root-admin
            reason: "Domain C has no approvers; approved out of band, ticket OPS-1"
            actions:
              - { skip: "PendingAll.others.decision[C]@a3" }
              - { setData: { engLead: lee } }
              - { jump: { from: PendingAll, to: InDevelopment } }
            waived: []
        expect:
          - [Overridden, { by: root-admin }]
          - [WaitSkipped, { wait: "PendingAll.others.decision[C]@a3" }]
          - [DataSet, { source: admin, patch: { engLead: lee } }]
          - [StageExited, { activation: a3, mode: forced }]
          - [StageEntered, { activation: a4, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4, assignees: ["user:lee"] }]

  - id: T6b
    name: A skip alone decides nothing and leaves the request stuck
    turns:
      - same-as: T6 turns 1 to 4
      - input:
          admin: { by: root-admin, reason: "Domain C has no approvers", actions: [ { skip: "PendingAll.others.decision[C]@a3" } ], waived: [] }
        expect:
          - [Overridden, { by: root-admin }]
          - [WaitSkipped, { wait: "PendingAll.others.decision[C]@a3" }]
          - [Faulted, { kind: stuck }]       # t_accept stays false; no obligation or call is open
    finalState: { activeStages: [root, PendingAll], open: [], faulted: true }

  - id: T7
    name: Admin jumps while the directory calls are in flight
    turns:
      - *start_ab
      - input:
          admin:
            by: root-admin
            reason: "Sev1 hotfix"
            actions:
              - { setData: { engLead: lee } }
              - { jump: { from: PendingAll, to: InDevelopment } }
            waived: []
        expect:
          - [Overridden, { by: root-admin }]
          - [DataSet, { source: admin, patch: { engLead: lee } }]
          - [WaitSkipped, { wait: PendingAll.primary.members@a3 }]
          - [WaitSkipped, { wait: PendingAll.primary.decision@a3 }]
          - [WaitSkipped, { wait: PendingAll.others.members@a3 }]
          - [WaitSkipped, { wait: "PendingAll.others.decision[B]@a3" }]
          - [StageExited, { activation: a3, mode: forced }]
          - [StageEntered, { activation: a4, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4 }]
      - input: { callResult: { wait: PendingAll.primary.members@a3, outcome: ok, data: *members_a } }
        expect:
          - [CallResultLate, { wait: PendingAll.primary.members@a3, outcome: ok }]

  - id: T7b
    name: A jump without the data the target stage requires is refused
    turns:
      - *start_ab
      - input:
          admin: { by: root-admin, reason: "Sev1 hotfix", actions: [ { jump: { from: PendingAll, to: InDevelopment } } ], waived: [] }
        refuse: { reason: requires-not-met, paths: [engLead] }
        expect: []

  - id: T8
    name: A CEL error rolls the turn back and faults the request
    turns:
      - input: { start: { by: rita, input: { title: "Typo domain", primaryDomain: Z, otherDomains: [] } } }
        expect:
          - [RequestStarted, { by: rita }]
          - [Faulted, { kind: error, element: PendingPrimary.primary.members }]    # approverGroup has no key Z; the routing is rolled back too
      - input:
          admin: { by: root-admin, reason: "Unknown domain; requester to resubmit", actions: [ { close: {} } ], waived: [] }
        expect:
          - [Overridden, { by: root-admin }]
          - [RequestClosed, { by: admin }]
    finalState: { activeStages: [], open: [], closed: true }

  - id: T9
    name: Domain path, another domain's decision has no effect; the primary alone accepts
    turns:
      - *start_domain_ab
      - input: { callResult: { wait: PendingPrimary.primary.members@a3, outcome: ok, data: *members_b } }
        expect:
          - [WaitCompleted, { wait: PendingPrimary.primary.members@a3, outcome: ok, by: "connector:directory" }]
        notify: []
      - input: { act: { by: alice, wait: "PendingPrimary.others.decision[A]@a3", outcome: reject, data: { reason: "Not keen" } } }
        expect:
          - [WaitCompleted, { wait: "PendingPrimary.others.decision[A]@a3", outcome: reject, by: alice }]   # recorded; no transition reads it
      - input: { act: { by: bob, wait: PendingPrimary.primary.decision@a3, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: PendingPrimary.primary.decision@a3, outcome: approve, by: bob }]
          - [TransitionFired, { transition: t_accept, activation: a3 }]
          - [DataSet, { source: transition, element: t_accept, patch: { engLead: lee } }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4, assignees: ["user:lee"] }]
        notify: [n_task]

  - id: T10
    name: Domain path, the primary's decision closes the other domains' open actions
    turns:
      - *start_domain_ab
      - input: { act: { by: bob, wait: PendingPrimary.primary.decision@a3, outcome: reject, data: { reason: "Duplicate" } } }
        expect:
          - [WaitCompleted, { wait: PendingPrimary.primary.decision@a3, outcome: reject, by: bob }]
          - [TransitionFired, { transition: t_reject, activation: a3 }]
          - [WaitCancelled, { wait: PendingPrimary.primary.members@a3, cause: stage exit }]
          - [WaitCancelled, { wait: "PendingPrimary.others.decision[A]@a3", cause: stage exit }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: Rejected, parentActivation: a1 }]
          - [RequestClosed, { stage: Rejected }]
      - input: { act: { by: alice, wait: "PendingPrimary.others.decision[A]@a3", outcome: approve, data: {} } }
        refuse: { reason: wait-not-open }
        expect: []

  - id: T11
    name: No-approval path, the eng lead is the first member of the domain's eng-lead group
    turns:
      - *start_d
      - input: { callResult: { wait: AssignLead.leads@a3, outcome: ok, data: *leads_d } }
        expect:
          - [WaitCompleted, { wait: AssignLead.leads@a3, outcome: ok, by: "connector:directory" }]
          - [TransitionFired, { transition: t_lead, activation: a3 }]
          - [DataSet, { source: transition, element: t_lead, patch: { engLead: lee } }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4, assignees: ["user:lee"] }]
        notify: [n_task]    # the only notification on this path

  - id: T12
    name: No-approval path, an empty eng-lead group faults; an admin retries by re-entering the stage
    turns:
      - *start_d
      - input: { callResult: { wait: AssignLead.leads@a3, outcome: ok, data: *leads_empty } }
        expect:
          - [WaitCompleted, { wait: AssignLead.leads@a3, outcome: ok, by: "connector:directory" }]
          - [Faulted, { kind: error, element: t_lead }]      # members[0] on an empty list
      - input:
          admin:
            by: root-admin
            reason: "Eng-lead group for D was empty; fixed in the directory"
            actions:
              - { clearFault: {} }
              - { jump: { from: AssignLead, to: AssignLead } }
            waived: []
        expect:
          - [Overridden, { by: root-admin }]
          - [StageExited, { activation: a3, mode: forced }]
          - [StageEntered, { activation: a4, stage: AssignLead, parentActivation: a1 }]
          - [WaitOpened, { wait: AssignLead.leads@a4, kind: call }]     # a new read; t_lead is false while it is open
      - input: { callResult: { wait: AssignLead.leads@a4, outcome: ok, data: *leads_d } }
        expect:
          - [WaitCompleted, { wait: AssignLead.leads@a4, outcome: ok }]
          - [TransitionFired, { transition: t_lead, activation: a4 }]
          - [DataSet, { source: transition, element: t_lead, patch: { engLead: lee } }]
          - [StageExited, { activation: a4, mode: normal }]
          - [StageEntered, { activation: a5, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a5 }]

  - id: T12b
    name: No-approval path, an admin bypasses the lookup by setting the eng lead
    turns:
      - same-as: T12 turns 1 to 2
      - input:
          admin:
            by: root-admin
            reason: "Eng-lead group for D is empty; lee confirmed by email"
            actions:
              - { clearFault: {} }
              - { setData: { engLead: lee } }
              - { jump: { from: AssignLead, to: InDevelopment } }
            waived: []
        expect:
          - [Overridden, { by: root-admin }]
          - [DataSet, { source: admin, patch: { engLead: lee } }]
          - [StageExited, { activation: a3, mode: forced }]
          - [StageEntered, { activation: a4, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release.task@a4, assignees: ["user:lee"] }]

  - id: T12c
    name: No-approval path, a failed directory lookup faults; an admin retries by re-entering the stage
    turns:
      - *start_d
      - input: { callResult: { wait: AssignLead.leads@a3, outcome: failed, data: { error: "group not found" } } }
        expect:
          - [WaitCompleted, { wait: AssignLead.leads@a3, outcome: failed, by: "connector:directory" }]
          - [Faulted, { kind: error, element: AssignLead.leads }]      # leads has no onFailure: outcome
      - same-as: T12 turns 3 to 4

  - id: T3b
    name: All-approve path, a failed membership check does not stop the request
    turns:
      - *start_ab
      - input: { callResult: { wait: PendingAll.primary.members@a3, outcome: failed, data: { error: "directory unavailable" } } }
        expect:
          - [WaitCompleted, { wait: PendingAll.primary.members@a3, outcome: failed, by: "connector:directory" }]   # onFailure: outcome; no fault
        notify: [PendingAll.primary.noApprover]
    finalState: { activeStages: [root, PendingAll], faulted: false }
