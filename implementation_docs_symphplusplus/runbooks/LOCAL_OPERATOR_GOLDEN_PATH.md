# Local Operator Golden Path

## Start

1. Run the local daemon from `elixir/` with `mix sympp.cockpit`.
2. Open an MCP-enabled Symphony++ session.
3. Claim the correct ledger object:
   - Worker: `claim_local_assignment({"work_package_id":"<WP id>"})`
   - Architect: `claim_local_architect_assignment({"work_request_id":"<WR id>"})`

## Worker Flow

1. `get_current_assignment`
2. `read_context`
3. `read_task_plan`
4. Record plan/progress/findings/blockers/review evidence through MCP.
5. Attach branch/PR metadata and mark ready only when gates pass.

## Architect Flow

1. `read_work_request`
2. `read_plan`
3. `read_delivery_board`
4. Add/approve/dispatch WorkPackages.
5. Record delivery closeout from PR or no-PR evidence.

## Safety

Do not paste raw secrets, tokens, grant verifiers, or claim lease internals into
prompts, docs, comments, PRs, or logs.
