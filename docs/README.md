# Symphony++ Documentation

This directory documents the running Symphony++ product. It is not a roadmap,
design archive, or copy of the agent skills.

## Sources Of Truth

| Subject | Authority |
|---|---|
| Runtime behavior and state transitions | Elixir code and behavior tests |
| Agent operating procedure | Packaged `plugins/**/skills/**/SKILL.md` files |
| Human concepts and operations | This directory |
| Product direction | `PRODUCT.md` |
| Interface design | `DESIGN.md` |
| Upstream Symphony behavior | `SPEC.md` and `elixir/` |
| MCP artifact identity | MCP server identity and runtime artifact tests |

Use Git history for completed designs, cutovers, and experiments. Historical
documents do not remain in the active documentation tree.

## Read By Goal

- Understand the model: [Concepts](concepts.md)
- Operate Symphony++: [Operations](operations.md)
- Understand the system: [Architecture](architecture.md)
- Review trust boundaries: [Security](security.md)
- Develop and validate changes: [Development](development.md)
- Diagnose installed runtime behavior: [Runtime](runtime.md)
- Repair delivery state: [Delivery recovery](runbooks/delivery-recovery.md)
- Respond to a permission or secret incident:
  [Security incident](runbooks/security-incident.md)

## Documentation Rules

- Describe only current behavior.
- Link to packaged skills instead of copying agent procedures.
- Link to code-owned schemas instead of maintaining a second tool inventory.
- Put machine-consumed files with the runtime or plugin that owns them.
- Delete completed plans and cutover notes; Git already preserves them.
