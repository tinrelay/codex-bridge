require "./spec_helper"

describe ".discover" do
  it "returns the resolved stock Codex connection" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      connection = CodexBridge.discover(
        root,
        socket_file: "/explicit/app-tools.sock",
        node_path: File.join(root, "node"),
        cache: false
      ).not_nil!

      connection.socket_file.should eq("/explicit/app-tools.sock")
      connection.node_path.should eq(File.join(root, "node"))
      connection.codex_resources.should be_nil
      File.exists?(File.join(root, "codex-bridge", "state.db")).should be_false
    end
  end
end
