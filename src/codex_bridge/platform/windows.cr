require "c/fileapi"
require "c/handleapi"

module CodexBridge
  private module Platform
    PIPE_ROOT   = %q(\\.\pipe\)
    PIPE_PREFIX = "codex-browser-use-"

    def self.resource_candidates : Array(String)
      [] of String
    end

    def self.relay_socket_candidates(_state_home : String) : Array(String)
      [] of String
    end

    def self.socket_candidates : Array(String)
      candidates = [] of String
      query = "#{PIPE_ROOT}#{PIPE_PREFIX}*"
      handle = LibC.FindFirstFileW(query.to_utf16.to_unsafe, out data)
      return candidates if handle == LibC::INVALID_HANDLE_VALUE

      begin
        loop do
          name = String.from_utf16(data.cFileName.to_slice, truncate_at_null: true)
          candidates << "#{PIPE_ROOT}#{name}" if name.starts_with?(PIPE_PREFIX)
          break if LibC.FindNextFileW(handle, pointerof(data)) == 0
        end
      ensure
        LibC.FindClose(handle)
      end
      candidates.uniq.sort
    end

    def self.open_endpoint(path : String, timeout : Time::Span, &)
      OverlappedPipe.open(path) do |io|
        io.read_timeout = timeout
        io.write_timeout = timeout
        yield io
      end
    end

    def self.node_name : String
      "node.exe"
    end

    def self.restrict_private_file(_path : String) : Nil
    end

    private class OverlappedPipe < File
      def self.open(path, &)
        open_internal(path, "r+", blocking: false) { |io| yield io }
      end
    end
  end
end
