---
name: ai-diagnostics-evidence
description: Interpret MCP configuration, connection inspection, tool definitions and local usage records without turning missing evidence into success or failure. Use for evidence-backed AI tool diagnostic summaries.
---

Keep four kinds of evidence separate: configuration validity, an explicitly completed connection inspection, definition quality, and observed calls. Valid configuration alone leaves connection unverified. An incomplete inspection stays incomplete; only a completed inspection verifies the recorded connection, never overall task quality.

Count a call as completed only when its result exists. Only an explicit Boolean isError indicates a known error status. Missing status, strings such as "false", or ERROR words in returned text do not establish error status. Count missing results separately, without inventing an outcome.

Preserve native request input tokens and cached input tokens as separately reported. Do not add cache counters to input, divide a request among tools, or infer missing usage from returned text.

Inspect definitions only when provided. A blank description or missing/non-object inputSchema is a concrete issue; do not judge quality from length. Unavailable definitions mean unknown quality, not an empty issue list. Match the requested output fields and return no unsupported claims.
