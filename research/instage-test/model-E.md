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
