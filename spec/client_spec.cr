require "./spec_helper"

describe CodexBridge::Client do
  {% unless flag?(:win32) %}
    it "waits for the app-tools relay before submitting" do
      root = File.join(Dir.tempdir, "cb-client-#{Process.pid}-#{Random::Secure.hex(4)}")
      state_home = File.join(root, "state")
      socket_file = File.join(root, "relay.sock")
      Dir.mkdir_p(root)
      handled = Channel(String?).new
      server = nil.as(UNIXServer?)

      spawn do
        begin
          sleep 250.milliseconds
          listening = UNIXServer.new(socket_file)
          server = listening
          2.times do |index|
            client = listening.accept
            header = Bytes.new(4)
            client.read_fully(header)
            size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
            body = Bytes.new(size.to_i)
            client.read_fully(body)
            request = JSON.parse(String.new(body))
            if index == 0
              request["method"].as_s.should eq("tools/list")
              result = {
                tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
              }
            else
              request["method"].as_s.should eq("tools/call")
              result = {
                success:      true,
                contentItems: [{type: "inputText", text: {threadId: CodexBridgeSpec::TASK}.to_json}],
              }
            end
            response = {id: 1, jsonrpc: "2.0", result: result}.to_json.to_slice
            IO::ByteFormat::LittleEndian.encode(response.size.to_u32, header)
            client.write(header)
            client.write(response)
            client.close
          end
          listening.close
          handled.send(nil)
        rescue ex
          handled.send(ex.message || ex.class.name)
        end
      end

      CodexBridge::Client.new(
        root,
        state_home: state_home,
        socket_file: socket_file,
        cache: false,
        timeout: 2.seconds
      ).send_message(CodexBridgeSpec::TASK, "Hello")
      handled.receive.should be_nil
    ensure
      server.try(&.close)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end
  {% end %}

  it "can disable the discovery wait" do
    root = File.join(Dir.tempdir, "cb-client-#{Process.pid}-#{Random::Secure.hex(4)}")
    socket_file = File.join(root, "missing.sock")
    Dir.mkdir_p(root)

    started = Time.instant
    expect_raises(CodexBridge::TaskUnavailable, "app_tools_unavailable") do
      CodexBridge::Client.new(
        root,
        socket_file: socket_file,
        cache: false,
        timeout: 0.seconds
      ).send_message(CodexBridgeSpec::TASK, "Hello")
    end
    (Time.instant - started).should be < 250.milliseconds
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "delivers without resolving optional runtime metadata" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      previous_node = ENV.delete("CODEX_MCP_NODE_PATH")
      previous_resources = ENV.delete("CODEX_ELECTRON_RESOURCES_PATH")
      begin
        CodexBridge::Client.new(
          root,
          socket_file: ENV["CODEX_APP_TOOLS_PIPE_PATH"],
          cache: false,
          timeout: 2.seconds
        ).send_message(CodexBridgeSpec::TASK, "Hello")

        CodexBridgeSpec.transport_requests(log).last["operation"].as_s.should eq("send")
      ensure
        CodexBridgeSpec.restore_env("CODEX_MCP_NODE_PATH", previous_node)
        CodexBridgeSpec.restore_env("CODEX_ELECTRON_RESOURCES_PATH", previous_resources)
      end
    end
  end

  it "rejects a negative timeout" do
    expect_raises(ArgumentError, "timeout cannot be negative") do
      CodexBridge::Client.new(timeout: -1.second)
    end
  end

  it "self-attributes a message by default" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      CodexBridge::Client.new(root).send_message(CodexBridgeSpec::TASK, "Hello")

      request = CodexBridgeSpec.transport_requests(log).last
      request["sourceTaskId"].as_s.should eq(CodexBridgeSpec::TASK)
      request["targetTaskId"].as_s.should eq(CodexBridgeSpec::TASK)
      request["prompt"].as_s.should eq("Hello")
    end
  end

  it "uses an explicit source task" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      CodexBridge::Client.new(root).send_message(
        CodexBridgeSpec::TASK,
        "Hello",
        from: CodexBridgeSpec::SOURCE
      )

      request = CodexBridgeSpec.transport_requests(log).last
      request["sourceTaskId"].as_s.should eq(CodexBridgeSpec::SOURCE)
      request["targetTaskId"].as_s.should eq(CodexBridgeSpec::TASK)
    end
  end

  it "tries the cached app-tools endpoint first" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      initial = ENV["CODEX_APP_TOOLS_PIPE_PATH"]
      client = CodexBridge::Client.new(root)
      client.send_message(CodexBridgeSpec::TASK, "First")
      ENV["CODEX_APP_TOOLS_PIPE_PATH"] = "/fake/replacement.sock"
      client.send_message(CodexBridgeSpec::TASK, "Second")

      discoveries = CodexBridgeSpec.transport_requests(log).select do |request|
        request["operation"].as_s == "discover"
      end
      discoveries.last["candidates"][0].as_s.should eq(initial)
    end
  end

  it "rejects invalid task IDs before contacting Codex" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      expect_raises(ArgumentError, "invalid local task id") do
        CodexBridge::Client.new(root).send_message("not-a-task", "Hello")
      end

      File.exists?(log).should be_false
    end
  end

  it "reports an authoritative native rejection as not received" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      CodexBridgeSpec.fake_result("rejected")

      expect_raises(CodexBridge::MessageRejected, "native rejection") do
        CodexBridge::Client.new(root).send_message(CodexBridgeSpec::TASK, "Hello")
      end
    end
  end

  it "reports an uncertain transport result as receipt unknown" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      CodexBridgeSpec.fake_result("unknown")

      expect_raises(CodexBridge::ReceiptUnknown, "connection closed") do
        CodexBridge::Client.new(root, timeout: 2.seconds)
          .send_message(CodexBridgeSpec::TASK, "Hello")
      end
    end
  end

  it "confirms a delivery from Codex history after the native receipt is lost" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      history = File.join(root, "thread_history_1.sqlite")
      DB.open("sqlite3://#{URI.encode_path(history)}") do |database|
        database.exec(<<-SQL)
          CREATE TABLE thread_items (
            thread_id TEXT NOT NULL,
            rollout_ordinal INTEGER NOT NULL,
            item_type TEXT NOT NULL,
            item_json TEXT NOT NULL
          )
        SQL
      end
      CodexBridgeSpec.fake_result("unknown")
      inserted = Channel(Nil).new(1)
      spawn do
        until File.exists?(log) && CodexBridgeSpec.transport_requests(log).any? do |request|
                request["operation"].as_s == "send"
              end
          sleep 10.milliseconds
        end
        wrapper = "<codex_delegation>\n" +
                  "  <source_thread_id>#{CodexBridgeSpec::TASK}</source_thread_id>\n" +
                  "  <input>Hello</input>\n" +
                  "</codex_delegation>"
        item = {
          type:      "functionCallOutput",
          name:      "send_message_to_thread",
          namespace: "codex_app",
          output:    wrapper,
        }
        DB.open("sqlite3://#{URI.encode_path(history)}") do |database|
          database.exec(
            "INSERT INTO thread_items VALUES (?, ?, ?, ?)",
            CodexBridgeSpec::TASK,
            1,
            "functionCallOutput",
            item.to_json
          )
        end
        inserted.send(nil)
      end

      CodexBridge::Client.new(root, timeout: 2.seconds)
        .send_message(CodexBridgeSpec::TASK, "Hello")
      inserted.receive
      CodexBridgeSpec.transport_requests(log).count do |request|
        request["operation"].as_s == "send"
      end.should eq(1)
    end
  end

  it "reports malformed post-submission transport output as receipt unknown" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      CodexBridgeSpec.fake_result("malformed")

      expect_raises(CodexBridge::ReceiptUnknown, "invalid_app_tools_response") do
        CodexBridge::Client.new(root, timeout: 2.seconds)
          .send_message(CodexBridgeSpec::TASK, "Hello")
      end
    end
  end
end
