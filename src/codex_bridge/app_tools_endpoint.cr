module CodexBridge
  private class AppToolsEndpoint
    CACHE_KEY = "app_tools_pipe"

    getter connection : Connection

    def self.discover(
      state_home : String,
      candidates : Enumerable(String)? = nil,
      *,
      socket_file : String? = nil,
      node_path : String? = nil,
      codex_resources : String? = nil,
      cache = true,
    ) : self?
      node, resources = bundled_node(node_path, codex_resources)

      state = StateStore.new(state_home)
      paths = [] of String
      if socket_file
        paths << socket_file
      else
        paths.concat(PlatformDiscovery.relay_socket_candidates(state_home))
        if cache && (cached = state.get(CACHE_KEY))
          paths << cached
        end
      end
      unless socket_file
        if configured = ENV["CODEX_APP_TOOLS_PIPE_PATH"]?
          paths << configured
        end
        if candidates
          paths.concat(candidates)
        else
          paths.concat(default_candidates)
        end
      end

      path = AppToolsTransport.discover(paths.uniq)
      return unless path
      state.put(CACHE_KEY, path) if cache
      new(Connection.new(path, node, resources))
    end

    def initialize(@connection)
    end

    def send_message(source_task_id : String, target_task_id : String, prompt : String)
      AppToolsTransport.send_message(connection.socket_file, source_task_id, target_task_id, prompt)
    end

    private def self.bundled_node(explicit_node, explicit_resources)
      return {explicit_node, resources_for(explicit_node, explicit_resources)} if explicit_node
      if explicit_resources
        node = File.join(explicit_resources, "cua_node", "bin", node_name)
        return {node, explicit_resources} if File.exists?(node)
        return {nil, explicit_resources}
      end

      paths = [] of Tuple(String, String?)
      if configured = ENV["CODEX_MCP_NODE_PATH"]?
        paths << {configured, resources_for(configured, nil)}
      end
      if configured = ENV["CODEX_BROWSER_USE_NODE_PATH"]?
        paths << {configured, resources_for(configured, nil)}
      end
      if resources = ENV["CODEX_ELECTRON_RESOURCES_PATH"]?
        paths << {File.join(resources, "cua_node", "bin", node_name), resources}
      end
      PlatformDiscovery.resource_candidates.each do |resources|
        paths << {File.join(resources, "cua_node", "bin", node_name), resources}
      end
      paths.find { |path, _| File.exists?(path) } || {nil, nil}
    end

    private def self.resources_for(node_path, configured_resources)
      return configured_resources if configured_resources
      suffix = File.join("cua_node", "bin", node_name)
      return unless node_path.ends_with?(suffix)
      node_path[0, node_path.bytesize - suffix.bytesize].rstrip(File::SEPARATOR)
    end

    private def self.node_name
      {% if flag?(:win32) %}
        "node.exe"
      {% else %}
        "node"
      {% end %}
    end

    private def self.default_candidates
      PlatformDiscovery.socket_candidates
    end
  end
end
