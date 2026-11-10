# Expansion test battery

Each case is a workflow expanded into the kernel's blocks and events on paper. A case passes when it uses only what the kernel spec defines. The battery is also the record of why fields exist: if a case can no longer be expressed, something it needs was removed.

Cases the MVP builds have test cases as data in `test-cases/` (definition, inputs, exact events expected). The others stay on paper, with small replay-only cases for the insurance fields.

| Case | Workflow | Built in the MVP | Status | Test data |
|---|---|---|---|---|
| C1 | Change request | Yes | Passes on spec v2.7 | `test-cases/c1-change-request.yaml` (T1 to T8) |
| C2 | Metric change control | No | Expressible with reserved features; the revise-and-reapprove loop is a known weak spot | Paper |
| C3 | Checklist item ticked, un-ticked, re-ticked | No | Representation only | `test-cases/replay-only.yaml` R2 |
| P1 | Start without waiting, join later | No | Passes with child requests | Paper; R3 covers the parent field |
| P2 | Work that survives a send-back | No | Passes with child requests | Paper; R3 |
| P3 | Fan-out where each leg runs several steps | No | Passes with child requests | Paper |
| P4 | Two stage paths active at once | No | Representation only | `test-cases/replay-only.yaml` R1 |
| I1 | Ten repeated in-stage actions | No | 3 of 10 clean with repeatable waits; the rest need an undesigned layer; history is safe for all | Paper; reports in `instage-test/` |

## C1. Change request

The definition and the happy-path trace are in section 9 of `kernel-spec.md`. The edge cases are T2 to T8 in `test-cases/c1-change-request.yaml`.

Passes if: every trace uses only the events in section 5 of the spec.

Needs: `foreach` on person waits; the guarded wait-status record; `CallResultLate`; admin skip of a single wait; stage `requires` with supply-or-waive on a jump; notification rules.

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

Ten patterns, each expanded under three models: data-driven (an action is a validated write), event-driven (named events with handlers), and the hybrid in the spec (a repeatable wait with its own Set). A fourth agent tried to show that the history favours one model. Reports: `instage-test/`.

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
