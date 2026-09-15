module CodexBridge
  private class ThreadHistory
    POLL_INTERVAL = 50.milliseconds

    def initialize(@codex_home : String)
      @path = File.join(@codex_home, "thread_history_1.sqlite")
    end

    def latest_ordinal(task_id : String) : Int64?
      query do |database|
        database.query_one(
          "SELECT COALESCE(MAX(rollout_ordinal), -1) FROM thread_items WHERE thread_id = ?",
          task_id,
          as: Int64
        )
      end
    end

    def wait_for_delivery(
      task_id : String,
      source_task_id : String,
      message : String,
      after ordinal : Int64,
      until deadline : Time::Instant,
    ) : Bool
      expected = wrapper(source_task_id, message)
      loop do
        return true if delivered?(task_id, ordinal, expected)
        remaining = deadline - Time.instant
        return false if remaining <= 0.seconds
        sleep(POLL_INTERVAL < remaining ? POLL_INTERVAL : remaining)
      end
    end

    private def delivered?(task_id, ordinal, expected)
      query do |database|
        database.query_each(
          <<-SQL,
            SELECT item_json
            FROM thread_items
            WHERE thread_id = ?
              AND rollout_ordinal > ?
              AND item_type = 'functionCallOutput'
            ORDER BY rollout_ordinal
          SQL
          task_id,
          ordinal
        ) do |result|
          item = JSON.parse(result.read(String))
          return true if item["name"]?.try(&.as_s?) == "send_message_to_thread" &&
                         item["namespace"]?.try(&.as_s?) == "codex_app" &&
                         item["output"]?.try(&.as_s?) == expected
        end
        false
      end || false
    end

    private def query(&)
      return unless File.file?(@path)
      DB.open("sqlite3://#{URI.encode_path(@path)}?busy_timeout=100") do |database|
        yield database
      end
    rescue DB::Error | JSON::ParseException | KeyError | TypeCastError
      nil
    end

    private def wrapper(source_task_id, message)
      "<codex_delegation>\n" +
        "  <source_thread_id>#{source_task_id}</source_thread_id>\n" +
        "  <input>#{message}</input>\n" +
        "</codex_delegation>"
    end
  end
end
