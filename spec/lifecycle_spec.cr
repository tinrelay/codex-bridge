require "./spec_helper"

module CodexBridge
  private def self.snapshot(state, revision = 1)
    JSON.parse({type: "snapshot", revision: revision, conversationState: state}.to_json)
  end

  describe Lifecycle do
    it "matches each user-message client ID inside its containing turn" do
      lifecycle = Lifecycle.new
      lifecycle.update(snapshot({
        threadRuntimeStatus: {type: "active"},
        turnHistory:         {
          kind:    "canonical",
          history: {entitiesByKey: {
            one: {
              turnId: "turn-1", status: "inProgress",
              items: [
                {type: "userMessage", clientId: "first", content: "discarded"},
                {type: "userMessage", clientId: "second", content: "discarded"},
              ],
            },
          }},
        },
      }))

      lifecycle.active_turn_id.should eq("turn-1")
      lifecycle.message_match("first").turn_id.should eq("turn-1")
      lifecycle.message_match("second").turn_id.should eq("turn-1")
      lifecycle.message_match("missing").state.should eq(MessageState::Absent)
    end

    it "fails when one logical ID appears in more than one user-message item" do
      lifecycle = Lifecycle.new
      lifecycle.update(snapshot({
        threadRuntimeStatus: {type: "idle"},
        turnHistory:         {
          kind:    "canonical",
          history: {entitiesByKey: {
            one: {
              turnId: "turn-1", status: "completed",
              items: [
                {type: "userMessage", clientId: "duplicate"},
                {type: "userMessage", clientId: "duplicate"},
              ],
            },
          }},
        },
      }))

      expect_raises(IncompatibleFailure, "duplicate_logical_message_id") do
        lifecycle.message_match("duplicate")
      end
    end

    it "keeps a matching item provisional until its containing turn has an ID" do
      lifecycle = Lifecycle.new
      lifecycle.update(snapshot({
        threadRuntimeStatus: {type: "active"},
        turns:               [{
          status: "inProgress",
          items:  [{type: "userMessage", clientId: "provisional"}],
        }],
      }))

      match = lifecycle.message_match("provisional")
      match.state.should eq(MessageState::Provisional)
      match.turn_id.should be_nil
    end

    it "invalidates skipped lifecycle revisions" do
      lifecycle = Lifecycle.new
      lifecycle.update(snapshot({threadRuntimeStatus: {type: "idle"}, turns: [] of String}))
      lifecycle.update(JSON.parse({
        type: "patches", baseRevision: 2, revision: 3, patches: [] of String,
      }.to_json))
      lifecycle.revision.should be_nil
    end
  end
end
