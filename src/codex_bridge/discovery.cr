module CodexBridge
  record Connection,
    socket_file : String,
    node_path : String,
    codex_resources : String?

  def self.discover(
    codex_home = ENV["CODEX_HOME"]? || Path.home.join(".codex").to_s,
    *,
    state_home : String? = nil,
    socket_file : String? = nil,
    node_path : String? = nil,
    codex_resources : String? = nil,
    cache = true,
  ) : Connection?
    state_home ||= File.join(codex_home, "codex-bridge")
    AppToolsEndpoint.discover(
      state_home,
      socket_file: socket_file,
      node_path: node_path,
      codex_resources: codex_resources,
      cache: cache
    ).try(&.connection)
  end
end
