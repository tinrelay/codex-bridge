require "./spec_helper"
require "../src/codex_bridge/platform_discovery"

module CodexBridge
  describe PlatformDiscovery do
    it "keeps native Unix app-tools sockets rooted under /tmp" do
      PlatformDiscovery::UNIX_SOCKET_ROOT.should eq("/tmp")
    end

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

        PlatformDiscovery.unix_socket_candidates(root).should eq([
          File.join(socket_root, "first.sock"),
          File.join(socket_root, "later.sock"),
        ])
      ensure
        FileUtils.rm_r(root) if root && Dir.exists?(root)
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
