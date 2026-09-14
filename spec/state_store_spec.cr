require "./spec_helper"

module CodexBridge
  describe StateStore do
    it "stores small runtime values in one private database" do
      CodexBridgeSpec.with_fake_app_tools do |root, _log|
        store = StateStore.new(root)
        store.get("missing").should be_nil
        store.put("app_tools_pipe", "/tmp/first.sock").should be_true
        store.put("app_tools_pipe", "/tmp/second.sock").should be_true
        store.get("app_tools_pipe").should eq("/tmp/second.sock")
        File.file?(File.join(root, "state.db")).should be_true
      end
    end
  end
end
