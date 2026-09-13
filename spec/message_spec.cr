require "./spec_helper"

module CodexBridge
  describe Delivery do
    it "requires an explicit tagged delivery mode" do
      delivery = CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      delivery.mode.should eq(CodexBridge::DeliveryMode::Queue)
    end

    it "keeps attachments in the structured untrusted start representation" do
      delivery = CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      message = Message.new(delivery)
      params = JSON.parse(message.start_params.to_json)
      turn = params["turnStart"]
      input = turn["request"]["input"][0]
      input["text"].as_s.should eq(delivery.instruction)
      placeholder = input["text_elements"][0]["placeholder"].as_s
      envelope = JSON.parse(placeholder.lchop("codex-untrusted-app-input:"))
      attachment = envelope["modelContextAttachments"][0]
      attachment["untrusted"].as_bool.should be_true
      attachment["text"].as_s.should eq("untrusted text")
      items = turn["context"]["responseItems"]
      items[0]["name"].as_s.should eq("untrusted_input")
      items[0]["call_id"].should eq(items[1]["call_id"])
      body = JSON.parse(items[1]["output"][0]["text"].as_s)
      body["sourceId"].as_s.should eq("event-1")
      body["text"].as_s.should eq("untrusted text")
    end

    it "builds trusted-only steer input without an untrusted placeholder" do
      delivery = CodexBridgeSpec.delivery(
        CodexBridge::DeliveryMode::Steer,
        attachments: [] of CodexBridge::UntrustedAttachment
      )
      params = JSON.parse(Message.new(delivery).steer_params.to_json)
      input = params["input"][0]
      input["text"].as_s.should eq(delivery.instruction)
      input["text_elements"].as_a.should be_empty
      params["clientUserMessageId"].as_s.should eq(delivery.logical_message_id)
      params["restoreMessage"]["context"]["workspaceRoots"].as_a.should be_empty
    end
  end
end
