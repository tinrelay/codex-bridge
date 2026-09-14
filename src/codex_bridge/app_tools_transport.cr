module CodexBridge
  private module AppToolsTransport
    def self.accepts_node_path?(path : String) : Bool
      {% if flag?(:darwin) %}
        AppToolsNodeTransport.available?(path)
      {% else %}
        File.exists?(path)
      {% end %}
    end

    def self.discover(node : String, candidates : Array(String)) : String?
      {% if flag?(:darwin) %}
        AppToolsNodeTransport.discover(node, candidates)
      {% else %}
        AppToolsNative.discover(candidates)
      {% end %}
    end

    def self.send_message(
      node : String,
      socket_file : String,
      source_task_id : String,
      target_task_id : String,
      prompt : String,
    )
      {% if flag?(:darwin) %}
        AppToolsNodeTransport.send_message(
          node,
          socket_file,
          source_task_id,
          target_task_id,
          prompt
        )
      {% else %}
        AppToolsNative.send_message(socket_file, source_task_id, target_task_id, prompt)
      {% end %}
    end
  end

  private module AppToolsNative
    MAX_FRAME         = 8 * 1024 * 1024
    DISCOVERY_TIMEOUT = 250.milliseconds
    SEND_TIMEOUT      = 20.seconds

    def self.discover(candidates : Enumerable(String)) : String?
      candidates.each do |path|
        begin
          result = request(
            path,
            "tools/list",
            {threadStartKind: "all"},
            DISCOVERY_TIMEOUT
          )
          tools = result["tools"].as_a
          if tools.any? do |tool|
               tool["name"]?.try(&.as_s?) == "send_message_to_thread" &&
               tool["namespace"]?.try(&.as_s?) == "codex_app"
             end
            return path
          end
        rescue AppToolsRejected | AppToolsReceiptUnknown
          next
        end
      end
      nil
    end

    def self.send_message(
      path : String,
      source_task_id : String,
      target_task_id : String,
      prompt : String,
    )
      call_id = "codex-bridge-#{UUID.random}"
      result = request(
        path,
        "tools/call",
        {
          arguments: {
            threadId: target_task_id,
            hostId:   "local",
            prompt:   prompt,
          },
          callId:    call_id,
          namespace: "codex_app",
          threadId:  source_task_id,
          tool:      "send_message_to_thread",
          turnId:    call_id,
        },
        SEND_TIMEOUT,
        mutating: true
      )
      raise AppToolsRejected.new("message rejected") if result["success"]?.try(&.as_bool?) == false

      begin
        unless result["success"]?.try(&.as_bool?) == true
          raise AppToolsReceiptUnknown.new("invalid message result")
        end
        item = result["contentItems"].as_a.find do |content|
          content["type"]?.try(&.as_s?) == "inputText"
        end
        unless item
          raise AppToolsReceiptUnknown.new("invalid message result")
        end
        returned = JSON.parse(item["text"].as_s)["threadId"].as_s
        unless returned == target_task_id
          raise AppToolsReceiptUnknown.new("message target mismatch")
        end
      rescue ex : JSON::ParseException | KeyError | TypeCastError
        raise AppToolsReceiptUnknown.new(ex.message || "invalid message result")
      end
    end

    private def self.request(path, method, params, timeout, *, mutating = false) : JSON::Any
      payload = {id: 1, jsonrpc: "2.0", method: method, params: params}.to_json.to_slice
      raise AppToolsRejected.new("request too large") if payload.size > MAX_FRAME

      submitted = false
      open_endpoint(path, timeout) do |io|
        header = Bytes.new(4)
        IO::ByteFormat::LittleEndian.encode(payload.size.to_u32, header)
        submitted = mutating
        io.write(header)
        io.write(payload)
        io.flush

        io.read_fully(header)
        size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
        raise IO::Error.new("invalid frame") if size > MAX_FRAME
        body = Bytes.new(size.to_i)
        io.read_fully(body)
        response = JSON.parse(String.new(body))
        if error = response["error"]?
          message = error["message"]?.try(&.as_s?) || "JSON-RPC error"
          raise AppToolsRejected.new(message)
        end
        response["result"]
      end
    rescue ex : AppToolsRejected | AppToolsReceiptUnknown
      raise ex
    rescue ex : IO::Error | JSON::ParseException | KeyError | TypeCastError | OverflowError
      message = case ex
                when IO::EOFError
                  "connection closed"
                when JSON::ParseException, KeyError, TypeCastError, OverflowError
                  "invalid_app_tools_response"
                else
                  ex.message || "app tools IO failed"
                end
      if mutating && submitted
        raise AppToolsReceiptUnknown.new(message)
      end
      raise AppToolsRejected.new(message)
    end

    private def self.open_endpoint(path, timeout, &)
      {% if flag?(:win32) %}
        OverlappedPipe.open(path) do |io|
          io.read_timeout = timeout
          io.write_timeout = timeout
          yield io
        end
      {% else %}
        socket = UNIXSocket.new(path)
        begin
          socket.read_timeout = timeout
          socket.write_timeout = timeout
          yield socket
        ensure
          socket.close
        end
      {% end %}
    end

    {% if flag?(:win32) %}
      private class OverlappedPipe < File
        def self.open(path, &)
          open_internal(path, "r+", blocking: false) { |io| yield io }
        end
      end
    {% end %}
  end
end
