require "spec"
require "file_utils"

require "../src/codex_bridge"

module CodexBridgeSpec
  TASK   = "11111111-2222-3333-4444-555555555555"
  SOURCE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  def self.with_fake_app_tools(&)
    root = File.join(Dir.tempdir, "cb-#{Process.pid}-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(root)
    node = File.join(root, "node")
    log = File.join(root, "transport.jsonl")
    pipe = "/fake/app-tools.sock"
    server = nil.as(IO?)
    {% if flag?(:linux) %}
      pipe = File.join(root, "app-tools.sock")
      server = UNIXServer.new(pipe)
      spawn { serve_fake_app_tools(server, pipe, log) }
    {% end %}
    File.write(node, <<-'RUBY')
      #!/usr/bin/env ruby
      require "json"
      input = JSON.parse(STDIN.read)
      File.open(ENV.fetch("CODEX_BRIDGE_SPEC_LOG"), "a") { |file| file.puts(input.to_json) }
      if input.fetch("operation") == "discover"
        puts({path: input.fetch("candidates").first}.to_json)
      else
        case ENV["CODEX_BRIDGE_SPEC_RESULT"]
        when "rejected"
          puts({error: "rejected", message: "native rejection"}.to_json)
        when "unknown"
          puts({error: "receipt_unknown", message: "connection closed"}.to_json)
        when "malformed"
          puts "not json"
        else
          puts({path: input.fetch("candidates").first, sent: true}.to_json)
        end
      end
      RUBY
    {% if flag?(:linux) %}
      File.write(node, "#!/bin/sh\nexit 97\n")
    {% end %}
    File.chmod(node, 0o700)
    previous_node = ENV["CODEX_MCP_NODE_PATH"]?
    previous_pipe = ENV["CODEX_APP_TOOLS_PIPE_PATH"]?
    previous_log = ENV["CODEX_BRIDGE_SPEC_LOG"]?
    previous_result = ENV["CODEX_BRIDGE_SPEC_RESULT"]?
    ENV["CODEX_MCP_NODE_PATH"] = node
    ENV["CODEX_APP_TOOLS_PIPE_PATH"] = pipe
    ENV["CODEX_BRIDGE_SPEC_LOG"] = log
    ENV.delete("CODEX_BRIDGE_SPEC_RESULT")
    yield root, log
  ensure
    server.try(&.close)
    restore_env("CODEX_MCP_NODE_PATH", previous_node)
    restore_env("CODEX_APP_TOOLS_PIPE_PATH", previous_pipe)
    restore_env("CODEX_BRIDGE_SPEC_LOG", previous_log)
    restore_env("CODEX_BRIDGE_SPEC_RESULT", previous_result)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  def self.restore_env(key, value)
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end

  def self.transport_requests(log)
    File.read_lines(log).map { |line| JSON.parse(line) }
  end

  {% if flag?(:linux) %}
    private def self.serve_fake_app_tools(server, pipe, log)
      loop do
        client = server.accept
        handle_fake_app_tools(client, pipe, log)
      end
    rescue IO::Error
    end

    private def self.handle_fake_app_tools(client, pipe, log)
      header = Bytes.new(4)
      client.read_fully(header)
      size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
      payload = Bytes.new(size.to_i)
      client.read_fully(payload)
      request = JSON.parse(String.new(payload))

      if request["method"].as_s == "tools/list"
        File.open(log, "a") do |file|
          file.puts({operation: "discover", candidates: [pipe]}.to_json)
        end
        write_fake_frame(client, {
          id:      1,
          jsonrpc: "2.0",
          result:  {
            tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
          },
        }.to_json)
        return
      end

      params = request["params"]
      arguments = params["arguments"]
      target = arguments["threadId"].as_s
      File.open(log, "a") do |file|
        file.puts({
          operation:    "send",
          candidates:   [pipe],
          sourceTaskId: params["threadId"].as_s,
          targetTaskId: target,
          prompt:       arguments["prompt"].as_s,
        }.to_json)
      end

      case ENV["CODEX_BRIDGE_SPEC_RESULT"]?
      when "rejected"
        write_fake_frame(client, {
          id:      1,
          jsonrpc: "2.0",
          error:   {message: "native rejection"},
        }.to_json)
      when "unknown"
      when "malformed"
        write_fake_frame(client, "not json")
      else
        write_fake_frame(client, {
          id:      1,
          jsonrpc: "2.0",
          result:  {
            success:      true,
            contentItems: [{type: "inputText", text: {threadId: target}.to_json}],
          },
        }.to_json)
      end
    ensure
      client.close
    end

    private def self.write_fake_frame(client, payload : String)
      bytes = payload.to_slice
      header = Bytes.new(4)
      IO::ByteFormat::LittleEndian.encode(bytes.size.to_u32, header)
      client.write(header)
      client.write(bytes)
      client.flush
    end
  {% end %}
end
