# Permission Or Secret Incident

## Contain

1. Stop the affected agent or runtime path without disrupting unrelated healthy
   sessions.
2. Revoke exposed credentials and affected Symphony++ grants.
3. Preserve non-secret timestamps, identifiers, and logs needed to reconstruct
   the event.
4. Do not copy the exposed value into an issue, WorkRequest, pull request,
   review, or chat.

## Assess

Determine:

- Which credential or capability was exposed.
- Which WorkRequest, WorkPackage, session, process, and repository were in
  scope.
- Whether the value reached durable ledger prose, logs, dashboard payloads,
  Git history, plugin assets, or external services.
- Whether the underlying server authorization was widened or only a workflow
  aid was wrong.

## Repair

1. Rotate exposed external credentials.
2. Revoke and replace affected grants or claims.
3. Remove durable copies without publishing the value again.
4. Fix the server-side authorization or redaction boundary.
5. Add the smallest behavior test that would have prevented the incident.
6. Validate with synthetic credentials and scoped fixtures.

Document what class of secret or permission failed and where, never its raw
value.
