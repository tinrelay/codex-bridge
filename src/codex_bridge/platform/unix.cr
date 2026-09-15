module CodexBridge
  private module Platform
    UNIX_SOCKET_ROOT = "/tmp"

    def self.resource_candidates : Array(String)
      ["/usr/lib/chatgpt/resources"]
    end

    def self.relay_socket_candidates(_state_home : String) : Array(String)
      [] of String
    end

    def self.socket_candidates(temporary_root = UNIX_SOCKET_ROOT) : Array(String)
      Dir.glob(File.join(temporary_root, "codex-browser-use", "*.sock"))
        .reject { |path| relay_socket?(path) }
        .sort
    end

    def self.relay_socket?(path : String) : Bool
      name = File.basename(path)
      name.starts_with?(RELAY_SOCKET_PREFIX) && name.ends_with?(".sock")
    end

    def self.open_endpoint(path : String, timeout : Time::Span, &)
      socket = UNIXSocket.new(path)
      begin
        socket.read_timeout = timeout
        socket.write_timeout = timeout
        yield socket
      ensure
        socket.close
      end
    end

    def self.node_name : String
      "node"
    end

    def self.restrict_private_file(path : String) : Nil
      File.chmod(path, 0o600)
    end
  end
end
