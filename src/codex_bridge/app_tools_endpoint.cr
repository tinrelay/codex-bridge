module CodexBridge
  private class AppToolsEndpoint
    CACHE_KEY = "app_tools_pipe"

    getter connection : Connection

    def self.discover(
      state_home : String,
      candidates : Enumerable(String)? = nil,
      *,
      socket_file : String? = nil,
      node_path : String? = nil,
      codex_resources : String? = nil,
      cache = true,
    ) : self?
      node, resources = bundled_node(node_path, codex_resources)
      return unless node

      state = StateStore.new(state_home)
      paths = [] of String
      if socket_file
        paths << socket_file
      elsif cache && (cached = state.get(CACHE_KEY))
        paths << cached
      end
      unless socket_file
        if configured = ENV["CODEX_APP_TOOLS_PIPE_PATH"]?
          paths << configured
        end
        if candidates
          paths.concat(candidates)
        else
          paths.concat(default_candidates)
        end
      end

      result = AppToolsHelper.run(node, {operation: "discover", candidates: paths.uniq})
      return if result["error"]?
      path = result["path"].as_s
      state.put(CACHE_KEY, path) if cache
      new(Connection.new(path, node, resources))
    rescue AppToolsHelperUnavailable | AppToolsHelperError
      nil
    rescue JSON::ParseException | KeyError | TypeCastError
      nil
    end

    def initialize(@connection)
    end

    def send_message(source_task_id : String, target_task_id : String, prompt : String)
      result = AppToolsHelper.run(
        connection.node_path,
        {
          operation:    "send",
          candidates:   [connection.socket_file],
          sourceTaskId: source_task_id,
          targetTaskId: target_task_id,
          prompt:       prompt,
        }
      )
      if error = result["error"]?.try(&.as_s?)
        message = result["message"]?.try(&.as_s?) || error
        raise AppToolsReceiptUnknown.new(message) if error == "receipt_unknown"
        raise AppToolsRejected.new(message)
      end
      unless result["sent"]?.try(&.as_bool?)
        raise AppToolsReceiptUnknown.new("invalid_app_tools_response")
      end
    rescue AppToolsHelperUnavailable
      raise AppToolsRejected.new("app_tools_unavailable")
    rescue AppToolsHelperError | JSON::ParseException | KeyError | TypeCastError
      raise AppToolsReceiptUnknown.new("invalid_app_tools_response")
    end

    private def self.bundled_node(explicit_node, explicit_resources)
      return {explicit_node, resources_for(explicit_node, explicit_resources)} if explicit_node
      if explicit_resources
        node = File.join(explicit_resources, "cua_node", "bin", node_name)
        return {node, explicit_resources} if File::Info.executable?(node)
        return {nil, explicit_resources}
      end

      paths = [] of Tuple(String, String?)
      if configured = ENV["CODEX_MCP_NODE_PATH"]?
        paths << {configured, resources_for(configured, nil)}
      end
      if configured = ENV["CODEX_BROWSER_USE_NODE_PATH"]?
        paths << {configured, resources_for(configured, nil)}
      end
      if resources = ENV["CODEX_ELECTRON_RESOURCES_PATH"]?
        paths << {File.join(resources, "cua_node", "bin", node_name), resources}
      end
      PlatformDiscovery.resource_candidates.each do |resources|
        paths << {File.join(resources, "cua_node", "bin", node_name), resources}
      end
      paths.find { |path, _| File::Info.executable?(path) } || {nil, nil}
    end

    private def self.resources_for(node_path, configured_resources)
      return configured_resources if configured_resources
      suffix = File.join("cua_node", "bin", node_name)
      return unless node_path.ends_with?(suffix)
      node_path[0, node_path.bytesize - suffix.bytesize].rstrip(File::SEPARATOR)
    end

    private def self.node_name
      {% if flag?(:win32) %}
        "node.exe"
      {% else %}
        "node"
      {% end %}
    end

    private def self.default_candidates
      PlatformDiscovery.socket_candidates
    end
  end

  private module AppToolsHelper
    SCRIPT = <<-'JAVASCRIPT'
      const crypto = require("crypto");
      const net = require("net");

      const MAX_FRAME = 8 * 1024 * 1024;

      function request(path, method, params, timeoutMs, mutating = false) {
        return new Promise((resolve, reject) => {
          const socket = net.createConnection(path);
          let buffer = Buffer.alloc(0);
          let settled = false;
          let submitted = false;
          const failure = message => {
            const error = new Error(message);
            error.receiptUnknown = mutating && submitted;
            return error;
          };
          const finish = (error, value) => {
            if (settled) return;
            settled = true;
            socket.destroy();
            error ? reject(error) : resolve(value);
          };
          socket.setTimeout(timeoutMs, () => finish(failure("timeout")));
          socket.on("error", error => finish(failure(error.message)));
          socket.on("close", () => {
            if (!settled) finish(failure("closed"));
          });
          socket.on("connect", () => {
            const payload = Buffer.from(JSON.stringify({id: 1, jsonrpc: "2.0", method, params}));
            if (payload.length > MAX_FRAME) return finish(new Error("request too large"));
            const header = Buffer.alloc(4);
            header.writeUInt32LE(payload.length);
            submitted = mutating;
            socket.write(Buffer.concat([header, payload]));
          });
          socket.on("data", chunk => {
            buffer = Buffer.concat([buffer, chunk]);
            if (buffer.length < 4) return;
            const size = buffer.readUInt32LE(0);
            if (size > MAX_FRAME) return finish(failure("invalid frame"));
            if (buffer.length < size + 4) return;
            try {
              const response = JSON.parse(buffer.subarray(4, size + 4).toString("utf8"));
              if (response.error) {
                const error = new Error(response.error.message || "JSON-RPC error");
                error.receiptUnknown = false;
                return finish(error);
              }
              finish(null, response.result);
            } catch (error) {
              finish(failure(error.message));
            }
          });
        });
      }

      async function endpoint(candidates) {
        for (const path of candidates) {
          try {
            const result = await request(path, "tools/list", {threadStartKind: "all"}, 250);
            if (result.tools.some(tool =>
              tool.name === "send_message_to_thread" && tool.namespace === "codex_app"
            )) return path;
          } catch (_) {}
        }
        return null;
      }

      async function main() {
        const chunks = [];
        for await (const chunk of process.stdin) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        const path = input.operation === "send"
          ? input.candidates[0]
          : await endpoint(input.candidates);
        if (!path) {
          process.stdout.write(JSON.stringify({error: "unavailable"}));
          return;
        }
        if (input.operation === "discover") {
          process.stdout.write(JSON.stringify({path}));
          return;
        }
        if (input.operation !== "send") throw new Error("unknown operation");
        const callId = `codex-bridge-${crypto.randomUUID()}`;
        const result = await request(path, "tools/call", {
          arguments: {
            threadId: input.targetTaskId,
            hostId: "local",
            prompt: input.prompt
          },
          callId,
          namespace: "codex_app",
          threadId: input.sourceTaskId,
          tool: "send_message_to_thread",
          turnId: callId
        }, 20000, true);
        if (result && result.success === false) throw new Error("message rejected");
        try {
          if (!result || result.success !== true) throw new Error("invalid message result");
          const item = result.contentItems.find(item => item.type === "inputText");
          const returned = item && JSON.parse(item.text).threadId;
          if (returned !== input.targetTaskId) throw new Error("message target mismatch");
        } catch (error) {
          error.receiptUnknown = true;
          throw error;
        }
        process.stdout.write(JSON.stringify({path, sent: true}));
      }

      main().catch(error => {
        process.stdout.write(JSON.stringify({
          error: error && error.receiptUnknown ? "receipt_unknown" : "rejected",
          message: String(error && error.message || error)
        }));
      });
      JAVASCRIPT

    def self.run(node : String, request) : JSON::Any
      output = IO::Memory.new
      errors = IO::Memory.new
      result = Process.run(
        node,
        ["-e", SCRIPT],
        input: IO::Memory.new(request.to_json),
        output: output,
        error: errors
      )
      unless result.success?
        message = errors.to_s.strip
        message = "app tools helper failed" if message.empty?
        raise AppToolsHelperError.new(message)
      end
      JSON.parse(output.to_s)
    rescue File::NotFoundError
      raise AppToolsHelperUnavailable.new("bundled Node is unavailable")
    rescue ex : IO::Error
      raise AppToolsHelperError.new(ex.message || "app tools helper IO failed")
    end
  end

  private class AppToolsHelperError < Exception
  end

  private class AppToolsHelperUnavailable < Exception
  end
end
