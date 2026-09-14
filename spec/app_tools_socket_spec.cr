require "socket"

require "./spec_helper"

{% unless flag?(:win32) %}
  module CodexBridge
    describe AppToolsNative do
      it "discovers the exact native app-tools endpoint without Node" do
        root = File.join(Dir.tempdir, "cb-socket-#{Process.pid}-#{Random::Secure.hex(4)}")
        Dir.mkdir_p(root)
        path = File.join(root, "app-tools.sock")
        server = UNIXServer.new(path)
        handled = Channel(String?).new

        spawn do
          begin
            client = server.accept
            header = Bytes.new(4)
            client.read_fully(header)
            size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
            payload = Bytes.new(size.to_i)
            client.read_fully(payload)
            request = JSON.parse(String.new(payload))
            request["method"].as_s.should eq("tools/list")

            response = {
              id:      1,
              jsonrpc: "2.0",
              result:  {
                tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
              },
            }.to_json.to_slice
            IO::ByteFormat::LittleEndian.encode(response.size.to_u32, header)
            client.write(header)
            client.write(response)
            client.close
            handled.send(nil)
          rescue ex
            handled.send(ex.message || ex.class.name)
          end
        end

        AppToolsNative.discover([path]).should eq(path)
        handled.receive.should be_nil
      ensure
        server.try(&.close)
        FileUtils.rm_r(root) if root && Dir.exists?(root)
      end
    end
  end
{% end %}
