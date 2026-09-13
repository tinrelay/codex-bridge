module CodexBridge
  private enum MessageState
    Absent
    Provisional
    Accepted
  end

  private record MessageMatch, state : MessageState, turn_id : String? = nil

  # Keep only the facts needed to choose a delivery action and reconcile its
  # stable logical ID. Task prose and model output never enter this projection.
  private class Lifecycle
    getter revision : Int64? = nil
    @state = JSON.parse("{}")

    def invalidate
      @revision = nil
      @state = JSON.parse("{}")
    end

    def update(change : JSON::Any)
      next_revision = change.as_h["revision"].as_i64
      case change.as_h["type"].as_s
      when "snapshot"
        @state = project(change.as_h["conversationState"], "root")
      when "patches"
        if @revision.nil? ||
           change.as_h["baseRevision"].as_i64 != @revision ||
           next_revision <= @revision.not_nil!
          invalidate
          return
        end
        change.as_h["patches"].as_a.each { |patch| apply(patch) }
      else
        invalidate
        return
      end
      @revision = next_revision
    rescue KeyError | IndexError | TypeCastError
      invalidate
    end

    def runtime : String?
      return if revision.nil?
      @state.as_h["threadRuntimeStatus"]?.try { |value| value.as_h["type"]?.try(&.as_s?) }
    end

    def active_turn_id : String?
      return unless runtime == "active"
      current_turn.try { |turn| turn.as_h["turnId"]?.try(&.as_s?) }
    end

    def message_match(logical_id : String) : MessageMatch
      return MessageMatch.new(MessageState::Absent) if revision.nil?
      matches = [] of String?
      turns.each do |turn|
        turn_id = turn.as_h["turnId"]?.try(&.as_s?)
        items = turn.as_h["items"]?.try(&.as_a) || [] of JSON::Any
        items.each do |item|
          next unless item.as_h["type"]?.try(&.as_s?) == "userMessage"
          matches << turn_id if item.as_h["clientId"]?.try(&.as_s?) == logical_id
        end
      end
      raise IncompatibleFailure.new("duplicate_logical_message_id") if matches.size > 1
      return MessageMatch.new(MessageState::Absent) if matches.empty?
      turn_id = matches.first
      return MessageMatch.new(MessageState::Provisional) unless turn_id
      raise IncompatibleFailure.new("invalid_message_turn_id") if turn_id.empty?
      MessageMatch.new(MessageState::Accepted, turn_id)
    end

    private def current_turn : JSON::Any?
      turns.reverse_each.find do |turn|
        turn.as_h["status"]?.try(&.as_s?) == "inProgress"
      end
    end

    private def turns : Array(JSON::Any)
      history = @state.as_h["turnHistory"]?
      if history && history.as_h["kind"]?.try(&.as_s?) == "canonical"
        history.as_h["history"]?.try do |value|
          value.as_h["entitiesByKey"]?.try(&.as_h.values)
        end || [] of JSON::Any
      else
        @state.as_h["turns"]?.try(&.as_a) || [] of JSON::Any
      end
    end

    private def child_kind(kind, key : JSON::Any) : String?
      name = key.as_s?
      case kind
      when "root"
        case name
        when "threadRuntimeStatus" then "runtime"
        when "turns"               then "turns"
        when "turnHistory"         then "history_container"
        end
      when "runtime"
        "leaf" if name == "type"
      when "turns"
        "turn" if key.as_i?
      when "turn"
        if {"turnId", "status"}.includes?(name)
          "leaf"
        elsif name == "items"
          "items"
        end
      when "items"
        "item" if key.as_i?
      when "item"
        "leaf" if {"type", "clientId"}.includes?(name)
      when "history_container"
        name == "kind" ? "leaf" : name == "history" ? "history" : nil
      when "history"
        "entities" if name == "entitiesByKey"
      when "entities"
        "turn" if name
      end
    end

    private def project(value : JSON::Any, kind : String) : JSON::Any
      return value if kind == "leaf" && !value.as_h? && !value.as_a?
      if {"turns", "items"}.includes?(kind)
        child = kind == "turns" ? "turn" : "item"
        return JSON::Any.new(value.as_a.map { |entry| project(entry, child) })
      end
      projected = {} of String => JSON::Any
      value.as_h.each do |key, child|
        if next_kind = child_kind(kind, JSON::Any.new(key))
          projected[key] = project(child, next_kind)
        end
      end
      JSON::Any.new(projected)
    end

    private def apply(patch)
      path = patch.as_h["path"].as_a
      kind = "root"
      path.each do |key|
        kind = child_kind(kind, key) || return
      end
      operation = patch.as_h["op"].as_s
      unless {"add", "replace", "remove"}.includes?(operation)
        raise TypeCastError.new("unknown patch operation")
      end
      if path.empty?
        @state = project(patch.as_h["value"], "root")
        return
      end
      parent = @state
      path[0...-1].each { |key| parent = key.as_s? ? parent[key.as_s] : parent[key.as_i] }
      key = path.last
      if name = key.as_s?
        if operation == "remove"
          parent.as_h.delete(name)
        else
          parent.as_h[name] = project(patch.as_h["value"], kind)
        end
      else
        index = key.as_i
        case operation
        when "remove" then parent.as_a.delete_at(index)
        when "add"    then parent.as_a.insert(index, project(patch.as_h["value"], kind))
        else               parent.as_a[index] = project(patch.as_h["value"], kind)
        end
      end
    end
  end
end
