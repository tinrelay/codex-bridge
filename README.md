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

`Client.new(timeout: 60.seconds)` controls the complete delivery budget: endpoint discovery,
native submission, and confirmation when Codex loses the native receipt. The default is 60 seconds.

On macOS, install codex-bridge's narrow relay MCP once and restart Codex when requested:

```crystal
CodexBridge.install # => :ready or :codex_restart_required
```

The call is idempotent. On Linux and Windows it returns `:ready` without changing files or Codex
configuration. The qualified VM configurations use Codex's bundled `codex-app-tools` MCP to make
the stock app-tools endpoint available; codex-bridge then connects to that endpoint directly.

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

A normal return means Codex definitely received the message. If Codex closes the native connection
after submission, codex-bridge uses the remainder of the timeout to look for the exact newer
delivery in Codex's local thread history. It never resubmits during that check. `NotReceived` means
submission definitely failed and a caller may choose to retry or fall back. `ReceiptUnknown` means
neither the native receipt nor local history established the outcome and must not trigger an
automatic retry or fallback. The CLI reports those as exit statuses 3 and 4 respectively.

## CLI

The included CLI reads the complete message from stdin:

```sh
echo 'Please acknowledge this test.' | codex-bridge TASK_ID
```

This uses self-attribution. Use `--from-task TASK_ID` for intentional task-to-task attribution.
Use `--timeout SECONDS` to change the default 60-second overall delivery budget.

```sh
echo 'Please acknowledge this test.' \
  | codex-bridge --from-task SOURCE_TASK_ID DESTINATION_TASK_ID
```

On macOS, the equivalent installation command is:

```sh
codex-bridge --install
```

`ready` means the current Codex process can already use the relay. `codex_restart_required` means
installation succeeded and Codex must be restarted before messages can use it.

After the macOS install-and-restart step, and on the qualified Linux and Windows configurations
with the bundled `codex-app-tools` MCP enabled, ordinary sends need no discovery overrides. For
diagnostics, embedding, or scripts that need the same stock-Codex facts, the CLI can also act as a
small discovery tool:

```sh
codex-bridge --discover
codex-bridge --variable socket_file
codex-bridge --variable node_path
codex-bridge --variable codex_resources
```

`--discover` emits one JSON object. Use `--socket-file`, `--node-path`, or `--codex-resources` to
override one discovered value. `--uncached` skips both reading and writing the SQLite socket cache.
`node_path` is optional connection metadata; native message delivery does not require it.

The Linux default derives the bundled runtime from `/usr/lib/chatgpt/resources` and scans the
per-user app-tools sockets under the system temporary directory. Explicit arguments and the Codex
environment variables remain available for nonstandard installations.

The Windows default resolves the current `OpenAI.Codex` AppX package, derives its bundled runtime,
and scans the current user's `codex-browser-use-*` named pipes. Package versions and pipe names are
discovered at runtime rather than embedded in the bridge.

## Stock Codex boundary

Native Crystal IO is the normal transport. On Linux and Windows, codex-bridge speaks the
length-prefixed JSON-RPC protocol directly over the per-user Unix socket or named pipe. On macOS,
`install` copies an embedded relay to `~/.codex/codex-bridge/relay.mjs` and registers it with stock
Codex as an ordinary MCP server. Each loaded task launches one relay through Codex's own process
tree and creates a user-only `relay-PID.sock` beside codex-bridge's `state.db`.
codex-bridge then uses the same native Crystal protocol against that socket. The relay accepts only
the read-only discovery call and `codex_app/send_message_to_thread`; it does not expose arbitrary
app tools. The macOS client searches only its configured state directory for relay sockets; unlike
Linux and Windows, it does not scan stock app-tools endpoints. The relay itself performs one
bounded stock-socket probe when its MCP process starts, then retains that endpoint in memory.
At the same startup seam it removes only bridge-owned relay sockets that the kernel definitively
reports as having no listener; ambiguous failures are preserved.

The installer registers the relay with a single SHA-256 identity derived from its embedded source.
It reports `ready` only when a responding relay carries that identity; a still-running older relay
therefore continues to require a Codex restart after an update.

The last working socket path is stored in a small `kv` table in
`~/.codex/codex-bridge/state.db`. Current macOS relay sockets in that directory are tried before a
cached endpoint. Each call validates the cached endpoint and scans again when it is stale. Library
consumers can call `CodexBridge.discover` to get a `Connection` containing
`socket_file`, `node_path`, and `codex_resources`. Pass another `state_home` to `Client` or use CLI
`--state-home PATH` when embedding the bridge elsewhere. `Client` accepts an explicit `socket_file`;
runtime metadata is diagnostic and never gates delivery. `CODEX_APP_TOOLS_PIPE_PATH` and Codex's
bundled-runtime environment variables are used when present.

The same bridge-owned SQLite database briefly serializes submissions so concurrent clients cannot
claim the same fallback confirmation. Codex's `thread_history_1.sqlite` is read only after an
uncertain native result, and only for a newer exact source-and-body delivery record. Message bodies
are not copied into bridge state or logs.

This boundary is private and version-sensitive. codex-bridge exposes message delivery and the
connection facts needed to reuse its discovery; it does not provide a generic interface to Codex's
other app tools.

Run the checks with:

```sh
crystal tool format --check src spec
crystal spec --warnings=all --error-on-warnings
shards build codex-bridge --release --warnings=all --error-on-warnings
```
