module CodexBridge
  private module Platform
    RELAY_SOCKET_PREFIX = "relay-"
  end
end

{% if flag?(:darwin) %}
  require "./platform/macos"
{% elsif flag?(:linux) %}
  require "./platform/unix"
{% elsif flag?(:win32) %}
  require "./platform/windows"
{% else %}
  {% raise "codex-bridge does not support this platform" %}
{% end %}
