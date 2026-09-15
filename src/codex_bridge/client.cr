module CodexBridge
  class Client
    DEFAULT_TIMEOUT           = 60.seconds
    DISCOVERY_INITIAL_BACKOFF = 100.milliseconds
    DISCOVERY_MAX_BACKOFF     = 5.seconds

    getter codex_home : String
    getter state_home : String

    def initialize(
      @codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s,
      state_home : String? = nil,
      @socket_file : String? = nil,
      @cache = true,
      @timeout : Time::Span = DEFAULT_TIMEOUT,
    )
      raise ArgumentError.new("timeout cannot be negative") if @timeout < 0.seconds
      @state_home = state_home || File.join(@codex_home, "codex-bridge")
    end

    def send_message(task_id : String, message : String, from source_task_id : String? = nil)
      validate_task_id(task_id)
      source_task_id ||= task_id
      validate_task_id(source_task_id)
      raise ArgumentError.new("message is required") if message.empty?

      deadline = Time.instant + @timeout
      endpoint = wait_for_endpoint(deadline)
      raise TaskUnavailable.new("app_tools_unavailable") unless endpoint

      remaining = deadline - Time.instant
      raise TaskUnavailable.new("timeout") if remaining <= 0.seconds
      StateStore.new(state_home).with_send_lock(remaining) do
        history = ThreadHistory.new(codex_home)
        baseline = history.latest_ordinal(task_id)
        remaining = deadline - Time.instant
        raise TaskUnavailable.new("timeout") if remaining <= 0.seconds
        begin
          endpoint.send_message(source_task_id, task_id, message, remaining)
        rescue ex : AppToolsReceiptUnknown
          confirmed = baseline && history.wait_for_delivery(
            task_id,
            source_task_id,
            message,
            after: baseline,
            until: deadline
          )
          raise ex unless confirmed
        end
      end
    rescue ex : AppToolsRejected
      raise MessageRejected.new(ex.message || "app_tools_rejected")
    rescue ex : AppToolsReceiptUnknown
      raise ReceiptUnknown.new(ex.message || "receipt_unknown")
    rescue DB::Error
      raise TaskUnavailable.new("codex_bridge_busy")
    end

    private def validate_task_id(task_id)
      unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(task_id)
        raise ArgumentError.new("invalid local task id")
      end
    end

    private def wait_for_endpoint(deadline)
      backoff = DISCOVERY_INITIAL_BACKOFF
      loop do
        return if Time.instant >= deadline
        endpoint = AppToolsEndpoint.discover_delivery(
          state_home,
          socket_file: @socket_file,
          cache: @cache,
          deadline: deadline
        )
        return endpoint if endpoint

        remaining = deadline - Time.instant
        return if remaining <= 0.seconds
        sleep(backoff < remaining ? backoff : remaining)
        backoff = backoff * 2
        backoff = DISCOVERY_MAX_BACKOFF if backoff > DISCOVERY_MAX_BACKOFF
      end
    end
  end
end
