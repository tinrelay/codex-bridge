module CodexBridge
  private module PlatformDiscovery
    UNIX_SOCKET_ROOT    = "/tmp"
    WINDOWS_PIPE_PREFIX = %q(\\.\pipe\codex-browser-use-)

    POWERSHELL_APPX =
      "(Get-AppxPackage -Name 'OpenAI.Codex' | Sort-Object Version -Descending | " \
      "Select-Object -First 1).InstallLocation"
    POWERSHELL_PIPES = [
      %q([IO.Directory]::GetFiles('\\.\pipe\')),
      "| Where-Object {",
      %q($_.StartsWith('\\.\pipe\codex-browser-use-', [StringComparison]::Ordinal)),
      "} | Sort-Object",
    ].join(" ")

    def self.resource_candidates : Array(String)
      {% if flag?(:darwin) %}
        ["/Applications/ChatGPT.app/Contents/Resources"]
      {% elsif flag?(:linux) %}
        linux_resource_candidates
      {% elsif flag?(:win32) %}
        windows_resource_candidates
      {% else %}
        [] of String
      {% end %}
    end

    def self.socket_candidates : Array(String)
      {% if flag?(:win32) %}
        windows_socket_candidates
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

    def self.windows_resource_candidates(powershell = "powershell.exe") : Array(String)
      windows_resources(powershell_lines(powershell, POWERSHELL_APPX))
    end

    def self.windows_socket_candidates(powershell = "powershell.exe") : Array(String)
      windows_pipes(powershell_lines(powershell, POWERSHELL_PIPES))
    end

    def self.windows_resources(lines : Enumerable(String)) : Array(String)
      location = lines.find { |line| windows_absolute_path?(line) }
      return [] of String unless location
      [location.rstrip("\\/") + "\\app\\resources"]
    end

    def self.windows_pipes(lines : Enumerable(String)) : Array(String)
      lines.select(&.starts_with?(WINDOWS_PIPE_PREFIX)).uniq.sort
    end

    private def self.powershell_lines(executable, script) : Array(String)
      output = IO::Memory.new
      errors = IO::Memory.new
      result = Process.run(
        executable,
        ["-NoProfile", "-NonInteractive", "-Command", script],
        output: output,
        error: errors
      )
      return [] of String unless result.success?
      output.to_s.lines(chomp: true).map(&.strip).reject(&.empty?)
    rescue File::NotFoundError | IO::Error
      [] of String
    end

    private def self.windows_absolute_path?(path)
      path.matches?(/\A[A-Za-z]:[\\\/]/)
    end
  end
end
