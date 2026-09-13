module CodexBridge
  {% if flag?(:win32) %}
    private alias CodexTransport = File
  {% else %}
    private alias CodexTransport = UNIXSocket
  {% end %}

  private class Session
    MAX_FRAME               = 268_435_456
    REQUEST_TIMEOUT         = 20.seconds
    COMPLETE_HISTORY_METHOD = "thread-follower-load-complete-history"
    RETRYABLE_HISTORY       = {
      "Conversation must be resumed before loading history"     => "conversation_not_resumed",
      "no-client-found: thread stream owner became unavailable" => "owner_unavailable",
      "no-client-found: thread stream owner is unavailable"     => "owner_unavailable",
      "no-client-found: thread stream owner changed"            => "owner_changed",
      "no-client-found: thread stream owner disconnected"       => "owner_disconnected",
      "client-disconnected"                                     => "owner_window_unavailable",
      "no-client-found: client-disconnected"                    => "owner_window_unavailable",
      "no-client-found: webcontents-destroyed"                  => "owner_window_unavailable",
      "no-client-found: webview-disposed"                       => "owner_window_unavailable",
      "no-client-found: provider-disposed"                      => "owner_window_unavailable",
    }

    getter lifecycle = Lifecycle.new
    @client_id = ""
    @owner_id = ""
    @subscribed = false

    def initialize(@socket : CodexTransport, @task_id : String, @control : Control)
      handshake
    end

    def subscribe
      @subscribed = true
      refresh
    end

    def refresh
      lifecycle.invalidate
      following(true)
      deadline = Time.instant + REQUEST_TIMEOUT
      while lifecycle.revision.nil?
        receive(deadline)
      end
    rescue Deadline
      raise RetryableFailure.new("lifecycle_snapshot_unavailable")
    end

    def close
      begin
        following(false) if @subscribed && !@socket.closed?
      rescue Disconnected | Stopped
      ensure
        @socket.close
      end
    end

    def load_complete_history(logical_id : String) : MessageMatch
      deadline = Time.instant + REQUEST_TIMEOUT
      response = rpc(
        COMPLETE_HISTORY_METHOD,
        {conversationId: @task_id},
        1,
        @owner_id,
        deadline
      )
      revision = response.as_h["result"].as_h["revision"].as_i64
      current_revision = lifecycle.revision ||
                         raise IncompatibleFailure.new("complete_history_revision_mismatch")
      if current_revision > revision
        raise IncompatibleFailure.new("complete_history_revision_mismatch")
      end
      while current_revision < revision
        receive(deadline)
        current_revision = lifecycle.revision ||
                           raise IncompatibleFailure.new("complete_history_revision_mismatch")
        if current_revision > revision
          raise IncompatibleFailure.new("complete_history_revision_mismatch")
        end
      end
      lifecycle.message_match(logical_id)
    rescue TypeCastError | KeyError
      raise IncompatibleFailure.new("invalid_complete_history_response")
    rescue Deadline
      raise RetryableFailure.new("complete_history_snapshot_unavailable")
    end

    def wait_idle
      loop do
        @control.check
        refresh if lifecycle.revision.nil?
        case lifecycle.runtime
        when "idle"   then return
        when "active" then receive
        else
          raise IncompatibleFailure.new("unknown_task_runtime")
        end
      end
    end

    def wait_active_turn : String?
      @control.check
      refresh if lifecycle.revision.nil?
      case lifecycle.runtime
      when "idle"
        nil
      when "active"
        lifecycle.active_turn_id || begin
          refresh
          lifecycle.active_turn_id ||
            raise RetryableFailure.new("active_turn_unavailable")
        end
      else
        raise IncompatibleFailure.new("unknown_task_runtime")
      end
    end

    def start(message : Message) : String
      response = rpc(
        "thread-follower-start-turn",
        message.start_params,
        2,
        @owner_id,
        submission: true
      )
      turn = response.as_h["result"].as_h["result"].as_h["turn"]
      id = turn.as_h["id"].as_s
      raise IncompatibleFailure.new("invalid_accepted_turn") if id.empty?
      id
    rescue TypeCastError | KeyError
      raise IncompatibleFailure.new("invalid_start_response")
    end

    def steer(message : Message, expected_turn_id : String) : String
      response = rpc(
        "thread-follower-steer-turn",
        message.steer_params,
        1,
        @owner_id,
        submission: true
      )
      id = response.as_h["result"].as_h["result"].as_h["turnId"].as_s
      raise IncompatibleFailure.new("invalid_accepted_turn") if id.empty?
      unless id == expected_turn_id
        raise IncompatibleFailure.new("steer_turn_mismatch")
      end
      id
    rescue TypeCastError | KeyError
      raise IncompatibleFailure.new("invalid_steer_response")
    end

    private def handshake
      @socket.read_timeout = 250.milliseconds
      @socket.write_timeout = 2.seconds
      response = rpc("initialize", {clientType: "codex-bridge"}, 0)
      @client_id = response.as_h["result"].as_h["clientId"].as_s
      raise IncompatibleFailure.new("invalid_client_id") if @client_id.empty?
      response = rpc(
        "thread-owner-discovery",
        {hostId: "local", conversationId: @task_id},
        1
      )
      @owner_id = response.as_h["handledByClientId"].as_s
      raise IncompatibleFailure.new("invalid_owner_id") if @owner_id.empty?
      unless response.as_h["result"].as_h["supportsUntrustedAppInput"].as_bool
        raise IncompatibleFailure.new("untrusted_input_unsupported")
      end
    rescue TypeCastError | KeyError
      raise IncompatibleFailure.new("invalid_ipc_handshake")
    end

    private def following(value)
      send_frame({
        type:            "broadcast",
        method:          "thread-stream-following-changed",
        version:         1,
        sourceClientId:  @client_id,
        targetClientIds: [@owner_id],
        params:          {hostId: "local", conversationId: @task_id, following: value},
      })
    end

    private def rpc(method, params, version, target : String? = nil,
                    deadline : Time::Instant? = nil, submission = false)
      request_id = UUID.random.to_s
      message = JSON.parse({
        type:      "request",
        requestId: request_id,
        method:    method,
        params:    params,
        version:   version,
        timeoutMs: 20_000,
      }.to_json)
      message.as_h["sourceClientId"] = JSON::Any.new(@client_id) unless @client_id.empty?
      message.as_h["targetClientId"] = JSON::Any.new(target) if target
      sent = false
      send_frame(message)
      sent = true
      request_deadline = deadline || Time.instant + REQUEST_TIMEOUT
      loop do
        response = receive(request_deadline)
        next unless response.as_h["type"]?.try(&.as_s?) == "response" &&
                    response.as_h["requestId"]?.try(&.as_s?) == request_id
        if response.as_h["resultType"]?.try(&.as_s?) == "error"
          classify_rejection(method, response.as_h["error"]?.try(&.as_s?))
        end
        unless response.as_h["resultType"]?.try(&.as_s?) == "success"
          raise IncompatibleFailure.new("invalid_ipc_result")
        end
        if method != "initialize" && response.as_h["method"]?.try(&.as_s?) != method
          raise IncompatibleFailure.new("ipc_response_method_mismatch")
        end
        if target && response.as_h["handledByClientId"]?.try(&.as_s?) != target
          raise IncompatibleFailure.new("ipc_response_owner_mismatch")
        end
        return response
      end
    rescue ex : Stopped
      raise SubmissionInterrupted.new if submission && sent
      raise ex
    end

    private def classify_rejection(method, reason : String?) : NoReturn
      if method == "thread-follower-start-turn" &&
         reason == "App context must wait until the current turn finishes"
        raise Busy.new
      end
      if method == "thread-follower-steer-turn" && stale_steer?(reason)
        raise StaleTurn.new
      end
      raise RetryableFailure.new("no_compatible_task_owner") if reason == "no-client-found"
      if method == COMPLETE_HISTORY_METHOD
        if classification = RETRYABLE_HISTORY[reason]?
          raise RetryableFailure.new("history_#{classification}")
        end
      end
      raise IncompatibleFailure.new("ipc_request_rejected:#{method}:unclassified")
    end

    private def stale_steer?(reason : String?)
      return true if reason == "no active turn to steer" || reason == "NoActiveTurn"
      return true if reason ==
                       "Cannot steer conversation #{@task_id} because its active turn already ended"
      return true if reason == "Cannot steer conversation #{@task_id} without an active turn id"
      return false unless reason
      return true if reason.matches?(
                       /\Aexpected active turn id `[^`\s]+` but found `[^`\s]+`\z/
                     )
      reason.matches?(
        /\AExpectedTurnMismatch\s*\{[^}\r\n]*\bactual:\s*"[^"\r\n]+"[^}\r\n]*\}\z/
      )
    end

    private def send_frame(value)
      @control.check
      bytes = value.to_json.to_slice
      raise IncompatibleFailure.new("ipc_frame_too_large") if bytes.size > MAX_FRAME
      @socket.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
      @socket.write(bytes)
      @socket.flush
    rescue IO::Error
      raise Disconnected.new
    end

    private def read_exact(size, deadline : Time::Instant?)
      bytes = Bytes.new(size)
      offset = 0
      while offset < size
        @control.check
        raise Deadline.new if deadline && Time.instant >= deadline
        begin
          count = @socket.read(bytes[offset..])
          raise Disconnected.new if count == 0
          offset += count
        rescue IO::TimeoutError
        rescue IO::Error
          raise Disconnected.new
        end
      end
      bytes
    end

    private def receive(deadline : Time::Instant? = nil) : JSON::Any
      header = read_exact(4, deadline)
      size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
      raise IncompatibleFailure.new("invalid_ipc_frame_length") unless 0 < size <= MAX_FRAME
      frame = JSON.parse(String.new(read_exact(size.to_i, deadline)))
      consume(frame)
      frame
    rescue JSON::ParseException | TypeCastError | KeyError
      raise IncompatibleFailure.new("invalid_ipc_message")
    end

    private def consume(frame)
      case frame.as_h["type"]?.try(&.as_s?)
      when "client-discovery-request"
        send_frame({
          type:      "client-discovery-response",
          requestId: frame.as_h["requestId"].as_s,
          response:  {canHandle: false},
        })
      when "broadcast"
        if frame.as_h["method"]?.try(&.as_s?) == "thread-stream-state-changed" &&
           frame.as_h["sourceClientId"]?.try(&.as_s?) == @owner_id
          params = frame.as_h["params"]
          if params.as_h["hostId"]?.try(&.as_s?) == "local" &&
             params.as_h["conversationId"]?.try(&.as_s?) == @task_id
            unless frame.as_h["version"].as_i == 11
              raise IncompatibleFailure.new("unsupported_lifecycle_version")
            end
            lifecycle.update(params.as_h["change"])
          end
        elsif frame.as_h["method"]?.try(&.as_s?) == "client-status-changed"
          params = frame.as_h["params"]
          if params.as_h["clientId"]?.try(&.as_s?) == @owner_id &&
             params.as_h["status"]?.try(&.as_s?) == "disconnected"
            raise Disconnected.new
          end
        end
      end
    end
  end
end
