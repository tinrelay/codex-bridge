# codex-bridge source guidance

codex-bridge owns the volatile stock-Codex mechanics required to send a message to an exact local
Codex Desktop task without changing the visible task. Keep callers independent of those mechanics.

- Use Codex's native `codex_app/send_message_to_thread` tool through the app-tools pipe.
- Stock Codex and runtimes bundled with it are dependencies. TMTK is not.
- Do not launch a second App Server, use renderer history, or navigate the GUI to wake a task.
- Default the source task to the destination task. Accept an explicit source only for intentional
  attribution to a real task; never manufacture or imply Mike's authority.
- Probe cached and candidate sockets only with the framed `tools/list` JSON-RPC request. Select the
  endpoint that advertises the exact native messaging tool.
- Keep the last working endpoint in the bridge-owned `state.db`; validate it before reuse.
- Keep stock-Codex runtime and endpoint discovery reusable through both the shard and CLI so
  consumers do not duplicate installation, bundled-runtime, socket scanning, or cache logic.
- Expose message delivery, not arbitrary native app-tool calls.
- Callers own address books, routing, trust labeling, retries, queues, and message persistence.
- Never log or report message bodies.
- Prefer causal protocol tests over source-shape assertions.

Keep handwritten Crystal at 100 columns or fewer. Run:

```sh
crystal tool format --check src spec
crystal spec --warnings=all --error-on-warnings
shards build codex-bridge --release --warnings=all --error-on-warnings
```
