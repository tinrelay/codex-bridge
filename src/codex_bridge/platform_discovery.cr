module CodexBridge
  private module PlatformDiscovery
    UNIX_SOCKET_ROOT = "/tmp"

    def self.resource_candidates : Array(String)
      {% if flag?(:darwin) %}
        ["/Applications/ChatGPT.app/Contents/Resources"]
      {% elsif flag?(:linux) %}
        linux_resource_candidates
      {% else %}
        [] of String
      {% end %}
    end

    def self.socket_candidates : Array(String)
      {% if flag?(:win32) %}
        [] of String
      {% else %}
        unix_socket_candidates
      {% end %}
    end

    def self.linux_resource_candidates(install_root = "/usr/lib/chatgpt") : Array(String)
      [File.join(install_root, "resources")]
    end

    def self.unix_socket_candidates(temporary_root = UNIX_SOCKET_ROOT) : Array(String)
      Dir.glob(File.join(temporary_root, "codex-browser-use", "*.sock")).sort
    end
  end
end
