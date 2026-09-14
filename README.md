# codex-bridge

codex-bridge sends a message to an exact local Codex Desktop task without changing the visible
task. It uses the native task-messaging tool included with stock Codex. It does not depend on TMTK,
launch another App Server, or load task history through a renderer.

Add the shard:

```yaml
dependencies:
  codex_bridge:
    github: tinrelay/codex-bridge
```

```crystal
require "codex_bridge"

bridge = CodexBridge::Client.new
bridge.send_message(task_id, "Please look at this.")
```

By default, the destination task is also the source task. Codex therefore renders an ordinary
self-attributed task message rather than implying that Mike or another agent sent it. Supply a real
source task only when that task is intentionally speaking:

```crystal
bridge.send_message(destination_task_id, "Please look at this.", from: source_task_id)
```

The source and destination must be exact local task UUIDs. A source task must really exist; Codex
rejects synthetic IDs. Callers own names, address books, trust labeling, retry policy, and message
persistence. Because default self-attribution looks like a task addressing itself, external callers
should put a clear origin cue in the message body when the recipient would not otherwise understand
where it came from. codex-bridge does not invent that label.

A normal return means Codex definitely received the message. `NotReceived` means submission
definitely failed and a caller may choose to retry or fall back. `ReceiptUnknown` means submission
may have succeeded and must not trigger an automatic retry or fallback. The CLI reports those as
exit statuses 3 and 4 respectively.

## CLI

The included CLI reads the complete message from stdin:

```sh
printf 'Please acknowledge this test.\n' | codex-bridge TASK_ID
```

This uses self-attribution. Use `--from-task TASK_ID` for intentional task-to-task attribution.

```sh
printf 'Please acknowledge this test.\n' \
  | codex-bridge --from-task SOURCE_TASK_ID DESTINATION_TASK_ID
```

On qualified stock macOS installations, ordinary sends need no discovery configuration. Linux and
Windows currently require Codex-provided environment paths or explicit overrides until their
platform defaults are qualified. For diagnostics, embedding, or scripts that need the same
stock-Codex facts, the CLI can also act as a small discovery tool:

```sh
codex-bridge --discover
codex-bridge --variable socket_file
codex-bridge --variable node_path
codex-bridge --variable codex_resources
```

`--discover` emits one JSON object. Use `--socket-file`, `--node-path`, or `--codex-resources` to
override one discovered value. `--uncached` skips both reading and writing the SQLite socket cache.

## Stock Codex boundary

Codex accepts app-tools pipe clients launched with its bundled Node runtime. codex-bridge uses that
runtime to probe the per-user app-tools sockets with the read-only `tools/list` JSON-RPC method and
selects the endpoint advertising `codex_app/send_message_to_thread`.

The last working socket path is stored in a small `kv` table in
`~/.codex/codex-bridge/state.db`. Each call validates the cached endpoint first and scans again when
it is stale. Library consumers can call `CodexBridge.discover` to get a `Connection` containing
`socket_file`, `node_path`, and `codex_resources`, or pass those values to `Client.new` as explicit
keywords. Pass another `state_home` to `Client` or use CLI `--state-home PATH` when embedding the
bridge elsewhere. `CODEX_APP_TOOLS_PIPE_PATH` and Codex's bundled-runtime environment variables are
used when present.

This boundary is private and version-sensitive. codex-bridge exposes message delivery and the
connection facts needed to reuse its discovery; it does not provide a generic interface to Codex's
other app tools.

Run the checks with:

```sh
crystal tool format --check src spec
crystal spec --warnings=all --error-on-warnings
shards build codex-bridge --release --warnings=all --error-on-warnings
```
