# SYMPP-V2-DOGFOOD-002 Child A Naming Evidence

Date: 2026-05-18

## Scope

Child A records the toy naming convention used by the DOGFOOD-002 multi-PR
rehearsal. The change is intentionally docs/evidence-only so the rehearsal can
exercise branch, review, and merge mechanics without product or runtime risk.

## WorkRequest Mapping

| Item | Value |
| --- | --- |
| WorkRequest | `SYMPP-V2-DOGFOOD-002-WR` |
| WorkPackage | `SYMPP-V2-DOGFOOD-002-SLICE-A` |
| Dispatched WorkPackage | `wp_ZtFeuFtbjHyAXvNY2jllEA` |
| Branch | `feat/sympp-v2-dogfood-002-child-a` |
| Owned file | `implementation_docs_symphplusplus/dogfood/SYMPP-V2-DOGFOOD-002-child-a-naming.md` |

## Naming Convention

- Use `SYMPP-V2-DOGFOOD-002-WR` for the rehearsal WorkRequest.
- Use `SYMPP-V2-DOGFOOD-002-SLICE-A` and `SYMPP-V2-DOGFOOD-002-SLICE-B` for the two child slices.
- Use branch names `feat/sympp-v2-dogfood-002-child-a` and `feat/sympp-v2-dogfood-002-child-b`.
- Keep child outputs under `implementation_docs_symphplusplus/dogfood/`.

## Guardrails

- Do not touch runtime, plugin, or workflow defaults from child slices.
- Do not record raw work keys, access grants, MCP session ids, tokens, or private handoff payloads.
- Treat this file as naming evidence only; the final DOGFOOD-002 evidence note owns the readiness recommendation.
