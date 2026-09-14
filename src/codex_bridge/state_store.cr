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

    private def open(&)
      Dir.mkdir_p(@state_home, mode: 0o700)
      path = File.join(@state_home, "state.db")
      DB.open("sqlite3://#{URI.encode_path(path)}?busy_timeout=1000") do |database|
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
