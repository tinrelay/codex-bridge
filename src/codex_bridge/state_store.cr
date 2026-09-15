module CodexBridge
  private class StateStore
    def initialize(@state_home : String)
    end

    def get(key : String) : String?
      open do |database|
        database.query_one?("SELECT value FROM kv WHERE key = ?", key, as: String)
      end
    rescue DB::Error
      nil
    end

    def put(key : String, value : String) : Bool
      open do |database|
        database.exec(
          <<-SQL,
            INSERT INTO kv (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
          SQL
          key,
          value
        )
      end
      true
    rescue DB::Error
      false
    end

    def with_send_lock(timeout : Time::Span, &)
      open(timeout) do |database|
        database.exec("BEGIN IMMEDIATE")
        begin
          value = yield
          database.exec("COMMIT")
          value
        rescue ex
          begin
            database.exec("ROLLBACK")
          rescue DB::Error
          end
          raise ex
        end
      end
    end

    private def open(timeout = 1.second, &)
      Dir.mkdir_p(@state_home, mode: 0o700)
      path = File.join(@state_home, "state.db")
      milliseconds = timeout.total_milliseconds.clamp(0, Int32::MAX).to_i
      DB.open("sqlite3://#{URI.encode_path(path)}?busy_timeout=#{milliseconds}") do |database|
        {% unless flag?(:win32) %}
          File.chmod(path, 0o600)
        {% end %}
        database.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS kv (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        SQL
        yield database
      end
    end
  end
end
