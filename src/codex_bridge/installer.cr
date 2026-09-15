module CodexBridge
  def self.install(
    codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s,
    *,
    state_home : String? = nil,
    codex_path : String? = nil,
    node_path : String? = nil,
    codex_resources : String? = nil,
  ) : Symbol
    {% if flag?(:darwin) %}
      Installer.install(
        codex_home,
        state_home: state_home,
        codex_path: codex_path,
        node_path: node_path,
        codex_resources: codex_resources
      )
    {% else %}
      :ready
    {% end %}
  end

  {% if flag?(:darwin) %}
    private module Installer
      MCP_NAME   = "codex_bridge_relay"
      RELAY_NAME = "relay.mjs"
      RELAY      = {{ read_file("#{__DIR__}/macos_relay/relay.mjs") }}
      RELAY_ID   = Digest::SHA256.hexdigest(RELAY)

      def self.install(
        codex_home,
        *,
        state_home,
        codex_path,
        node_path,
        codex_resources,
      ) : Symbol
        state_home ||= File.join(codex_home, "codex-bridge")
        relay_path = File.join(state_home, RELAY_NAME)
        Dir.mkdir_p(state_home, mode: 0o700)
        File.chmod(state_home, 0o700)
        current = File.exists?(relay_path) && File.read(relay_path) == RELAY
        write_relay(relay_path) unless current

        codex, node = resolve_runtimes(codex_path, node_path, codex_resources)
        output = IO::Memory.new
        errors = IO::Memory.new
        result = Process.run(
          codex,
          [
            "mcp",
            "add",
            MCP_NAME,
            "--env",
            "CODEX_BRIDGE_STATE_HOME=#{state_home}",
            "--",
            node,
            relay_path,
            RELAY_ID,
          ],
          env: {"CODEX_HOME" => codex_home},
          output: output,
          error: errors
        )
        unless result.success?
          detail = errors.to_s.strip
          detail = output.to_s.strip if detail.empty?
          raise InstallError.new(detail.empty? ? "mcp_install_failed" : detail)
        end
        if AppToolsNative.relay_generation?(
             PlatformDiscovery.relay_socket_candidates(state_home),
             RELAY_ID
           )
          :ready
        else
          :codex_restart_required
        end
      rescue ex : File::NotFoundError
        raise InstallError.new("codex_not_found")
      rescue ex : IO::Error
        raise InstallError.new(ex.message || "install_io_failed")
      end

      private def self.resolve_runtimes(codex_path, node_path, codex_resources)
        resources = codex_resources
        resources ||= File.dirname(codex_path) if codex_path
        resources ||= PlatformDiscovery.resource_candidates.find do |candidate|
          File::Info.executable?(File.join(candidate, "codex"))
        end
        codex_path ||= File.join(resources, "codex") if resources
        node_path ||= File.join(resources, "cua_node", "bin", "node") if resources
        unless codex_path && File::Info.executable?(codex_path)
          raise InstallError.new("codex_not_found")
        end
        unless node_path && File::Info.executable?(node_path)
          raise InstallError.new("codex_node_not_found")
        end
        {codex_path, node_path}
      end

      private def self.write_relay(path)
        temporary = "#{path}.tmp-#{Process.pid}-#{Random::Secure.hex(4)}"
        File.write(temporary, RELAY)
        File.chmod(temporary, 0o600)
        File.rename(temporary, path)
      ensure
        File.delete(temporary) if temporary && File.exists?(temporary)
      end
    end
  {% end %}
end
