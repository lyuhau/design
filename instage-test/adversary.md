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
