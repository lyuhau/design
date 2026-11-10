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
