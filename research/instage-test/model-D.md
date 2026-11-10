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
