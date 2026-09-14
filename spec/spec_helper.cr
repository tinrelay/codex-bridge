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
    log = File.join(root, "helper.jsonl")
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
    previous_node = ENV["CODEX_MCP_NODE_PATH"]?
    previous_pipe = ENV["CODEX_APP_TOOLS_PIPE_PATH"]?
    previous_log = ENV["CODEX_BRIDGE_SPEC_LOG"]?
    previous_result = ENV["CODEX_BRIDGE_SPEC_RESULT"]?
    ENV["CODEX_MCP_NODE_PATH"] = node
    ENV["CODEX_APP_TOOLS_PIPE_PATH"] = "/fake/app-tools.sock"
    ENV["CODEX_BRIDGE_SPEC_LOG"] = log
    ENV.delete("CODEX_BRIDGE_SPEC_RESULT")
    yield root, log
  ensure
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

  def self.helper_requests(log)
    File.read_lines(log).map { |line| JSON.parse(line) }
  end
end
