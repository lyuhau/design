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
