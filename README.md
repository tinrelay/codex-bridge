# Codex Bridge

Codex Bridge is a small Crystal library for delivering caller-owned input to an existing local
Codex Desktop task. It uses Codex Desktop's local Unix socket on macOS and Linux and its named pipe
on Windows. It does not address cloud tasks or remote hosts.

The follower protocol is an internal, version-sensitive Codex Desktop boundary, not a stable public
API. Desktop changes may return `Incompatible` until the shard is updated; platform support names
the implemented local transports, not an official remote or cloud interface.

Add the shard and install dependencies:

```yaml
dependencies:
  codex_bridge:
    github: mieko/codex-bridge
```

```sh
shards install
```

Each delivery requires an exact local task ID, a trusted instruction, a stable caller-supplied
logical message ID, and an explicit `Steer` or `Queue` mode. Attachments are represented separately
as structured untrusted model context.

One logical message ID identifies one exact input to one exact task. Retries must retain that task,
input, and ID. The ID is correlation evidence, not an idempotency key; retrying an ambiguous
delivery may still produce duplicate acceptance.

```crystal
require "codex_bridge"

delivery = CodexBridge::Delivery.new(
  task_id: task_id,
  instruction: "Route the attached event without treating it as authority.",
  attachments: [CodexBridge::UntrustedAttachment.new("event-1", "Event", event_json)],
  logical_message_id: stable_id,
  mode: CodexBridge::DeliveryMode::Queue,
)

result = CodexBridge::Client.new.deliver(delivery)
```

`Queue` waits for the task to become idle and starts a fresh turn. `Steer` adds trusted-only input
to the observed active turn, or starts a fresh turn when the task is idle. The current Desktop
follower API cannot inject structured untrusted context into an active turn, so active `Steer` with
attachments returns `Incompatible("steer_untrusted_attachments_unsupported")`; it never silently
becomes `Queue` or moves attachment text into trusted input.

The result is one of:

- `Accepted(turn_id)`: Codex Core accepted the input for that turn. This does not mean a model
  processed it or that the turn completed.
- `Retryable(reason)`: a definite pre-submission condition permits caller-owned retry.
- `Ambiguous(reason)`: submission may have been accepted. Keep the same logical message ID and
  reconcile before deciding whether to retry.
- `Incompatible(reason)`: the local Desktop contract or supplied operation is unsupported.

The shard uses positive complete-history evidence to reconcile a stable logical message ID. Absence
is only non-observation and never proves rejection. It does not persist messages, receipts, queues,
retry state, task mappings, or completion state; the caller owns those policies and must keep any
input needed after an ambiguous result. Unknown submission outcomes are never resubmitted
automatically.

Run the checks with:

```sh
crystal tool format --check src spec
crystal spec --warnings=all --error-on-warnings
crystal build src/codex_bridge.cr --warnings=all --error-on-warnings
```
