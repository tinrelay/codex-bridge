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
      deadline : Time::Instant? = nil,
    ) : self?
      path = discover_path(
        state_home,
        candidates,
        socket_file: socket_file,
        cache: cache,
        deadline: deadline
      )
      return unless path
      node, resources = bundled_node(node_path, codex_resources)
      new(Connection.new(path, node, resources))
    end

    def self.discover_delivery(
      state_home : String,
      candidates : Enumerable(String)? = nil,
      *,
      socket_file : String? = nil,
      cache = true,
      deadline : Time::Instant? = nil,
    ) : self?
      path = discover_path(
        state_home,
        candidates,
        socket_file: socket_file,
        cache: cache,
        deadline: deadline
      )
      path ? new(Connection.new(path, nil, nil)) : nil
    end

    private def self.discover_path(
      state_home,
      candidates,
      *,
      socket_file,
      cache,
      deadline,
    ) : String?
      state = StateStore.new(state_home)
      checked = [] of String
      if socket_file
        path = probe([socket_file], checked, deadline)
        return remember(state, path, cache)
      end

      path = probe(Platform.relay_socket_candidates(state_home), checked, deadline)
      return remember(state, path, cache) if path
      if cache && (cached = state.get(CACHE_KEY))
        path = probe([cached], checked, deadline)
        return remember(state, path, cache) if path
      end
      if configured = ENV["CODEX_APP_TOOLS_PIPE_PATH"]?
        path = probe([configured], checked, deadline)
        return remember(state, path, cache) if path
      end

      path = probe(candidates || default_candidates, checked, deadline)
      remember(state, path, cache)
    end

    private def self.remember(state, path, cache)
      return unless path
      state.put(CACHE_KEY, path) if cache
      path
    end

    private def self.probe(paths, checked, deadline)
      fresh = paths.reject do |path|
        duplicate = checked.includes?(path)
        checked << path unless duplicate
        duplicate
      end
      return if fresh.empty?
      AppToolsTransport.discover(fresh, deadline)
    end

    def initialize(@connection)
    end

    def send_message(
      source_task_id : String,
      target_task_id : String,
      prompt : String,
      timeout : Time::Span,
    )
      AppToolsTransport.send_message(
        connection.socket_file,
        source_task_id,
        target_task_id,
        prompt,
        timeout
      )
    end

    private def self.bundled_node(explicit_node, explicit_resources)
      return {explicit_node, resources_for(explicit_node, explicit_resources)} if explicit_node
      if explicit_resources
        node = File.join(explicit_resources, "cua_node", "bin", Platform.node_name)
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
        paths << {File.join(resources, "cua_node", "bin", Platform.node_name), resources}
      end
      Platform.resource_candidates.each do |resources|
        paths << {File.join(resources, "cua_node", "bin", Platform.node_name), resources}
      end
      paths.find { |path, _| File.exists?(path) } || {nil, nil}
    end

    private def self.resources_for(node_path, configured_resources)
      return configured_resources if configured_resources
      suffix = File.join("cua_node", "bin", Platform.node_name)
      return unless node_path.ends_with?(suffix)
      node_path[0, node_path.bytesize - suffix.bytesize].rstrip(File::SEPARATOR)
    end

    private def self.default_candidates
      Platform.socket_candidates
    end
  end
end
