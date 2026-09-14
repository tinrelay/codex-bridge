require "./codex_bridge"
require "./codex_bridge/cli"

exit CodexBridge::CLI.run(ARGV.dup)
