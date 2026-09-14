module CodexBridge
  class Client
    getter codex_home : String
    getter state_home : String

    def initialize(
      @codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s,
      state_home : String? = nil,
      @socket_file : String? = nil,
      @node_path : String? = nil,
      @codex_resources : String? = nil,
      @cache = true,
    )
      @state_home = state_home || File.join(@codex_home, "codex-bridge")
    end

    def send_message(task_id : String, message : String, from source_task_id : String? = nil)
      validate_task_id(task_id)
      source_task_id ||= task_id
      validate_task_id(source_task_id)
      raise ArgumentError.new("message is required") if message.empty?

      endpoint = AppToolsEndpoint.discover(
        state_home,
        socket_file: @socket_file,
        node_path: @node_path,
        codex_resources: @codex_resources,
        cache: @cache
      )
      raise TaskUnavailable.new("app_tools_unavailable") unless endpoint
      endpoint.send_message(source_task_id, task_id, message)
    rescue ex : AppToolsRejected
      raise MessageRejected.new(ex.message || "app_tools_rejected")
    rescue ex : AppToolsReceiptUnknown
      raise ReceiptUnknown.new(ex.message || "receipt_unknown")
    end

    private def validate_task_id(task_id)
      unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(task_id)
        raise ArgumentError.new("invalid local task id")
      end
    end
  end
end
