require "spec"
require "file_utils"

require "../src/codex_bridge"

{% if flag?(:win32) %}
  require "./support/windows_app_tools_server"
{% end %}

module CodexBridgeSpec
  TASK   = "11111111-2222-3333-4444-555555555555"
  SOURCE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  {% if flag?(:win32) %}
    @@windows_server : WindowsAppToolsServer?
  {% end %}

  def self.with_fake_app_tools(&)
    root = File.join(Dir.tempdir, "cb-#{Process.pid}-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(root)
    node = File.join(root, "node")
    log = File.join(root, "transport.jsonl")
    pipe = "/fake/app-tools.sock"
    server = nil.as(IO?)
    {% if flag?(:win32) %}
      windows_server = nil.as(WindowsAppToolsServer?)
    {% end %}
    result_file = File.join(root, "result")
    File.write(result_file, "success")
    {% if flag?(:linux) || flag?(:darwin) %}
      pipe = File.join(root, "app-tools.sock")
      server = UNIXServer.new(pipe)
      spawn { serve_fake_app_tools(server, pipe, log) }
      File.write(node, "#!/bin/sh\nexit 97\n")
      File.chmod(node, 0o700)
    {% elsif flag?(:win32) %}
      name = "codex-browser-use-spec-#{Process.pid}-#{Random::Secure.hex(4)}"
      pipe = "\\\\.\\pipe\\#{name}"
      File.write(node, "metadata only")
      windows_server = WindowsAppToolsServer.new(name)
      @@windows_server = windows_server
    {% else %}
      {% raise "codex-bridge specs do not support this platform" %}
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
    {% if flag?(:win32) %}
      windows_server.try(&.close)
      @@windows_server = nil
    {% end %}
    restore_env("CODEX_MCP_NODE_PATH", previous_node)
    restore_env("CODEX_APP_TOOLS_PIPE_PATH", previous_pipe)
    restore_env("CODEX_BRIDGE_SPEC_LOG", previous_log)
    restore_env("CODEX_BRIDGE_SPEC_RESULT", previous_result)
    restore_env("CODEX_BRIDGE_SPEC_RESULT_FILE", previous_result_file)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  def self.fake_result(value)
    {% if flag?(:win32) %}
      @@windows_server.not_nil!.result = value
    {% else %}
      ENV["CODEX_BRIDGE_SPEC_RESULT"] = value
      if path = ENV["CODEX_BRIDGE_SPEC_RESULT_FILE"]?
        File.write(path, value)
      end
    {% end %}
  end

  def self.restore_env(key, value)
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end

  def self.transport_requests(log)
    {% if flag?(:win32) %}
      @@windows_server.not_nil!.requests
    {% else %}
      return [] of JSON::Any unless File.exists?(log)
      File.read_lines(log).map { |line| JSON.parse(line) }
    {% end %}
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
