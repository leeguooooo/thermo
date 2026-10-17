---
name: browser-workflow-evidence
description: Complete browser actions with evidence of the final business state, including delayed updates and lost action replies. Use for stateful browser tasks where duplicate submissions or premature completion matter.
---

Before acting, read the current page and use controls from that observation. A post-action capture marked complete means the capture finished; its contents may still describe an intermediate state. Check the business result the user asked for, rather than treating capture completion as task completion.

If an action reply is lost or says action_outcome_unknown, the action may already have happened. Observe the page or read its authoritative receipt before deciding whether another action is needed. Repeating a submission to get a cleaner reply can create duplicates.

Use a condition wait for a delayed final state. An immediate assertion with pass=false says only that the condition is not satisfied now. Preserve timedOut and execution errors separately. Prefer a targeted final condition over repeatedly requesting an entire page tree. Once the final receipt proves the requested operation happened exactly once, stop.
