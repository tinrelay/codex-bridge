require "c/errhandlingapi"
require "c/fileapi"
require "c/handleapi"
require "c/winbase"

lib LibC
  PIPE_ACCESS_DUPLEX = 0x00000003_u32
  PIPE_TYPE_BYTE     = 0x00000000_u32
  PIPE_READMODE_BYTE = 0x00000000_u32
  PIPE_WAIT          = 0x00000000_u32

  fun CreateNamedPipeW(
    name : LPWSTR,
    open_mode : DWORD,
    pipe_mode : DWORD,
    maximum_instances : DWORD,
    output_buffer_size : DWORD,
    input_buffer_size : DWORD,
    default_timeout : DWORD,
    security_attributes : SECURITY_ATTRIBUTES*,
  ) : HANDLE
  fun ConnectNamedPipe(pipe : HANDLE, overlapped : OVERLAPPED*) : BOOL
  fun DisconnectNamedPipe(pipe : HANDLE) : BOOL
end

module CodexBridgeSpec
  class WindowsAppToolsServer
    BUFFER_SIZE          = 8 * 1024
    ERROR_PIPE_CONNECTED = 535_u32

    getter path : String

    @closed = Atomic(Bool).new(false)
    @lock = Thread::Mutex.new
    @requests = [] of JSON::Any
    @result = "success"

    def initialize(name : String)
      @path = "\\\\.\\pipe\\#{name}"
      ready = Channel(Exception?).new
      @thread = Thread.new { serve(ready) }
      if error = ready.receive
        raise error
      end
    end

    def close : Nil
      return if @closed.swap(true)
      begin
        File.open(path, "r+") { }
      rescue File::Error | IO::Error
      end
      @thread.join
    end

    def requests : Array(JSON::Any)
      @lock.synchronize { @requests.dup }
    end

    def result=(value : String) : Nil
      @lock.synchronize { @result = value }
    end

    private def serve(ready) : Nil
      first = true
      loop do
        pipe = create_pipe
        if first
          ready.send(nil)
          first = false
        end

        connected = LibC.ConnectNamedPipe(pipe, nil) != 0
        connected ||= LibC.GetLastError == ERROR_PIPE_CONNECTED
        if connected && !@closed.get
          handle(pipe)
          LibC.DisconnectNamedPipe(pipe)
        end
        LibC.CloseHandle(pipe)
        break if @closed.get
      end
    rescue error
      if first
        ready.send(error)
      else
        STDERR.puts(error.inspect_with_backtrace)
      end
    end

    private def create_pipe : LibC::HANDLE
      pipe = LibC.CreateNamedPipeW(
        path.to_utf16.to_unsafe,
        LibC::PIPE_ACCESS_DUPLEX,
        LibC::PIPE_TYPE_BYTE | LibC::PIPE_READMODE_BYTE | LibC::PIPE_WAIT,
        1,
        BUFFER_SIZE,
        BUFFER_SIZE,
        0,
        nil
      )
      if pipe == LibC::INVALID_HANDLE_VALUE
        raise IO::Error.from_winerror("CreateNamedPipeW")
      end
      pipe
    end

    private def handle(pipe) : Nil
      payload = read_frame(pipe)
      return unless payload
      request = JSON.parse(payload)
      if request["method"].as_s == "tools/list"
        record(operation: "discover", candidates: [path])
        write_frame(pipe, {
          id:      1,
          jsonrpc: "2.0",
          result:  {
            tools: [{name: "send_message_to_thread", namespace: "codex_app"}],
          },
        }.to_json)
        return
      end

      params = request["params"]
      arguments = params["arguments"]
      target = arguments["threadId"].as_s
      record(
        operation: "send",
        candidates: [path],
        sourceTaskId: params["threadId"].as_s,
        targetTaskId: target,
        prompt: arguments["prompt"].as_s
      )

      result = @lock.synchronize { @result }
      case result
      when "unknown"
        return
      when "malformed"
        write_frame(pipe, "not json")
      when "rejected"
        write_frame(pipe, {
          id:      1,
          jsonrpc: "2.0",
          error:   {message: "native rejection"},
        }.to_json)
      else
        receipt = {threadId: target}.to_json
        write_frame(pipe, {
          id:      1,
          jsonrpc: "2.0",
          result:  {
            success:      true,
            contentItems: [{type: "inputText", text: receipt}],
          },
        }.to_json)
      end
    end

    private def read_frame(pipe) : String?
      header = Bytes.new(4)
      return unless read_exactly(pipe, header)
      size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
      payload = Bytes.new(size.to_i)
      return unless read_exactly(pipe, payload)
      String.new(payload)
    end

    private def write_frame(pipe, payload : String) : Nil
      body = payload.to_slice
      header = Bytes.new(4)
      IO::ByteFormat::LittleEndian.encode(body.size.to_u32, header)
      write_all(pipe, header)
      write_all(pipe, body)
      LibC.FlushFileBuffers(pipe)
    end

    private def read_exactly(pipe, buffer : Bytes) : Bool
      offset = 0
      while offset < buffer.size
        count = uninitialized LibC::DWORD
        success = LibC.ReadFile(
          pipe,
          buffer.to_unsafe + offset,
          (buffer.size - offset).to_u32,
          pointerof(count),
          nil
        )
        return false if success == 0 || count == 0
        offset += count
      end
      true
    end

    private def write_all(pipe, buffer : Bytes) : Nil
      offset = 0
      while offset < buffer.size
        count = uninitialized LibC::DWORD
        success = LibC.WriteFile(
          pipe,
          buffer.to_unsafe + offset,
          (buffer.size - offset).to_u32,
          pointerof(count),
          nil
        )
        raise IO::Error.from_winerror("WriteFile") if success == 0 || count == 0
        offset += count
      end
    end

    private def record(**values) : Nil
      entry = JSON.parse(values.to_json)
      @lock.synchronize { @requests << entry }
    end
  end
end
