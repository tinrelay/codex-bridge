require "./spec_helper"

describe CodexBridge::Client do
  it "checks a compatible idle or active task without submitting" do
    ["idle", "active"].each do |runtime|
      CodexBridgeSpec.with_peer do |peer, root|
        peer.add_turn("active-turn") if runtime == "active"

        result = CodexBridge::Client.new(root).check(CodexBridgeSpec::TASK)

        result.should eq(CodexBridge::Ready.new)
        peer.starts.should be_empty
        peer.steers.should be_empty
      end
    end
  end

  it "classifies unavailable and incompatible readiness without submitting" do
    missing = File.join(Dir.tempdir, "cb-none-#{Process.pid}")
    result = CodexBridge::Client.new(missing).check(CodexBridgeSpec::TASK)
    result.should eq(CodexBridge::Retryable.new("codex_transport_unavailable"))

    CodexBridgeSpec.with_peer do |peer, root|
      peer.runtime = "unknown"
      result = CodexBridge::Client.new(root).check(CodexBridgeSpec::TASK)

      result.should eq(CodexBridge::Incompatible.new("unknown_task_runtime"))
      peer.starts.should be_empty
      peer.steers.should be_empty
    end
  end

  it "queues untrusted attachments until idle, then starts one fresh turn" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("active-turn")
      result = Channel(CodexBridge::DeliveryResult).new(1)
      spawn do
        result.send(CodexBridge::Client.new(root).deliver(
          CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
        ))
      end
      CodexBridgeSpec.eventually do
        peer.requests.any? do |request|
          request["method"]? == "thread-follower-load-complete-history"
        end
      end
      peer.starts.should be_empty
      peer.steers.should be_empty
      peer.finish("active-turn")

      accepted = result.receive.as(CodexBridge::Accepted)
      accepted.turn_id.should eq("turn-1")
      peer.starts.size.should eq(1)
      peer.steers.should be_empty
    end
  end

  it "steers trusted-only input into the observed active turn" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("active-turn")
      delivery = CodexBridgeSpec.delivery(
        CodexBridge::DeliveryMode::Steer,
        attachments: [] of CodexBridge::UntrustedAttachment
      )
      result = CodexBridge::Client.new(root).deliver(delivery)

      result.should eq(CodexBridge::Accepted.new("active-turn"))
      peer.steers.size.should eq(1)
      peer.starts.should be_empty
      peer.steers[0]["params"]["input"][0]["text"].as_s.should eq(delivery.instruction)
    end
  end

  it "rejects active steer with untrusted attachments instead of silently queueing" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("active-turn")
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Steer)
      )

      result.should eq(CodexBridge::Incompatible.new("steer_untrusted_attachments_unsupported"))
      peer.steers.should be_empty
      peer.starts.should be_empty
    end
  end

  it "uses the full start path for idle steer with untrusted attachments" do
    CodexBridgeSpec.with_peer do |peer, root|
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Steer)
      )

      result.should eq(CodexBridge::Accepted.new("turn-1"))
      peer.starts.size.should eq(1)
      peer.steers.should be_empty
      context = peer.starts[0]["params"]["turnStart"]["context"]
      context["responseItems"].as_a.size.should eq(2)
    end
  end

  it "rechecks the selected mode after a definite idle-to-start race" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.on_start = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
        peer.add_turn("race-winner")
        peer.reply(
          connection,
          request,
          error: "App context must wait until the current turn finishes"
        )
        peer.on_start = nil
        spawn do
          sleep 20.milliseconds
          peer.finish("race-winner")
        end
        nil
      end
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      )

      result.should eq(CodexBridge::Accepted.new("turn-2"))
      peer.starts.size.should eq(2)
      peer.steers.should be_empty
    end
  end

  it "reconciles a lost accepted response from the user-message client ID" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.on_start = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
        id = "turn-lost-response"
        peer.add_turn(id)
        logical_id = request["params"]["turnStart"]["request"]["clientUserMessageId"].as_s
        peer.add_user_message(id, logical_id)
        peer.disconnect(connection)
        nil
      end
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      )

      result.should eq(CodexBridge::Accepted.new("turn-lost-response"))
      peer.starts.size.should eq(1)
    end
  end

  it "reconciles a lost accepted steer response without another submission" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("active-turn")
      peer.on_steer = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
        logical_id = request["params"]["clientUserMessageId"].as_s
        peer.add_user_message("active-turn", logical_id)
        peer.disconnect(connection)
        nil
      end
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(
          CodexBridge::DeliveryMode::Steer,
          attachments: [] of CodexBridge::UntrustedAttachment
        )
      )

      result.should eq(CodexBridge::Accepted.new("active-turn"))
      peer.steers.size.should eq(1)
      peer.starts.should be_empty
    end
  end

  it "refreshes after a definite stale steer and follows the explicit mode" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("active-turn")
      peer.on_steer = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
        peer.finish("active-turn")
        peer.reply(
          connection,
          request,
          error: "Cannot steer conversation #{CodexBridgeSpec::TASK} " +
                 "because its active turn already ended"
        )
        peer.on_steer = nil
        nil
      end
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(
          CodexBridge::DeliveryMode::Steer,
          attachments: [] of CodexBridge::UntrustedAttachment
        )
      )

      result.should eq(CodexBridge::Accepted.new("turn-1"))
      peer.steers.size.should eq(1)
      peer.starts.size.should eq(1)
    end
  end

  it "recognizes downstream expected-turn races and retries the selected mode" do
    [
      "expected active turn id `active-turn` but found `race-winner`",
      %(ExpectedTurnMismatch { expected: "active-turn", actual: "race-winner" }),
    ].each do |rejection|
      CodexBridgeSpec.with_peer do |peer, root|
        peer.add_turn("active-turn")
        peer.on_steer = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
          peer.finish("active-turn")
          peer.add_turn("race-winner")
          peer.reply(connection, request, error: rejection)
          peer.on_steer = nil
        end
        result = CodexBridge::Client.new(root).deliver(
          CodexBridgeSpec.delivery(
            CodexBridge::DeliveryMode::Steer,
            attachments: [] of CodexBridge::UntrustedAttachment
          )
        )

        result.should eq(CodexBridge::Accepted.new("race-winner"))
        peer.steers.size.should eq(2)
        peer.starts.should be_empty
      end
    end
  end

  it "waits for the promised complete-history snapshot after its response" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.on_history = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
        peer.add_turn("older-turn", "completed")
        peer.reply(connection, request, {revision: peer.revision})
        spawn do
          sleep 20.milliseconds
          peer.stream(connection)
        end
        nil
      end
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      )

      result.should eq(CodexBridge::Accepted.new("turn-1"))
      peer.starts.size.should eq(1)
    end
  end

  it "returns ambiguous after a lost response and complete-history non-observation" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.on_start = ->(connection : CodexBridgeSpec::Connection, _request : JSON::Any) do
        peer.disconnect(connection)
        nil
      end
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      )

      result.should eq(CodexBridge::Ambiguous.new("submission_not_observed"))
      peer.starts.size.should eq(1)
    end
  end

  it "returns ambiguous when stopped after the submission reaches Desktop" do
    CodexBridgeSpec.with_peer do |peer, root|
      received = Channel(Nil).new(1)
      peer.on_start = ->(_connection : CodexBridgeSpec::Connection, _request : JSON::Any) do
        received.send(nil)
      end
      control = CodexBridge::Control.new
      result = Channel(CodexBridge::DeliveryResult).new(1)
      spawn do
        result.send(CodexBridge::Client.new(root, control).deliver(
          CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
        ))
      end

      received.receive
      control.stop

      result.receive.should eq(CodexBridge::Ambiguous.new("submission_interrupted"))
      peer.starts.size.should eq(1)
    end
  end

  it "returns terminal incompatibility for duplicate accepted delivery evidence" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("turn-1", "completed")
      peer.add_user_message("turn-1", "logical-message-1")
      peer.add_turn("turn-2", "completed")
      peer.add_user_message("turn-2", "logical-message-1")
      result = CodexBridge::Client.new(root).deliver(
        CodexBridgeSpec.delivery(CodexBridge::DeliveryMode::Queue)
      )

      result.should eq(CodexBridge::Incompatible.new("duplicate_logical_message_id"))
      peer.starts.should be_empty
      peer.steers.should be_empty
    end
  end

  it "observes each terminal status without waiting for the task to become idle" do
    {
      "completed"   => CodexBridge::TerminalStatus::Completed,
      "failed"      => CodexBridge::TerminalStatus::Failed,
      "interrupted" => CodexBridge::TerminalStatus::Interrupted,
    }.each do |raw_status, expected_status|
      CodexBridgeSpec.with_peer do |peer, root|
        peer.add_turn("observed-turn")
        result = Channel(CodexBridge::ObservationResult).new(1)
        spawn do
          result.send(
            CodexBridge::Client.new(root).observe_until_terminal(
              CodexBridgeSpec::TASK,
              "observed-turn"
            )
          )
        end
        CodexBridgeSpec.eventually { peer.connections.size >= 1 }

        peer.finish_while_another_turn_is_active("observed-turn", "other-turn", raw_status)

        result.receive.should eq(CodexBridge::Terminal.new("observed-turn", expected_status))
        peer.runtime.should eq("active")
        peer.starts.should be_empty
        peer.steers.should be_empty
      end
    end
  end

  it "loads complete history before observing a terminal turn after restart" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("historical-turn", "completed")
      complete_state = JSON.parse(peer.state.to_json)
      peer.state = JSON.parse({
        threadRuntimeStatus: {type: "idle"},
        turnHistory:         {
          kind:    "canonical",
          history: {entitiesByKey: {} of String => String},
        },
      }.to_json)
      peer.on_history = ->(connection : CodexBridgeSpec::Connection, request : JSON::Any) do
        peer.state = complete_state
        peer.revision += 1
        peer.reply(connection, request, {revision: peer.revision})
        peer.stream(connection)
      end

      result = CodexBridge::Client.new(root).observe_until_terminal(
        CodexBridgeSpec::TASK,
        "historical-turn"
      )

      result.should eq(CodexBridge::Terminal.new(
        "historical-turn",
        CodexBridge::TerminalStatus::Completed
      ))
    end
  end

  it "returns retryable when complete history has not observed the accepted turn" do
    CodexBridgeSpec.with_peer do |peer, root|
      result = CodexBridge::Client.new(root).observe_until_terminal(
        CodexBridgeSpec::TASK,
        "accepted-but-lagging"
      )

      result.should eq(CodexBridge::Retryable.new("accepted_turn_not_observed"))
      peer.starts.should be_empty
      peer.steers.should be_empty
    end
  end

  it "reconciles one logical ID without submitting or inferring from absence" do
    CodexBridgeSpec.with_peer do |peer, root|
      peer.add_turn("observed-turn", "completed")
      peer.add_user_message("observed-turn", "observed-id")
      peer.add_provisional_message("provisional-id")
      client = CodexBridge::Client.new(root)

      observed = client.reconcile(CodexBridgeSpec::TASK, "observed-id")
      provisional = client.reconcile(CodexBridgeSpec::TASK, "provisional-id")
      absent = client.reconcile(CodexBridgeSpec::TASK, "absent-id")

      observed.should eq(CodexBridge::LogicalMessageObserved.new("observed-turn"))
      provisional.should eq(CodexBridge::LogicalMessageProvisional.new)
      absent.should eq(CodexBridge::LogicalMessageNotObserved.new)
      peer.starts.should be_empty
      peer.steers.should be_empty
    end
  end
end
