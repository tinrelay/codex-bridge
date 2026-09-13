module CodexBridge
  enum DeliveryMode
    Steer
    Queue
  end

  record UntrustedAttachment, id : String, title : String, text : String do
    def initialize(@id, @title, @text)
      raise ArgumentError.new("attachment id is required") if id.empty?
      raise ArgumentError.new("attachment title is required") if title.empty?
    end
  end

  class Delivery
    getter task_id : String
    getter instruction : String
    getter attachments : Array(UntrustedAttachment)
    getter logical_message_id : String
    getter mode : DeliveryMode

    def initialize(
      @task_id,
      @instruction,
      @attachments,
      @logical_message_id,
      @mode,
    )
      unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(task_id)
        raise ArgumentError.new("invalid local task id")
      end
      raise ArgumentError.new("instruction is required") if instruction.empty?
      if logical_message_id.empty? || logical_message_id.bytesize > 160
        raise ArgumentError.new("invalid logical message id")
      end
    end
  end

  record Accepted, turn_id : String
  record Retryable, reason : String
  record Ambiguous, reason : String
  record Incompatible, reason : String

  struct Ready
  end

  enum TerminalStatus
    Completed
    Failed
    Interrupted
  end

  record Terminal, turn_id : String, status : TerminalStatus

  alias DeliveryResult = Accepted | Retryable | Ambiguous | Incompatible
  alias ReadinessResult = Ready | Retryable | Incompatible
  alias ObservationResult = Terminal | Retryable | Incompatible

  class Control
    getter stopped = false

    def stop
      @stopped = true
    end

    def check
      raise Stopped.new if stopped
    end
  end

  class Stopped < Exception; end

  private class Disconnected < Exception; end

  private class SubmissionInterrupted < Exception; end

  private class Deadline < Disconnected; end

  private class RetryableFailure < Exception; end

  private class IncompatibleFailure < Exception; end

  private class Busy < Exception; end

  private class StaleTurn < Exception; end
end
