require "./spec_helper"
require "../src/codex_bridge/platform_discovery"

module CodexBridge
  describe PlatformDiscovery do
    it "keeps native Unix app-tools sockets rooted under /tmp" do
      PlatformDiscovery::UNIX_SOCKET_ROOT.should eq("/tmp")
    end

    {% if flag?(:darwin) %}
      it "does not scan stock app-tools sockets on macOS" do
        PlatformDiscovery.socket_candidates.should be_empty
      end
    {% end %}

    {% unless flag?(:win32) %}
      it "describes the stock Linux resources layout" do
        PlatformDiscovery.linux_resource_candidates("/opt/chatgpt").should eq([
          "/opt/chatgpt/resources",
        ])
      end

      it "enumerates deterministic Unix app-tools socket candidates" do
        root = File.join(Dir.tempdir, "cb-platform-#{Process.pid}-#{Random::Secure.hex(4)}")
        socket_root = File.join(root, "codex-browser-use")
        Dir.mkdir_p(socket_root)
        File.touch(File.join(socket_root, "later.sock"))
        File.touch(File.join(socket_root, "ignored"))
        File.touch(File.join(socket_root, "first.sock"))
        relay = File.join(socket_root, "#{PlatformDiscovery::RELAY_SOCKET_PREFIX}123.sock")
        File.touch(relay)

        PlatformDiscovery.unix_socket_candidates(root).should eq([
          File.join(socket_root, "first.sock"),
          File.join(socket_root, "later.sock"),
        ])
        PlatformDiscovery.relay_socket_candidates(socket_root).should eq([relay])
      ensure
        FileUtils.rm_r(root) if root && Dir.exists?(root)
      end

      it "does not mistake similarly named stock sockets for relay sockets" do
        PlatformDiscovery.relay_socket?("/tmp/codex-browser-use/relay-123.sock").should be_true
        PlatformDiscovery.relay_socket?("/tmp/codex-browser-use/codex-bridge-relay.sock").should be_false
        PlatformDiscovery.relay_socket?("/tmp/codex-browser-use/not-relay-123.sock").should be_false
      end
    {% end %}

    it "derives Windows resources from the installed AppX location" do
      PlatformDiscovery.windows_resources([
        "progress noise",
        %q(C:\Program Files\WindowsApps\OpenAI.Codex_26.1_arm64__publisher),
      ]).should eq([
        %q(C:\Program Files\WindowsApps\OpenAI.Codex_26.1_arm64__publisher\app\resources),
      ])
    end

    it "filters and sorts Windows app-tools named pipes" do
      PlatformDiscovery.windows_pipes([
        %q(\\.\pipe\codex-browser-use-z),
        %q(\\.\pipe\codex-ipc),
        %q(\\.\pipe\codex-browser-use-a),
        %q(\\.\pipe\codex-browser-use-a),
      ]).should eq([
        %q(\\.\pipe\codex-browser-use-a),
        %q(\\.\pipe\codex-browser-use-z),
      ])
    end
  end
end
