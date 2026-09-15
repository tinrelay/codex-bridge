module CodexBridge
  private module Platform
    def self.resource_candidates : Array(String)
      ["/Applications/ChatGPT.app/Contents/Resources"]
    end

    def self.relay_socket_candidates(state_home : String) : Array(String)
      Dir.glob(File.join(state_home, "#{RELAY_SOCKET_PREFIX}*.sock")).sort
    end

    def self.socket_candidates : Array(String)
      [] of String
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
