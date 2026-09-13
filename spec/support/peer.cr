module CodexBridgeSpec
  class Connection
    getter socket : UNIXSocket
    getter lock = Mutex.new

    def initialize(@socket)
    end
  end

  class Peer
    getter requests = [] of JSON::Any
    getter starts = [] of JSON::Any
    getter steers = [] of JSON::Any
    getter connections = [] of Connection
    getter errors = [] of Exception
    getter path : String
    property owner = "owner-1"
    property revision = 1_i64
    property state : JSON::Any
    property on_start : Proc(Connection, JSON::Any, Nil)? = nil
    property on_steer : Proc(Connection, JSON::Any, Nil)? = nil
    property on_history : Proc(Connection, JSON::Any, Nil)? = nil
    property on_subscribe : Proc(Connection, Nil)? = nil

    def initialize(root : String)
      @path = File.join(root, "ipc", "ipc.sock")
      Dir.mkdir_p(File.dirname(path))
      @listener = UNIXServer.new(path)
      @closed = false
      @state = JSON.parse({
        threadRuntimeStatus: {type: "idle"},
        turns:               [] of String,
        turnHistory:         {
          kind:    "canonical",
          history: {entitiesByKey: {} of String => String},
        },
      }.to_json)
      spawn { accept }
    end

    def runtime=(value : String)
      state["threadRuntimeStatus"].as_h["type"] = JSON::Any.new(value)
    end

    def runtime
      state["threadRuntimeStatus"]["type"].as_s
    end

    def add_turn(id : String, status = "inProgress")
      self.runtime = status == "inProgress" ? "active" : "idle"
      entities[id] = JSON.parse({
        turnId: id,
        status: status,
        items:  [] of String,
      }.to_json)
      self.revision += 1
      id
    end

    def add_user_message(turn_id : String, logical_id : String)
      items = entities[turn_id]["items"].as_a
      items << JSON.parse({
        type:     "userMessage",
        id:       "user-#{items.size + 1}",
        clientId: logical_id,
        content:  [{type: "text", text: "private and unprojected"}],
      }.to_json)
      self.revision += 1
    end

    def add_provisional_message(logical_id : String)
      entities["provisional"] = JSON.parse({
        status: "inProgress",
        items:  [{type: "userMessage", clientId: logical_id}],
      }.to_json)
      self.revision += 1
    end

    def finish(turn_id : String)
      entities[turn_id].as_h["status"] = JSON::Any.new("completed")
      self.runtime = "idle"
      self.revision += 1
      stream
    end

    def finish_while_another_turn_is_active(
      turn_id : String,
      active_id : String,
      status = "completed",
    )
      entities[turn_id].as_h["status"] = JSON::Any.new(status)
      add_turn(active_id)
      stream
    end

    def active_turn_id : String
      entities.each_value do |turn|
        return turn["turnId"].as_s if turn["status"].as_s == "inProgress"
      end
      raise "no active turn"
    end

    def reply(
      connection : Connection,
      request : JSON::Any,
      result = nil,
      error : String? = nil,
    )
      value = {
        "type"              => JSON::Any.new("response"),
        "requestId"         => JSON::Any.new(request["requestId"].as_s),
        "method"            => JSON::Any.new(request["method"].as_s),
        "handledByClientId" => JSON::Any.new(owner),
        "resultType"        => JSON::Any.new(error ? "error" : "success"),
        "result"            => JSON.parse(result.to_json),
      }
      value["error"] = JSON::Any.new(error) if error
      send(connection, value)
    end

    def stream(connection : Connection? = nil)
      selected = connection || connections.last
      send(selected, {
        type:           "broadcast",
        method:         "thread-stream-state-changed",
        version:        11,
        sourceClientId: owner,
        params:         {
          hostId:         "local",
          conversationId: TASK,
          change:         {
            type:              "snapshot",
            revision:          revision,
            conversationState: state,
          },
        },
      })
    end

    def accept_start(connection : Connection, request : JSON::Any)
      id = "turn-#{starts.size}"
      add_turn(id)
      logical_id = request["params"]["turnStart"]["request"]["clientUserMessageId"].as_s
      add_user_message(id, logical_id)
      stream(connection)
      reply(connection, request, {result: {turn: {id: id, status: "inProgress"}}})
      id
    end

    def accept_steer(connection : Connection, request : JSON::Any)
      id = active_turn_id
      add_user_message(id, request["params"]["clientUserMessageId"].as_s)
      stream(connection)
      reply(connection, request, {result: {turnId: id}})
      id
    end

    def disconnect(connection : Connection)
      connection.socket.close
    rescue IO::Error
    end

    def close
      @closed = true
      @listener.close
      connections.each { |connection| disconnect(connection) }
      File.delete(path) if File.exists?(path)
    end

    private def entities
      state["turnHistory"]["history"]["entitiesByKey"].as_h
    end

    private def send(connection : Connection, value)
      bytes = value.to_json.to_slice
      connection.lock.synchronize do
        connection.socket.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
        connection.socket.write(bytes)
        connection.socket.flush
      end
    end

    private def exact(io : IO, count : Int32)
      bytes = Bytes.new(count)
      offset = 0
      while offset < count
        read = io.read(bytes[offset..])
        raise IO::EOFError.new if read == 0
        offset += read
      end
      bytes
    end

    private def accept
      until @closed
        socket = @listener.accept?
        break unless socket
        connection = Connection.new(socket)
        connections << connection
        spawn { serve(connection) }
      end
    rescue ex : IO::Error
      errors << ex unless @closed
    end

    private def serve(connection)
      loop do
        size = IO::ByteFormat::LittleEndian.decode(UInt32, exact(connection.socket, 4))
        request = JSON.parse(String.new(exact(connection.socket, size.to_i)))
        requests << request
        case request["method"]?.try(&.as_s?)
        when "initialize"
          reply(connection, request, {clientId: "codex-bridge-spec-client"})
        when "thread-owner-discovery"
          reply(connection, request, {supportsUntrustedAppInput: true})
        when "thread-stream-following-changed"
          if request["params"]["following"].as_bool
            callback = on_subscribe
            callback ? callback.call(connection) : stream(connection)
          end
        when "thread-follower-load-complete-history"
          if callback = on_history
            callback.call(connection, request)
          else
            stream(connection)
            reply(connection, request, {revision: revision})
          end
        when "thread-follower-start-turn"
          starts << request
          if callback = on_start
            callback.call(connection, request)
          else
            accept_start(connection, request)
          end
        when "thread-follower-steer-turn"
          steers << request
          if callback = on_steer
            callback.call(connection, request)
          else
            accept_steer(connection, request)
          end
        end
      end
    rescue IO::EOFError | IO::Error
    rescue ex
      errors << ex
    end
  end
end
