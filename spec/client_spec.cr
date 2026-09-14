require "./spec_helper"

describe CodexBridge::Client do
  it "self-attributes a message by default" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      CodexBridge::Client.new(root).send_message(CodexBridgeSpec::TASK, "Hello")

      request = CodexBridgeSpec.helper_requests(log).last
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

      request = CodexBridgeSpec.helper_requests(log).last
      request["sourceTaskId"].as_s.should eq(CodexBridgeSpec::SOURCE)
      request["targetTaskId"].as_s.should eq(CodexBridgeSpec::TASK)
    end
  end

  it "tries the cached app-tools endpoint first" do
    CodexBridgeSpec.with_fake_app_tools do |root, log|
      client = CodexBridge::Client.new(root)
      client.send_message(CodexBridgeSpec::TASK, "First")
      ENV["CODEX_APP_TOOLS_PIPE_PATH"] = "/fake/replacement.sock"
      client.send_message(CodexBridgeSpec::TASK, "Second")

      discoveries = CodexBridgeSpec.helper_requests(log).select do |request|
        request["operation"].as_s == "discover"
      end
      discoveries.last["candidates"][0].as_s.should eq("/fake/app-tools.sock")
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
      ENV["CODEX_BRIDGE_SPEC_RESULT"] = "rejected"

      expect_raises(CodexBridge::MessageRejected, "native rejection") do
        CodexBridge::Client.new(root).send_message(CodexBridgeSpec::TASK, "Hello")
      end
    end
  end

  it "reports an uncertain helper result as receipt unknown" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      ENV["CODEX_BRIDGE_SPEC_RESULT"] = "unknown"

      expect_raises(CodexBridge::ReceiptUnknown, "connection closed") do
        CodexBridge::Client.new(root).send_message(CodexBridgeSpec::TASK, "Hello")
      end
    end
  end

  it "reports malformed post-submission helper output as receipt unknown" do
    CodexBridgeSpec.with_fake_app_tools do |root, _log|
      ENV["CODEX_BRIDGE_SPEC_RESULT"] = "malformed"

      expect_raises(CodexBridge::ReceiptUnknown, "invalid_app_tools_response") do
        CodexBridge::Client.new(root).send_message(CodexBridgeSpec::TASK, "Hello")
      end
    end
  end
end
