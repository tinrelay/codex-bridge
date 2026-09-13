module CodexBridge
  class Client
    def initialize(
      @codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s,
      @control = Control.new,
    )
    end

    def deliver(delivery : Delivery) : DeliveryResult
      session = connect(delivery.task_id)
      session.subscribe
      message = Message.new(delivery)
      match = session.load_complete_history(delivery.logical_message_id)
      case match.state
      when MessageState::Accepted
        return Accepted.new(match.turn_id.not_nil!)
      when MessageState::Provisional
        return Ambiguous.new("submission_provisional")
      when MessageState::Absent
      end

      loop do
        expected_turn = case delivery.mode
                        when DeliveryMode::Queue
                          session.wait_idle
                          nil
                        when DeliveryMode::Steer
                          session.wait_active_turn
                        else
                          return Incompatible.new("unsupported_delivery_mode")
                        end
        if expected_turn && !delivery.attachments.empty?
          return Incompatible.new("steer_untrusted_attachments_unsupported")
        end
        begin
          turn_id = if expected_turn
                      session.steer(message, expected_turn)
                    else
                      session.start(message)
                    end
          return Accepted.new(turn_id)
        rescue Busy | StaleTurn
          session.refresh
        rescue Disconnected
          return reconcile_unknown(delivery)
        rescue SubmissionInterrupted
          return Ambiguous.new("submission_interrupted")
        end
      end
    rescue ex : RetryableFailure | Disconnected
      Retryable.new(ex.message || "delivery_unavailable")
    rescue ex : IncompatibleFailure
      Incompatible.new(ex.message || "desktop_incompatible")
    rescue Stopped
      Retryable.new("stopped")
    ensure
      session.try(&.close)
    end

    def check(task_id : String) : ReadinessResult
      validate_task_id(task_id)
      session = connect(task_id)
      session.subscribe
      session.validate_available
      Ready.new
    rescue ex : RetryableFailure | Disconnected
      Retryable.new(ex.message || "delivery_unavailable")
    rescue ex : IncompatibleFailure
      Incompatible.new(ex.message || "desktop_incompatible")
    rescue Stopped
      Retryable.new("stopped")
    ensure
      session.try(&.close)
    end

    def observe_until_terminal(task_id : String, turn_id : String) : ObservationResult
      validate_task_id(task_id)
      raise ArgumentError.new("invalid turn id") if turn_id.empty?
      session = connect(task_id)
      session.subscribe
      session.load_complete_history
      status = session.observe_until_terminal(turn_id)
      Terminal.new(turn_id, status)
    rescue ex : RetryableFailure | Disconnected
      Retryable.new(ex.message || "delivery_unavailable")
    rescue ex : IncompatibleFailure
      Incompatible.new(ex.message || "desktop_incompatible")
    rescue Stopped
      Retryable.new("stopped")
    ensure
      session.try(&.close)
    end

    private def reconcile_unknown(delivery) : DeliveryResult
      session = connect(delivery.task_id)
      session.subscribe
      match = session.load_complete_history(delivery.logical_message_id)
      case match.state
      when MessageState::Accepted
        Accepted.new(match.turn_id.not_nil!)
      when MessageState::Provisional
        Ambiguous.new("submission_provisional")
      when MessageState::Absent
        Ambiguous.new("submission_not_observed")
      else
        raise IncompatibleFailure.new("unknown_message_state")
      end
    rescue ex : RetryableFailure | Disconnected | Stopped
      Ambiguous.new(ex.message || "history_unavailable")
    rescue ex : IncompatibleFailure
      Incompatible.new(ex.message || "desktop_incompatible")
    ensure
      session.try(&.close)
    end

    private def connect(task_id) : Session
      @control.check
      socket = open_socket
      Session.new(socket, task_id, @control)
    rescue IO::Error
      raise RetryableFailure.new("codex_transport_unavailable")
    end

    private def validate_task_id(task_id)
      unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(task_id)
        raise ArgumentError.new("invalid local task id")
      end
    end

    private def open_socket : CodexTransport
      {% if flag?(:win32) %}
        File.open(%(\\\\.\\pipe\\codex-ipc), "r+", blocking: false)
      {% else %}
        UNIXSocket.new(File.join(@codex_home, "ipc", "ipc.sock"))
      {% end %}
    end
  end
end
