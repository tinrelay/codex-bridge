require "./spec_helper"

describe ".discover" do
  it "returns the resolved stock Codex connection" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      socket_file = ENV["CODEX_APP_TOOLS_PIPE_PATH"]
      connection = CodexBridge.discover(
        root,
        socket_file: socket_file,
        node_path: File.join(root, "node"),
        cache: false
      ).not_nil!

      connection.socket_file.should eq(socket_file)
      connection.node_path.should eq(File.join(root, "node"))
      connection.codex_resources.should be_nil
      File.exists?(File.join(root, "codex-bridge", "state.db")).should be_false
    end
  end

  {% if flag?(:linux) %}
    it "keeps the bundled Node path as metadata for the native transport" do
      CodexBridgeSpec.with_fake_app_tools do |root, _log|
        node = File.join(root, "node")
        File.chmod(node, 0o600)

        connection = CodexBridge.discover(root, cache: false).not_nil!

        connection.node_path.should eq(node)
      end
    end
  {% end %}
end
