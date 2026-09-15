require "./spec_helper"

describe ".install" do
  {% if flag?(:darwin) %}
    it "materializes and registers the macOS relay MCP" do
      CodexBridgeSpec.with_fake_installer do |codex_home, state_home, codex, node, log|
        result = CodexBridge.install(
          codex_home,
          state_home: state_home,
          codex_path: codex,
          node_path: node
        )

        result.should eq(:codex_restart_required)
        relay = File.join(state_home, "relay.mjs")
        File.read(relay).should contain("send_message_to_thread")
        File.info(relay).permissions.value.should eq(0o600)
        File.info(state_home).permissions.value.should eq(0o700)
        File.read(log).should contain(
          "#{codex_home}|mcp add codex_bridge_relay " \
          "--env CODEX_BRIDGE_STATE_HOME=#{state_home} " \
          "-- #{node} #{relay} "
        )
      end
    end

    it "reports ready after registration when the current relay generation responds" do
      CodexBridgeSpec.with_fake_installer do |codex_home, state_home, codex, node, log|
        CodexBridge.install(
          codex_home,
          state_home: state_home,
          codex_path: codex,
          node_path: node
        )
        generation = File.read(log).split.last
        File.write(log, "")
        socket_path = File.join(state_home, "codex-bridge-relay-123.sock")
        server = UNIXServer.new(socket_path)
        handled = Channel(Nil).new
        spawn do
          client = server.accept
          CodexBridgeSpec.answer_tool_list(client, generation)
          handled.send(nil)
        end

        CodexBridge.install(
          codex_home,
          state_home: state_home,
          codex_path: codex,
          node_path: node
        ).should eq(:ready)
        handled.receive
        File.read(log).should contain("#{codex_home}|mcp add codex_bridge_relay")
      ensure
        server.try(&.close)
      end
    end

    it "requires a restart while only an old relay generation responds" do
      CodexBridgeSpec.with_fake_installer do |codex_home, state_home, codex, node, log|
        CodexBridge.install(
          codex_home,
          state_home: state_home,
          codex_path: codex,
          node_path: node
        )
        File.write(log, "")
        socket_path = File.join(state_home, "codex-bridge-relay-123.sock")
        server = UNIXServer.new(socket_path)
        handled = Channel(Nil).new
        spawn do
          client = server.accept
          CodexBridgeSpec.answer_tool_list(client, "old-generation")
          handled.send(nil)
        end

        CodexBridge.install(
          codex_home,
          state_home: state_home,
          codex_path: codex,
          node_path: node
        ).should eq(:codex_restart_required)
        handled.receive
        File.read(log).should contain("#{codex_home}|mcp add codex_bridge_relay")
      ensure
        server.try(&.close)
      end
    end
  {% else %}
    it "is a no-op outside macOS" do
      root = File.join(Dir.tempdir, "cb-install-#{Process.pid}-#{Random::Secure.hex(4)}")

      CodexBridge.install(root).should eq(:ready)
      Dir.exists?(root).should be_false
    end
  {% end %}
end
