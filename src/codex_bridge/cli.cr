require "option_parser"

module CodexBridge
  module CLI
    HELP = <<-TEXT
      Usage: codex-bridge [options] TASK_ID < message.txt
             codex-bridge --install [options]
             codex-bridge --discover [options]
             codex-bridge --variable NAME [options]

      Send stdin to an exact local Codex Desktop task without changing the visible task.

          --from-task TASK_ID  Attribute the message to another real task
          --codex-home PATH    Codex data directory (default: $CODEX_HOME or ~/.codex)
          --state-home PATH    codex-bridge state directory
          --codex-path PATH    Stock Codex executable (installation only)
          --socket-file PATH   Use this exact app-tools socket
          --node-path PATH     Bundled Codex Node path (install/diagnostics)
          --codex-resources PATH
                               Codex resources directory containing cua_node
          --timeout SECONDS    Maximum time for delivery work (default: 60)
          --uncached           Do not read or write the socket cache
          --install            Install the stock-macOS relay MCP
          --discover           Print the resolved connection as JSON
          --variable NAME      Print socket_file, node_path, or codex_resources
          --version            Print the version
          -h, --help           Show this help
      TEXT

    def self.run(
      argv : Array(String),
      input : IO = STDIN,
      output : IO = STDOUT,
      error : IO = STDERR,
      client : Client? = nil,
    ) : Int32
      show_help = false
      show_version = false
      discover = false
      install = false
      variable = nil.as(String?)
      source_task_id = nil.as(String?)
      codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s
      state_home = nil.as(String?)
      codex_path = nil.as(String?)
      socket_file = nil.as(String?)
      node_path = nil.as(String?)
      codex_resources = nil.as(String?)
      timeout = Client::DEFAULT_TIMEOUT
      cache = true
      parser = OptionParser.new do |options|
        options.on("--from-task TASK_ID", "Attribute the message to another task") do |task_id|
          source_task_id = task_id
        end
        options.on("--codex-home PATH", "Codex data directory") { |path| codex_home = path }
        options.on("--state-home PATH", "codex-bridge state directory") do |path|
          state_home = path
        end
        options.on("--codex-path PATH", "Stock Codex executable") { |path| codex_path = path }
        options.on("--socket-file PATH", "Exact app-tools socket") { |path| socket_file = path }
        options.on("--node-path PATH", "Bundled Codex Node path") do |path|
          node_path = path
        end
        options.on("--codex-resources PATH", "Codex resources directory") do |path|
          codex_resources = path
        end
        options.on("--timeout SECONDS", "Maximum time for delivery work") do |value|
          timeout = parse_timeout(value)
        end
        options.on("--uncached", "Do not read or write the socket cache") { cache = false }
        options.on("--install", "Install the stock-macOS relay MCP") { install = true }
        options.on("--discover", "Print the resolved connection as JSON") { discover = true }
        options.on("--variable NAME", "Print one resolved connection value") { |name| variable = name }
        options.on("--version", "Print the version") { show_version = true }
        options.on("-h", "--help", "Show this help") { show_help = true }
        options.invalid_option { |flag| raise ArgumentError.new("invalid option: #{flag}") }
        options.missing_option do |flag|
          raise ArgumentError.new("missing value for option: #{flag}")
        end
      end
      parser.parse(argv)
      if show_help
        output.puts HELP
        return 0
      end
      if show_version
        output.puts "codex-bridge #{VERSION}"
        return 0
      end
      if install
        raise ArgumentError.new("installation does not accept a task ID") unless argv.empty?
        raise ArgumentError.new("choose --install or discovery") if discover || variable
        result = CodexBridge.install(
          codex_home,
          state_home: state_home,
          codex_path: codex_path,
          node_path: node_path,
          codex_resources: codex_resources
        )
        output.puts result
        return 0
      end
      if discover || variable
        raise ArgumentError.new("discovery does not accept a task ID") unless argv.empty?
        raise ArgumentError.new("choose --discover or --variable") if discover && variable
        if name = variable
          unless {"socket_file", "node_path", "codex_resources"}.includes?(name)
            raise ArgumentError.new("unknown variable: #{name}")
          end
        end
        connection = CodexBridge.discover(
          codex_home,
          state_home: state_home,
          socket_file: socket_file,
          node_path: node_path,
          codex_resources: codex_resources,
          cache: cache
        )
        raise TaskUnavailable.new("app_tools_unavailable") unless connection
        if name = variable
          value = case name
                  when "socket_file"     then connection.socket_file
                  when "node_path"       then connection.node_path || ""
                  when "codex_resources" then connection.codex_resources || ""
                  else                        raise "unreachable"
                  end
          output.puts value
        else
          output.puts({
            socket_file:     connection.socket_file,
            node_path:       connection.node_path,
            codex_resources: connection.codex_resources,
          }.to_json)
        end
        return 0
      end
      raise ArgumentError.new("one task ID is required") unless argv.size == 1
      if codex_path || node_path || codex_resources
        raise ArgumentError.new(
          "--codex-path, --node-path, and --codex-resources are only valid for installation or diagnostics"
        )
      end

      body = input.gets_to_end
      bridge = client || Client.new(
        codex_home,
        state_home: state_home,
        socket_file: socket_file,
        cache: cache,
        timeout: timeout
      )
      bridge.send_message(argv.first, body, from: source_task_id)
      output.puts "sent #{argv.first}"
      0
    rescue ex : ArgumentError
      error.puts "codex-bridge: #{ex.message}"
      2
    rescue ex : NotReceived
      error.puts "codex-bridge: not received: #{ex.reason}"
      3
    rescue ex : ReceiptUnknown
      error.puts "codex-bridge: receipt unknown: #{ex.reason}"
      4
    rescue ex : InstallError
      error.puts "codex-bridge: install failed: #{ex.reason}"
      5
    end

    private def self.parse_timeout(value : String) : Time::Span
      seconds = value.to_f64?
      unless seconds && seconds.finite? && seconds >= 0
        raise ArgumentError.new("timeout must be a non-negative number")
      end
      seconds.seconds
    end
  end
end
