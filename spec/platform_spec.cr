require "./spec_helper"

module CodexBridge
  describe Platform do
    {% if flag?(:darwin) %}
      it "enumerates deterministic relay candidates" do
        root = File.join(Dir.tempdir, "cb-platform-#{Process.pid}-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(root)
        later = File.join(root, "#{Platform::RELAY_SOCKET_PREFIX}z.sock")
        first = File.join(root, "#{Platform::RELAY_SOCKET_PREFIX}a.sock")
        File.touch(later)
        File.touch(first)
        File.touch(File.join(root, "unrelated.sock"))

        Platform.relay_socket_candidates(root).should eq([first, later])
      ensure
        FileUtils.rm_r(root) if root && Dir.exists?(root)
      end

      it "does not scan stock app-tools sockets on macOS" do
        Platform.socket_candidates.should be_empty
      end
    {% elsif flag?(:win32) %}
      it "enumerates live app-tools pipes through the Windows adapter" do
        CodexBridgeSpec.with_fake_app_tools do
          pipe = ENV["CODEX_APP_TOOLS_PIPE_PATH"]
          Platform.socket_candidates.should contain(pipe)
        end
      end

      it "does not invoke package discovery for optional runtime metadata" do
        Platform.resource_candidates.should be_empty
      end

      it "does not scan macOS relay sockets on Windows" do
        Platform.relay_socket_candidates("ignored").should be_empty
      end
    {% elsif flag?(:linux) %}
      it "describes the stock Linux resources layout" do
        Platform.resource_candidates.should eq(["/usr/lib/chatgpt/resources"])
      end

      it "does not scan macOS relay sockets on Linux" do
        Platform.relay_socket_candidates("ignored").should be_empty
      end

      it "enumerates deterministic Unix app-tools socket candidates" do
        root = File.join(Dir.tempdir, "cb-platform-#{Process.pid}-#{Random::Secure.hex(4)}")
        socket_root = File.join(root, "codex-browser-use")
        Dir.mkdir_p(socket_root)
        File.touch(File.join(socket_root, "later.sock"))
        File.touch(File.join(socket_root, "ignored"))
        File.touch(File.join(socket_root, "first.sock"))
        relay = File.join(socket_root, "#{Platform::RELAY_SOCKET_PREFIX}123.sock")
        File.touch(relay)

        Platform.socket_candidates(root).should eq([
          File.join(socket_root, "first.sock"),
          File.join(socket_root, "later.sock"),
        ])
      ensure
        FileUtils.rm_r(root) if root && Dir.exists?(root)
      end
    {% else %}
      {% raise "codex-bridge specs do not support this platform" %}
    {% end %}
  end
end
