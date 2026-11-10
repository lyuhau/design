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
