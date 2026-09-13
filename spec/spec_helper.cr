require "spec"
require "file_utils"

require "../src/codex_bridge"
require "./support/peer"

module CodexBridgeSpec
  TASK = "11111111-2222-3333-4444-555555555555"

  def self.delivery(
    mode : CodexBridge::DeliveryMode,
    id = "logical-message-1",
    attachments = [CodexBridge::UntrustedAttachment.new("event-1", "Event", "untrusted text")],
  )
    CodexBridge::Delivery.new(
      task_id: TASK,
      instruction: "Caller-owned trusted instruction.",
      attachments: attachments,
      logical_message_id: id,
      mode: mode,
    )
  end

  def self.eventually(within = 3.seconds, &)
    deadline = Time.instant + within
    until yield
      raise "condition did not become true" if Time.instant >= deadline
      sleep 10.milliseconds
    end
  end

  def self.with_peer(&)
    root = File.join(Dir.tempdir, "cb-#{Process.pid}-#{UUID.random.to_s[0, 8]}")
    peer = Peer.new(root)
    yield peer, root
  ensure
    peer.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
