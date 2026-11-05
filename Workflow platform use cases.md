# Workflow platform: use cases

Nov 5, 2026 · @Yuhau Lin

The workflow platform has six use cases. Only UC1, the change-request intake, is in the MVP; the other five shape what the MVP must leave room for. This doc records what each use case needs, as described in our design discussions. How the engine meets those needs is in the design doc.

- **Stated** requirements came directly from the description of the use case.
- **Inferred** requirements are ones the design review added; each is marked *(inferred)*.
- **Phase**: MVP means the first release, which is UC1 at parity. Later means after the MVP, and those use cases have not been ordered yet.

## At a glance

| Use case | Who starts it | Trigger | What it adds to the platform | Phase |
| --- | --- | --- | --- | --- |
| UC1 Change-request intake | Anyone with a change to request | A submitted multi-page form | Conditional form pages, approvals routed by request type and entitlement, eng lead assignment, stage lifecycle | MVP |
| UC2 Tech debt initiatives | Almost anyone | A submitted idea | Initiatives with varying forms, parallel sub-workflows that tie back and can change the parent's path | Later |
| UC3 Architecture design review | A design author | A submitted design | Heavy back-and-forth, interrupts, send-back several stages at once | Later |
| UC4 Metrics recertification | The metrics program team | A date, every year | Time-based triggers over an upstream inventory, run as a campaign | Later |
| UC5 Domain-routed change requests | Same as UC1 | Same as UC1 | Approvers from each domain's entitlement, optional cross-domain approvals, auto-approval, Jira ticket creation | Later |
| UC6 Metadata change requests | Metadata users and domain owners | A request to change metadata | Forms generated from upstream schemas, existing values prefilled, "leave unchanged" vs "clear", downstream write | Later |

UC5 and UC6 are variants of UC1, so they run in the same app as UC1, Change Management. UC2, UC3 and UC4 would each be a separate app on its own pages, sharing the engine.

## UC1 Change-request intake (MVP)

UC1 rebuilds the existing Change Management intake as the first workflow on the engine. It needs parity with the current app, except where we choose to drop behavior that is bad. The current app is simpler than a typical legacy system, and parity will be checked against its code.

**Actors:** the requester, approvers (chosen by request type and entitlements), the eng lead, and the dev team as super-admins.

**Lifecycle**

1. The requester fills in a multi-page form. Some pages and questions show only under conditions.
2. On submit, the request becomes a change request in **Pending**.
3. Approvals are required, depending on request type and entitlements.
4. One of the approvers assigns an eng lead.
5. Once the required approvals are in, the request moves to **In development**.
6. The eng lead moves it to **Released**.
7. A request can be **Rejected** at approval. Rejection is terminal.

**Stated requirements**

- Approver routing by request type. A simple lookup from request type to approver group covers this, so no decision-table feature is needed.
- The eng lead picker shows only leads for the request's domain. The list comes from upstream data, not a static list.
- Labels and options can depend on other values in the request.
- Validations that compare fields, such as "end date at least one month after start date".
- An empty approver list does not block submission. The request waits for approvers, and the owner is alerted.
- Everything that happens is kept in an append-only history and retained indefinitely.
- Definitions are published through an API and an admin page that accepts JSON. There is no server CLI access.
- The dev team can act as break-glass super-admins to unblock anything during an incident. This includes approving their own requests.
- Admins can force a request past a stage. Any requirement they skip is recorded as waived, never as approved by someone.
- Scale is low: about 1 request every 10 seconds across all apps.

**Inferred requirements**

- *(inferred)* Saved drafts. A draft always moves to the latest workflow version at submit.
- *(inferred)* Readable IDs such as CR-1234, numbered above the legacy system's highest ID.
- *(inferred)* Withdraw and close reasons, comments, SLA reminders, and parity with the legacy app's reports.
- *(inferred)* A per-app list of the viewer's open action items. There is no inbox shared across apps.
- *(inferred)* Past participants keep view access only.

**Out of the MVP:** attachments, because there is no file storage yet; migrating in-flight requests to a new workflow version, since definitions are frozen per request; and importing legacy requests.

**Cutover:** requests already in flight finish in the legacy app, and new requests start in the new one. Importing legacy requests is reconsidered after release, if it turns out to be easy.

**Integrations:** an upstream user directory for the people picker. Notifications go through the existing email and Slack service.

## UC2 Tech debt initiatives (later)

UC2 replaces a very manual process for turning a tech debt idea into a company-wide initiative. Only the intake is in scope: going from idea to a created initiative. Distributing the initiative to apps and teams already has solutions. The "tech debt" can also be non-technical debt.

**Actors:** almost anyone can propose an initiative. The tech debt program team creates and distributes initiatives.

**Stated requirements**

- Initiatives can have very different forms. The program team will probably prescribe a standard shape with shared envelope fields, though some initiatives may be structurally different. Supporting variants through interfaces is deferred.
- An initiative can start sub-workflows that run alongside it, such as "provide these extra materials" or "get this kind of approval".
- Sub-workflows can tie back in: what happens in a sub-workflow can change which path the parent takes.
- A step can start a sub-workflow without waiting for it (fire-and-forget), and a later step can still wait on it. In the original notation:
  - `A /=> S`: A starts S and does not wait.
  - `A *=> B, C, D`: A branches to one of B, C or D.
  - `B => E`, `C => E`, `D => E`, `S => E`: E requires one of B, C or D, and also S.
- Whether a sub-workflow outlives its parent is the parent's setting. The parent either fires and forgets, or has a later stage that needs the child's output.
- Conditional chaining of separate workflows may cover many cases without nesting.
- This program will produce most of the platform's traffic.

**Inferred requirements**

- *(inferred)* Parent and child workflows are linked to each other but to no other workflow type, so links work across app boundaries.
- *(inferred)* When a parent is sent back and runs a stage again, it decides whether to start the child again. By default it doesn't if the child's inputs haven't changed, and a condition can override that.

## UC3 Architecture design review (later)

UC3 is a simple approval model with a lot of back-and-forth: someone submits an architecture design and the architecture team reviews it. Our team owns this workflow because we already support approvals. That was agreed with the design review team and the form creator team.

**Actors:** the design author, and the architecture team as reviewers.

**Stated requirements**

- Many back-and-forth transitions between the author and reviewers.
- Interrupts during review. These may be separate parallel branches that do their own back-and-forth.
- Sending a design back several stages at once ("back to the drawing board"), not one step at a time.
- A flow started mid-process keeps its own status when the main process is sent back. For example, stage 5 starts a flow and stage 10 sends the design back to stage 1; the stage-5 flow keeps running.
- An in-flight review may have to follow an updated process. So a workflow owner can choose to let a definition change apply to requests already in flight, and decide how those requests react.

**From the versioning discussion**

- Updating an in-flight request is a bulk edit that also changes its version. Like Flyway, an old request moves forward one version at a time, and each version defines how to migrate from the one before.
- Fields that become required may be left blank during the update. They block only the next transition, not the update itself.
- Reopening a closed request is an option set per workflow.

**Inferred requirements**

- *(inferred)* A "changes requested" outcome alongside approve and reject.

## UC4 Metrics recertification (later)

UC4 is a yearly campaign by the metrics program team. It confirms that each metric is still relevant and not orphaned. Metrics multiply because executives and teams keep asking for new ones. Most of what UC4 adds is scheduling, not workflow logic.

**Actors:** the metrics program team runs the campaign. Metric owners recertify their metrics.

**Stated requirements**

- A workflow starts automatically when a set date arrives.
- A time-based trigger can also interrupt a running workflow, not only start one.
- The list of metrics comes from an upstream inventory, which is the source of truth. Reading it is an upstream integration.
- Notifications to owners are a downstream integration. The engine either emits events that the notification system consumes, or pushes to it directly.
- This would be part of a calendar module, which comes later. In it, obligations are records that set dates and what happens on them, and starting a workflow is one possible action. People can create one-off or recurring obligations, and upstream events might create them automatically.

**Inferred requirements**

- *(inferred)* An obligation is a duty with its own status and outcome; the dates only trigger actions.
- *(inferred)* When a new cycle starts, it replaces any unfinished request from the previous cycle.
- *(inferred)* What happens to a metric whose owner has left or doesn't respond: escalation, reassignment, or retiring the metric.

## UC5 Domain-routed change requests (later)

UC5 configures Change Management so that approvals follow the request's domain, and an approved request opens a Jira ticket. It must be configurable in the UI with very good UX. Until that UI exists, the data model and expression language describe it.

| Request | Approval | Approved by | Jira "product owner" field |
| --- | --- | --- | --- |
| Domain a, b or c | Normal approval by members of the domain's product owner entitlement | The approver | The approver |
| Request type d | Automatic | A dedicated system identity | A specific, fixed person |

**Stated requirements**

- Product owners of other domains can also approve, but only the request domain's approval counts.
- Once a request is approved, a Jira ticket is created. Other Jira fields are filled from values in the request.
- Domains exist outside Change Management, including the entitlement for each domain. So domain configuration comes from upstream data, and perhaps later from upstream events.
- Some services are both an upstream source and a downstream target. Jira is a downstream target here.
- Auto-approval is a separate branch that skips the approval step. It writes the same fields an approval would, such as setting "approved by" to the system identity.

**Inferred requirements**

- *(inferred)* If Jira creation fails, the request is approved but has no ticket. Treat it as an alerted incident, not a state the engine resolves on its own.
- *(inferred)* Retries must not create duplicate tickets: the ticket key is derived from the request ID.

## UC6 Metadata change requests (later)

UC6 makes Change Management the way to change platform metadata. Today the two features are fully decoupled, so they drift apart. Metadata becomes both an upstream source (current values) and a downstream target (the update). Metadata is stored as Postgres jsonb and may expand beyond metrics to modules, domains, reports and user preferences.

**Actors:** requesters changing metadata on an item, and domain owners changing the metadata schema itself.

**Stated requirements**

- Metadata is fully polymorphic, so no fixed form fits it. Forms are generated from the metadata schema by rules. Whether those rules are built into the engine or configurable is open.
- Fields show their existing values. Without that prefill the UX is unacceptable.
- A request must tell "leave this unchanged" apart from "clear this". The engine, rather than special values each workflow defines, should handle this.
- Some field rules span fields. For example, two fields form a range and the minimum must be below the maximum. Whether such rules and tooltips live in metadata or in Change Management is open.
- Shared concepts, such as "this field is an enum of domains", may need a platform-level source of configurable data that both features read.
- A second level: domain owners request changes to the schema, for example adding a documentation-link field. That form edits classes instead of instances. There are two levels at most.
- Metadata can still be edited outside Change Management. So an in-flight request may drift from the current values, and that is an accepted risk.
- The metadata write is an event or adapter outside the engine, not engine code. If the write fails after approval, the system alerts, and it is handled as an incident.

**Inferred requirements**

- *(inferred)* Applying a change checks first that the fields haven't changed since the request was made, so a stale change can't silently overwrite a newer edit.
- *(inferred)* When the metadata schema changes, decide what happens to requests built on the old schema.

## Across all use cases

These requirements apply to every app on the engine. They came up while discussing the use cases above.

| Area | Requirement | Use cases that drive it |
| --- | --- | --- |
| Separate apps | Each workflow app has its own pages and its own list of the viewer's action items. Apps share the engine and its tables, grouped by a namespace column. | All |
| UX | The UX lives in our app and uses the company component library. Owners configure workflows in a UI, not code. | All |
| Logic | Conditions, computed values and validations use one expression language (CEL), with a visual builder and a formula bar. | UC1, UC5, UC6 |
| Upstream data | Workflows read external data: users and entitlements, domains, the metrics inventory, metadata values and schemas. | UC1, UC4, UC5, UC6 |
| Downstream actions | Workflows write to or notify external systems: email and Slack, Jira, metadata. If a downstream call fails, it is alerted and handled as an incident. | UC1, UC5, UC6 |
| Forms | Forms are probably built with the internal form creator app, through its API. Whether it fits hasn't been evaluated yet. | All |
| History | An append-only history of everything, kept forever, from which current state can be rebuilt. | All |
| Versioning | Requests are frozen to the definition version they started on. Owners can later allow in-flight requests to update. | UC1 (frozen), UC3 (updates) |
| Admin powers | The dev team has break-glass super-admin access, which can do anything, including approve its own requests. Safeguards come from accountability, not hard-coded rules. | All |
| Publishing | Definitions are published through an API and an admin page that accepts JSON. There is no server CLI access. | All |
| Scale | About 1 request every 10 seconds, mostly from UC2. | All |

## Open questions

- [ ] UC1: which directory API backs the people picker and the eng lead list?
- [ ] UC1: after what date are requests still open in the legacy app imported or closed?
- [ ] UC1: does the legacy app have drafts or attachments? If it has attachments, dropping them is a parity exception.
- [ ] UC1: does the internal form creator fit, and what adapters would it need?
- [ ] Later use cases: in what order do UC2 to UC6 ship?
- [ ] UC2: who exactly may propose an initiative, and how far apart can initiative shapes be?
- [ ] UC3: who updates an in-flight review to a new version, the workflow owner or the request owner?
- [ ] UC4: which system is the metrics inventory, and what happens to metrics that no one recertifies?
- [ ] UC5: where does domain data live, and who owns it?
- [ ] UC6: are schema-to-form rules built into the engine or configurable, and do cross-field rules live in metadata or Change Management?
