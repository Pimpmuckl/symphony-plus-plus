# Review Contract

A planned slice may declare one optional review requirement:

```json
{"type":"review-suite","args":{"mode":"normal"}}
```

`type` is an opaque provider or review kind. `args` is an optional non-secret
object interpreted only by the architect and worker. Symphony++ does not
install providers, run reviews, parse verdicts, or prescribe review cycles.

When no requirement is present, Symphony++ requires no review.

When a requirement is present:

1. Attach the current branch head.
2. Complete the declared review outside Symphony++.
3. Call `complete_review(reference?, note?)`.
4. Call `mark_ready()` after the remaining gates are satisfied.

The completion is bound to the WorkPackage, exact head SHA, and complete review
requirement. A head or requirement change makes earlier completion insufficient.
The optional `reference` is an opaque provider or human review id; `note` is
human-facing context. Generic `append_progress` events cannot satisfy readiness.
