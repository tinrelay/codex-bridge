require "./spec_helper"
require "../src/codex_bridge/cli"

describe CodexBridge::CLI do
  it "sends stdin with self-attribution by default" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      output = IO::Memory.new
      error = IO::Memory.new
      status = CodexBridge::CLI.run(
        [CodexBridgeSpec::TASK],
        IO::Memory.new("Hello"),
        output,
        error,
        CodexBridge::Client.new(root)
      )

      status.should eq(0)
      output.to_s.should eq("sent #{CodexBridgeSpec::TASK}\n")
      error.to_s.should be_empty
      CodexBridgeSpec.transport_requests(log).last["sourceTaskId"].as_s
        .should eq(CodexBridgeSpec::TASK)
    end
  end

  it "passes an explicit source task" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      status = CodexBridge::CLI.run(
        ["--from-task", CodexBridgeSpec::SOURCE, CodexBridgeSpec::TASK],
        IO::Memory.new("Hello"),
        IO::Memory.new,
        IO::Memory.new,
        CodexBridge::Client.new(root)
      )

      status.should eq(0)
      CodexBridgeSpec.transport_requests(log).last["sourceTaskId"].as_s
        .should eq(CodexBridgeSpec::SOURCE)
    end
  end

  it "prints help without contacting Codex" do
    output = IO::Memory.new
    error = IO::Memory.new
    status = CodexBridge::CLI.run(["--help"], IO::Memory.new, output, error)

    status.should eq(0)
    output.to_s.should contain("Usage: codex-bridge")
    error.to_s.should be_empty
  end

  it "installs the macOS relay or reports the platform no-op" do
    {% if flag?(:darwin) %}
      CodexBridgeSpec.with_fake_installer do |codex_home, state_home, codex, node, _log|
        output = IO::Memory.new
        status = CodexBridge::CLI.run(
          [
            "--install",
            "--codex-home", codex_home,
            "--state-home", state_home,
            "--codex-path", codex,
            "--node-path", node,
          ],
          IO::Memory.new,
          output,
          IO::Memory.new
        )

        status.should eq(0)
        output.to_s.should eq("codex_restart_required\n")
      end
    {% else %}
      output = IO::Memory.new
      status = CodexBridge::CLI.run(["--install"], IO::Memory.new, output, IO::Memory.new)

      status.should eq(0)
      output.to_s.should eq("ready\n")
    {% end %}
  end

  it "prints all resolved discovery values as JSON" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      socket_file = ENV["CODEX_APP_TOOLS_PIPE_PATH"]
      output = IO::Memory.new
      status = CodexBridge::CLI.run(
        ["--discover", "--codex-home", root],
        IO::Memory.new,
        output,
        IO::Memory.new
      )

      status.should eq(0)
      values = JSON.parse(output.to_s)
      values["socket_file"].as_s.should eq(socket_file)
      values["node_path"].as_s.should eq(File.join(root, "node"))
    end
  end

  it "prints one resolved discovery variable" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      socket_file = ENV["CODEX_APP_TOOLS_PIPE_PATH"]
      output = IO::Memory.new
      status = CodexBridge::CLI.run(
        ["--variable", "socket_file", "--codex-home", root],
        IO::Memory.new,
        output,
        IO::Memory.new
      )

      status.should eq(0)
      output.to_s.should eq("#{socket_file}\n")
    end
  end

  it "distinguishes definite rejection from an unknown receipt" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      CodexBridgeSpec.fake_result("rejected")
      rejected_error = IO::Memory.new
      rejected = CodexBridge::CLI.run(
        [CodexBridgeSpec::TASK],
        IO::Memory.new("Hello"),
        IO::Memory.new,
        rejected_error,
        CodexBridge::Client.new(root)
      )

      CodexBridgeSpec.fake_result("unknown")
      unknown_error = IO::Memory.new
      unknown = CodexBridge::CLI.run(
        [CodexBridgeSpec::TASK],
        IO::Memory.new("Hello"),
        IO::Memory.new,
        unknown_error,
        CodexBridge::Client.new(root)
      )

      rejected.should eq(3)
      rejected_error.to_s.should contain("not received")
      unknown.should eq(4)
      unknown_error.to_s.should contain("receipt unknown")
    end
  end
end
