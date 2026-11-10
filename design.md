===\n./expansion-battery.md\n===
# Expansion test battery

Each case is a workflow expanded into the kernel's blocks and events on paper. A case passes when it uses only what the kernel spec defines. The battery is also the record of why fields exist: if a case can no longer be expressed, something it needs was removed.

Cases the MVP builds have test cases as data in `test-cases/` (definition, inputs, exact events expected). The others stay on paper, with small replay-only cases for the insurance fields.

| Case | Workflow | Built in the MVP | Status | Test data |
|---|---|---|---|---|
| C1 | Change request | Yes | Passes on spec v2.4 | `test-cases/c1-change-request.yaml` (T1 to T8) |
| C2 | Metric change control | No | Expressible with reserved features; the revise-and-reapprove loop is a known weak spot | Paper |
| C3 | Checklist item ticked, un-ticked, re-ticked | No | Representation only | `test-cases/replay-only.yaml` R2 |
| P1 | Start without waiting, join later | No | Passes with child requests | Paper; R3 covers the parent field |
| P2 | Work that survives a send-back | No | Passes with child requests | Paper; R3 |
| P3 | Fan-out where each leg runs several steps | No | Passes with child requests | Paper |
| P4 | Two stage paths active at once | No | Representation only | `test-cases/replay-only.yaml` R1 |

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
===\n./test-cases/replay-only.yaml\n===
# Replay-only cases, against kernel-spec.md v2.4.
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
===\n./test-cases/c1-change-request.yaml\n===
# Test cases for the change request (battery case C1), against kernel-spec.md v2.4.
#
# These are data, not code. Each case is: a list of inputs, and for each input either the exact
# events the engine must append (in order) or a refusal. No harness exists yet.
#
# Conventions
# - The definition under test is the one in kernel-spec.md section 9.
# - Activation IDs are symbolic: a1 is the root, a2 the first child stage entered, and so on.
# - A wait is written <stage>.<wait>[<foreach key>]@<activation>. seq is 1 everywhere and omitted.
# - Envelope fields (requestId, seq, at, turn, v, engineBuild) are not listed. `turn` of every
#   event in a block is the seq of that block's first event.
# - Payload fields not listed are not asserted.
# - `notify` lists the notification rules the notifier must match for that turn. It is checked
#   against the notifier, not the engine: notifications are not history events.

fixtures:
  constants:
    approverGroup: { A: grp-a, B: grp-b, C: grp-c }
  directory:
    grp-a: [alice, rita]
    grp-b: [bob]
    grp-c: []
  people: { requester: rita, engLead: lee, admin: root-admin }
  membersResult: &members_ab
    groups:
      - { id: grp-a, members: [alice, rita] }
      - { id: grp-b, members: [bob] }
  membersResultC: &members_ac
    groups:
      - { id: grp-a, members: [alice, rita] }
      - { id: grp-c, members: [] }

# Shared opening turn for a request with primary domain A and one other domain B.
openings:
  start_ab: &start_ab
    input: { start: { by: rita, input: { title: "Rotate keys", primaryDomain: A, otherDomains: [B] } } }
    expect:
      - [RequestStarted, { by: rita }]
      - [DataSet, { source: start, patch: { form: { title: "Rotate keys", primaryDomain: A, otherDomains: [B] } } }]
      - [StageEntered, { activation: a1, stage: root, parentActivation: null }]
      - [StageEntered, { activation: a2, stage: Pending, parentActivation: a1 }]
      - [WaitOpened, { wait: Pending.members@a2, kind: call, connector: directory, op: membersOf, args: { groups: [grp-a, grp-b] } }]
      - [WaitOpened, { wait: Pending.primary@a2, kind: person, role: obligation, assignees: ["group:grp-a"] }]
      - [WaitOpened, { wait: "Pending.others[B]@a2", kind: person, role: obligation, assignees: ["group:grp-b"] }]
    notify: [n_task, n_task]
  members_ok: &members_ok
    input: { callResult: { wait: Pending.members@a2, outcome: ok, data: *members_ab } }
    expect:
      - [WaitCompleted, { wait: Pending.members@a2, outcome: ok, by: "connector:directory" }]
    notify: []

cases:

  - id: T1
    name: Happy path with one other domain
    turns:
      - *start_ab
      - *members_ok
      - input: { act: { by: bob, wait: "Pending.others[B]@a2", outcome: approve, data: {} } }
        expect:
          - [WaitCompleted, { wait: "Pending.others[B]@a2", outcome: approve, by: bob, evidence: { memberOf: [grp-b] } }]
      - input: { act: { by: alice, wait: Pending.primary@a2, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: Pending.primary@a2, outcome: approve, by: alice, evidence: { memberOf: [grp-a] } }]
          - [TransitionFired, { transition: t_accept, activation: a2 }]
          - [DataSet, { source: transition, patch: { engLead: lee } }]
          - [StageExited, { activation: a2, mode: normal }]
          - [StageEntered, { activation: a3, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release@a3, kind: person, role: obligation, assignees: ["user:lee"] }]
        notify: [n_task]
      - input: { act: { by: lee, wait: InDevelopment.release@a3, outcome: released, data: {} } }
        expect:
          - [WaitCompleted, { wait: InDevelopment.release@a3, outcome: released, by: lee }]
          - [TransitionFired, { transition: t_release, activation: a3 }]
          - [StageExited, { activation: a3, mode: normal }]
          - [StageEntered, { activation: a4, stage: Released, parentActivation: a1 }]
          - [RequestClosed, { stage: Released }]

  - id: T2
    name: No other domains; the primary approval alone accepts
    turns:
      - input: { start: { by: rita, input: { title: "Tune alert", primaryDomain: A, otherDomains: [] } } }
        expect:
          - [RequestStarted, { by: rita }]
          - [DataSet, { source: start }]
          - [StageEntered, { activation: a1, stage: root }]
          - [StageEntered, { activation: a2, stage: Pending }]
          - [WaitOpened, { wait: Pending.members@a2, args: { groups: [grp-a] } }]
          - [WaitOpened, { wait: Pending.primary@a2 }]
      - input: { act: { by: alice, wait: Pending.primary@a2, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: Pending.primary@a2, outcome: approve, by: alice }]
          - [TransitionFired, { transition: t_accept, activation: a2 }]
          - [DataSet, { source: transition, patch: { engLead: lee } }]
          - [WaitCancelled, { wait: Pending.members@a2, cause: stage exit }]   # the directory call was still in flight
          - [StageExited, { activation: a2, mode: normal }]
          - [StageEntered, { activation: a3, stage: InDevelopment }]
          - [WaitOpened, { wait: InDevelopment.release@a3 }]
      - input: { callResult: { wait: Pending.members@a2, outcome: ok, data: { groups: [{ id: grp-a, members: [alice, rita] }] } } }
        expect:
          - [CallResultLate, { wait: Pending.members@a2, outcome: ok }]
        notify: []          # a late result does not trigger the no-approver rule

  - id: T3
    name: A domain has no eligible approver; the request is submitted and waits
    turns:
      - input: { start: { by: rita, input: { title: "New dashboard", primaryDomain: A, otherDomains: [C] } } }
        expect:
          - [RequestStarted, { by: rita }]
          - [DataSet, { source: start }]
          - [StageEntered, { activation: a1, stage: root }]
          - [StageEntered, { activation: a2, stage: Pending }]
          - [WaitOpened, { wait: Pending.members@a2, args: { groups: [grp-a, grp-c] } }]
          - [WaitOpened, { wait: Pending.primary@a2 }]
          - [WaitOpened, { wait: "Pending.others[C]@a2", assignees: ["group:grp-c"] }]
      - input: { callResult: { wait: Pending.members@a2, outcome: ok, data: *members_ac } }
        expect:
          - [WaitCompleted, { wait: Pending.members@a2, outcome: ok }]
        notify: [n_no_approver]
    finalState: { activeStages: [root, Pending], open: [Pending.primary@a2, "Pending.others[C]@a2"], faulted: false }

  - id: T4
    name: Refused attempts write nothing to history
    turns:
      - *start_ab
      - input: { act: { by: rita, wait: Pending.primary@a2, outcome: approve, data: { engLead: lee } } }
        refuse: { reason: may }              # rita is in grp-a but is the requester
        expect: []
      - input: { act: { by: bob, wait: Pending.primary@a2, outcome: approve, data: { engLead: lee } } }
        refuse: { reason: not-assignee }     # bob is not in grp-a
        expect: []
      - input: { act: { by: alice, wait: Pending.primary@a2, outcome: approve, data: {} } }
        refuse: { reason: invalid-data }     # engLead is required to approve
        expect: []

  - id: T5
    name: One rejection rejects the request and cancels the approvals still open
    turns:
      - *start_ab
      - *members_ok
      - input: { act: { by: bob, wait: "Pending.others[B]@a2", outcome: reject, data: { reason: "Out of scope" } } }
        expect:
          - [WaitCompleted, { wait: "Pending.others[B]@a2", outcome: reject, by: bob }]
          - [TransitionFired, { transition: t_reject, activation: a2 }]
          - [WaitCancelled, { wait: Pending.primary@a2, cause: stage exit }]
          - [StageExited, { activation: a2, mode: normal }]
          - [StageEntered, { activation: a3, stage: Rejected, parentActivation: a1 }]
          - [RequestClosed, { stage: Rejected }]
      - input: { act: { by: alice, wait: Pending.primary@a2, outcome: approve, data: { engLead: lee } } }
        refuse: { reason: wait-not-open }
        expect: []

  - id: T6
    name: Admin skips a domain's approval and jumps, in one turn
    turns:
      - input: { start: { by: rita, input: { title: "New dashboard", primaryDomain: A, otherDomains: [C] } } }
        expect: same-as T3 turn 1
      - input: { callResult: { wait: Pending.members@a2, outcome: ok, data: *members_ac } }
        expect:
          - [WaitCompleted, { wait: Pending.members@a2, outcome: ok }]
      - input: { act: { by: alice, wait: Pending.primary@a2, outcome: approve, data: { engLead: lee } } }
        expect:
          - [WaitCompleted, { wait: Pending.primary@a2, outcome: approve, by: alice }]   # t_accept is false: others[C] is open
      - input:
          admin:
            by: root-admin
            reason: "Domain C has no approvers; approved out of band, ticket OPS-1"
            actions:
              - { skip: "Pending.others[C]@a2" }
              - { setData: { engLead: lee } }
              - { jump: { from: Pending, to: InDevelopment } }
            waived: []
        expect:
          - [Overridden, { by: root-admin }]
          - [WaitSkipped, { wait: "Pending.others[C]@a2" }]
          - [DataSet, { source: admin, patch: { engLead: lee } }]
          - [StageExited, { activation: a2, mode: forced }]
          - [StageEntered, { activation: a3, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release@a3, assignees: ["user:lee"] }]

  - id: T6b
    name: A skip alone decides nothing and leaves the request stuck
    turns:
      - same-as: T6 turns 1 to 3
      - input:
          admin: { by: root-admin, reason: "Domain C has no approvers", actions: [ { skip: "Pending.others[C]@a2" } ], waived: [] }
        expect:
          - [Overridden, { by: root-admin }]
          - [WaitSkipped, { wait: "Pending.others[C]@a2" }]
          - [Faulted, { kind: stuck }]       # t_accept stays false; no obligation or call is open
    finalState: { activeStages: [root, Pending], open: [], faulted: true }

  - id: T7
    name: Admin jumps while the directory call is in flight
    turns:
      - *start_ab
      - input:
          admin:
            by: root-admin
            reason: "Sev1 hotfix"
            actions:
              - { setData: { engLead: lee } }
              - { jump: { from: Pending, to: InDevelopment } }
            waived: []
        expect:
          - [Overridden, { by: root-admin }]
          - [DataSet, { source: admin, patch: { engLead: lee } }]
          - [WaitSkipped, { wait: Pending.members@a2 }]
          - [WaitSkipped, { wait: Pending.primary@a2 }]
          - [WaitSkipped, { wait: "Pending.others[B]@a2" }]
          - [StageExited, { activation: a2, mode: forced }]
          - [StageEntered, { activation: a3, stage: InDevelopment, parentActivation: a1 }]
          - [WaitOpened, { wait: InDevelopment.release@a3 }]
      - input: { callResult: { wait: Pending.members@a2, outcome: ok, data: *members_ab } }
        expect:
          - [CallResultLate, { wait: Pending.members@a2, outcome: ok }]

  - id: T7b
    name: A jump without the data the target stage requires is refused
    turns:
      - *start_ab
      - input:
          admin: { by: root-admin, reason: "Sev1 hotfix", actions: [ { jump: { from: Pending, to: InDevelopment } } ], waived: [] }
        refuse: { reason: requires-not-met, paths: [engLead] }
        expect: []

  - id: T8
    name: A CEL error rolls the turn back and faults the request
    turns:
      - input: { start: { by: rita, input: { title: "Typo domain", primaryDomain: Z, otherDomains: [] } } }
        expect:
          - [RequestStarted, { by: rita }]
          - [Faulted, { kind: error, element: Pending.members }]    # approverGroup has no key Z
      - input:
          admin: { by: root-admin, reason: "Unknown domain; requester to resubmit", actions: [ { close: {} } ], waived: [] }
        expect:
          - [Overridden, { by: root-admin }]
          - [RequestClosed, { by: admin }]
    finalState: { activeStages: [], open: [], closed: true }
===\n./design.md\n===
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
    <span class="pill plain">Kernel spec v2.4</span>
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
    <code>kernel-spec.md</code> (the kernel, in full), <code>expansion-battery.md</code> (workflows expanded on paper to test the kernel), and <code>test-cases/</code> (the change request as test data). Version 2.1 of this doc, with the earlier design and the detail for later use cases, is in this page's version history.
  </div>
</section>

<section id="scope">
  <h2>2. Scope</h2>
  <div class="tablewrap"><table>
    <thead><tr><th>In the first release</th><th>Not in the first release</th></tr></thead>
    <tbody>
      <tr><td>The change request workflow, at parity with the existing product (with intentional exceptions where it is bad)</td><td>The five later use cases: tech debt initiatives, architecture review, metrics recertification, domain routing with Jira, metadata changes</td></tr>
      <tr><td>Multi-domain approval: every domain's approvers approve; the primary domain's approver picks the eng lead</td><td>Updating a request in flight to a newer definition (migrations)</td></tr>
      <tr><td>Publishing a definition through the API and an admin page that accepts JSON</td><td>A visual workflow editor and a library of composites</td></tr>
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
  <p>The kernel is the small set of parts the engine executes. The full rules are in <code>kernel-spec.md</code>.</p>
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
  <p>A request has one primary domain and zero or more other domains, taken from the form. It only moves forward.</p>
  <div class="diagram">
    <div class="flow">
      <div class="st"><b>Pending</b><span>One approval per domain. The primary domain's approver picks the eng lead to approve. A directory call records who can approve.</span></div>
      <div class="ar">all approve</div>
      <div class="st"><b>In development</b><span>The eng lead marks the request released.</span></div>
      <div class="ar">released</div>
      <div class="st final"><b>Released</b><span>Final.</span></div>
    </div>
    <p style="margin:12px 0 0;font-size:13.5px;color:var(--muted)">Any one rejection in Pending moves the request to <strong>Rejected</strong> (final) and cancels the approvals still open.</p>
  </div>
  <ul>
    <li><strong>Submission never blocks.</strong> If a domain has nobody able to approve, the request still enters Pending and waits. A notification rule alerts the workflow admins from the recorded directory result.</li>
    <li><strong>Requesters cannot approve their own request.</strong> Group membership is checked when the person acts, and the lookup is recorded with the approval.</li>
    <li><strong>An admin can skip one domain's approval,</strong> but a skip never counts as an approval. To move the request on, the admin also jumps it forward and supplies the eng lead if nobody picked one.</li>
  </ul>
  <p>The definition and the happy-path events are in section 9 of the kernel spec. Ten cases (happy path, no other domains, no eligible approver, refused attempts, rejection, admin skip and jump, a jump during an in-flight call, an expression error) are written as test data in <code>test-cases/c1-change-request.yaml</code>.</p>
  <p><span class="pill open">To confirm</span> Three assumptions about the existing product: approvals for all domains run in parallel; one rejection rejects the whole request; a person in two domains' groups may approve for both.</p>
</section>

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
    <li>The first release has one hand-written expansion for approvals. There is no composite library.</li>
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
      <tr><td class="n">M2</td><td>Change request behaviour</td><td>All cases in <code>test-cases/</code> pass, plus cases added from the parity checklist.</td></tr>
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
      <tr><td><span class="pill later">Later</span> Repeatable waits</td><td>A second instance of the same wait within one stage entry.</td><td>Checklists that can be un-ticked</td></tr>
      <tr><td><span class="pill later">Later</span> In-flight updates</td><td>Moving a request to a newer definition version.</td><td>Architecture review</td></tr>
      <tr><td><span class="pill later">Later</span> Scheduling</td><td>Date-triggered starts and recurring duties, possibly as a separate "obligations" feature.</td><td>Metrics recertification</td></tr>
      <tr><td><span class="pill later">Later</span> Workflow editor and composites</td><td>Owners configure workflows in a UI from ready-made parts.</td><td>Every later app</td></tr>
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
    <li>Do the three approval assumptions in section 5 match the existing product?</li>
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
===\n./kernel-spec.md\n===
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
