# Codex Bridge source guidance

Codex Bridge is a small Crystal library for delivering trusted caller instructions and explicitly
untrusted attachments to an existing local Codex Desktop task. Keep it independent of the products
that use it.

- Every delivery explicitly selects `steer` or `queue`; the library has no policy default.
- `queue` supports structured untrusted attachments. Active `steer` is trusted-input-only until the
  Desktop follower API exposes an equivalent injection seam; it must fail rather than silently queue.
- Positive complete-history evidence may prove acceptance. Absence never proves rejection.
- Keep lifecycle state sparse: runtime, turn identity/status, and user-message client IDs only.
- The library owns Desktop transport, owner discovery, lifecycle validation, submission, and
  stable-ID reconciliation. Callers own queues, persistence, retries, supervisors, and completion.
- Never log or report trusted instructions or untrusted attachment bodies.
- Prefer causal protocol tests over source-shape assertions.

Keep handwritten Crystal at 100 columns or fewer. Run:

```sh
crystal tool format --check src spec
crystal spec --warnings=all --error-on-warnings
```
