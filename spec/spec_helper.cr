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
    windows_server = nil.as(Process?)
    result_file = File.join(root, "result")
    File.write(result_file, "success")
    {% if flag?(:linux) || flag?(:darwin) %}
      pipe = File.join(root, "app-tools.sock")
      server = UNIXServer.new(pipe)
      spawn { serve_fake_app_tools(server, pipe, log) }
      File.write(node, "#!/bin/sh\nexit 97\n")
      File.chmod(node, 0o700)
    {% elsif flag?(:win32) %}
      name = "codex-bridge-spec-#{Process.pid}-#{Random::Secure.hex(4)}"
      pipe = "\\\\.\\pipe\\#{name}"
      script = File.expand_path("support/windows_app_tools_server.ps1", __DIR__)
      ready = File.join(root, "ready")
      File.write(node, "metadata only")
      windows_server = Process.new(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script,
          name,
          log,
          result_file,
          ready,
        ],
        output: Process::Redirect::Close,
        error: Process::Redirect::Inherit
      )
      200.times do
        break if File.exists?(ready)
        sleep 10.milliseconds
      end
      raise "fake app-tools pipe did not start" unless File.exists?(ready)
    {% else %}
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
      File.chmod(node, 0o700)
    {% end %}
    previous_node = ENV["CODEX_MCP_NODE_PATH"]?
    previous_pipe = ENV["CODEX_APP_TOOLS_PIPE_PATH"]?
    previous_log = ENV["CODEX_BRIDGE_SPEC_LOG"]?
    previous_result = ENV["CODEX_BRIDGE_SPEC_RESULT"]?
    previous_result_file = ENV["CODEX_BRIDGE_SPEC_RESULT_FILE"]?
    ENV["CODEX_MCP_NODE_PATH"] = node
    ENV["CODEX_APP_TOOLS_PIPE_PATH"] = pipe
    ENV["CODEX_BRIDGE_SPEC_LOG"] = log
    ENV["CODEX_BRIDGE_SPEC_RESULT_FILE"] = result_file
    ENV.delete("CODEX_BRIDGE_SPEC_RESULT")
    yield root, log
  ensure
    server.try(&.close)
    windows_server.try(&.terminate)
    windows_server.try(&.wait)
    restore_env("CODEX_MCP_NODE_PATH", previous_node)
    restore_env("CODEX_APP_TOOLS_PIPE_PATH", previous_pipe)
    restore_env("CODEX_BRIDGE_SPEC_LOG", previous_log)
    restore_env("CODEX_BRIDGE_SPEC_RESULT", previous_result)
    restore_env("CODEX_BRIDGE_SPEC_RESULT_FILE", previous_result_file)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  def self.fake_result(value)
    ENV["CODEX_BRIDGE_SPEC_RESULT"] = value
    if path = ENV["CODEX_BRIDGE_SPEC_RESULT_FILE"]?
      File.write(path, value)
    end
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

  {% if flag?(:darwin) %}
    def self.with_fake_installer(&)
      root = "/tmp/cbi-#{Process.pid}-#{Random::Secure.hex(4)}"
      codex_home = File.join(root, "codex-home")
      state_home = File.join(codex_home, "codex-bridge")
      resources = File.join(root, "resources")
      node = File.join(resources, "cua_node", "bin", "node")
      codex = File.join(resources, "codex")
      log = File.join(root, "install.log")
      FileUtils.mkdir_p(File.dirname(node))
      File.write(node, "#!/bin/sh\nexit 0\n")
      File.write(codex, <<-'SH')
        #!/bin/sh
        echo "$CODEX_HOME|$@" >> "$CODEX_BRIDGE_INSTALL_LOG"
        SH
      File.chmod(node, 0o700)
      File.chmod(codex, 0o700)
      previous = ENV["CODEX_BRIDGE_INSTALL_LOG"]?
      ENV["CODEX_BRIDGE_INSTALL_LOG"] = log
      yield codex_home, state_home, codex, node, log
    ensure
      restore_env("CODEX_BRIDGE_INSTALL_LOG", previous)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end

    def self.answer_tool_list(client, generation)
      header = Bytes.new(4)
      client.read_fully(header)
      size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
      request = Bytes.new(size.to_i)
      client.read_fully(request)
      response = {
        id:      1,
        jsonrpc: "2.0",
        result:  {
          codexBridgeRelayGeneration: generation,
          tools:                      [{name: "send_message_to_thread", namespace: "codex_app"}],
        },
      }.to_json.to_slice
      IO::ByteFormat::LittleEndian.encode(response.size.to_u32, header)
      client.write(header)
      client.write(response)
      client.close
    end
  {% end %}

  {% if flag?(:linux) || flag?(:darwin) %}
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
