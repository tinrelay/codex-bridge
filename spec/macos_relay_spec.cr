require "./spec_helper"

{% if flag?(:darwin) %}
  module CodexBridgeSpec
    def self.read_frame(io) : JSON::Any
      header = Bytes.new(4)
      io.read_fully(header)
      size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
      body = Bytes.new(size.to_i)
      io.read_fully(body)
      JSON.parse(String.new(body))
    end

    def self.write_frame(io, value)
      body = value.to_json.to_slice
      header = Bytes.new(4)
      IO::ByteFormat::LittleEndian.encode(body.size.to_u32, header)
      io.write(header)
      io.write(body)
      io.flush
    end
  end

  module CodexBridge
    describe "the macOS relay" do
      it "waits for the app-tools pipe during Codex startup" do
        root = "/tmp/cbr-#{Process.pid}-#{Random::Secure.hex(4)}"
        state_home = File.join(root, "state")
        stock_path = File.join(root, "stock.sock")
        Dir.mkdir_p(root)

        resources = PlatformDiscovery.resource_candidates.first
        node = File.join(resources, "cua_node", "bin", "node")
        relay_source = File.expand_path("../src/codex_bridge/macos_relay/relay.mjs", __DIR__)
        process = Process.new(
          node,
          [relay_source, "spec-generation"],
          env: {
            "CODEX_APP_TOOLS_PIPE_PATH" => stock_path,
            "CODEX_BRIDGE_STATE_HOME"   => state_home,
          },
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Close,
          error: Process::Redirect::Inherit
        )

        sleep 250.milliseconds
        stock = UNIXServer.new(stock_path)
        handled = Channel(String?).new
        spawn do
          begin
            client = stock.accept
            request = CodexBridgeSpec.read_frame(client)
            request["method"].as_s.should eq("tools/list")
            CodexBridgeSpec.write_frame(client, {
              id:      1,
              jsonrpc: "2.0",
              result:  {
                tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
              },
            })
            client.close
            handled.send(nil)
          rescue ex
            handled.send(ex.message || ex.class.name)
          end
        end

        relay_path = nil.as(String?)
        300.times do
          relay_path = PlatformDiscovery.relay_socket_candidates(state_home).first?
          break if relay_path
          sleep 10.milliseconds
        end
        relay_path.should_not be_nil
        File.basename(relay_path.not_nil!).should eq("relay-#{process.pid}.sock")
        handled.receive.should be_nil
      ensure
        process.try do |child|
          child.input.try(&.close)
          child.wait
        end
        stock.try(&.close)
        FileUtils.rm_r(root) if root && Dir.exists?(root)
      end

      it "preserves receipt uncertainty after forwarding a mutating request" do
        root = "/tmp/cbr-#{Process.pid}-#{Random::Secure.hex(4)}"
        state_home = File.join(root, "state")
        stock_path = File.join(root, "stock.sock")
        Dir.mkdir_p(root)
        stock = UNIXServer.new(stock_path)
        handled = Channel(String?).new

        spawn do
          begin
            2.times do
              client = stock.accept
              request = CodexBridgeSpec.read_frame(client)
              request["method"].as_s.should eq("tools/list")
              CodexBridgeSpec.write_frame(client, {
                id:      1,
                jsonrpc: "2.0",
                result:  {
                  tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
                },
              })
              client.close
            end

            client = stock.accept
            request = CodexBridgeSpec.read_frame(client)
            request["method"].as_s.should eq("tools/call")
            client.close
            handled.send(nil)
          rescue ex
            handled.send(ex.message || ex.class.name)
          end
        end

        resources = PlatformDiscovery.resource_candidates.first
        node = File.join(resources, "cua_node", "bin", "node")
        relay_source = File.expand_path("../src/codex_bridge/macos_relay/relay.mjs", __DIR__)
        process = Process.new(
          node,
          [relay_source, "spec-generation"],
          env: {
            "CODEX_APP_TOOLS_PIPE_PATH" => stock_path,
            "CODEX_BRIDGE_STATE_HOME"   => state_home,
          },
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Close,
          error: Process::Redirect::Inherit
        )

        relay_path = nil.as(String?)
        200.times do
          relay_path = PlatformDiscovery.relay_socket_candidates(state_home).first?
          break if relay_path
          sleep 10.milliseconds
        end
        relay_path.should_not be_nil
        File.info(state_home).permissions.value.should eq(0o700)
        File.info(relay_path.not_nil!).permissions.value.should eq(0o600)

        expect_raises(ReceiptUnknown) do
          Client.new(
            root,
            state_home: state_home,
            socket_file: relay_path,
            cache: false
          ).send_message(CodexBridgeSpec::TASK, "Hello")
        end
        handled.receive.should be_nil
      ensure
        process.try do |child|
          child.input.try(&.close)
          child.wait
        end
        stock.try(&.close)
        FileUtils.rm_r(root) if root && Dir.exists?(root)
      end
    end
  end
{% end %}
