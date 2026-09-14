require "json"
require "socket"
require "sqlite3"
require "uuid"

module CodexBridge
  VERSION = "0.1.0"
end

require "./codex_bridge/types"
require "./codex_bridge/state_store"
require "./codex_bridge/platform_discovery"
{% if flag?(:darwin) %}
  require "./codex_bridge/app_tools_node_transport"
{% end %}
require "./codex_bridge/app_tools_transport"
require "./codex_bridge/app_tools_endpoint"
require "./codex_bridge/discovery"
require "./codex_bridge/client"
