module CodexBridge
  private class Message
    def initialize(@delivery : Delivery)
    end

    def start_params
      payload = prepared_payload
      {
        conversationId: @delivery.task_id,
        turnStart:      {
          request: {
            threadId:            @delivery.task_id,
            clientUserMessageId: @delivery.logical_message_id,
            input:               payload[:input],
          },
          context: {
            inheritThreadSettings:         true,
            mcpAppModelContextAttachments: payload[:model_context_attachments],
            responseItems:                 payload[:response_items],
          },
        },
      }
    end

    def steer_params
      payload = prepared_payload
      {
        conversationId:      @delivery.task_id,
        input:               payload[:input],
        restoreMessage:      restore_message(payload[:model_context_attachments]),
        serviceTier:         nil,
        attachments:         [] of String,
        clientUserMessageId: @delivery.logical_message_id,
        additionalContext:   nil,
        toolOutput:          nil,
      }
    end

    private def prepared_payload
      if @delivery.attachments.empty?
        return {
          input: [{
            type:          "text",
            text:          @delivery.instruction,
            text_elements: [] of String,
          }],
          model_context_attachments: [] of NamedTuple(
            untrusted: Bool,
            id: String,
            title: String,
            text: String,
            imageAttachments: Array(String)),
          response_items: [] of NamedTuple(
            type: String,
            call_id: String,
            name: String,
            arguments: String),
        }
      end
      attachments = @delivery.attachments.map do |attachment|
        {
          untrusted:        true,
          id:               attachment.id,
          title:            attachment.title,
          text:             attachment.text,
          imageAttachments: [] of String,
        }
      end
      envelope = {version: 1, modelContextAttachments: attachments}
      placeholder = "codex-untrusted-app-input:#{envelope.to_json}"
      instruction = @delivery.instruction
      input = [{
        type:          "text",
        text:          instruction,
        text_elements: [{
          byteRange:   {start: 0, end: instruction.bytesize},
          placeholder: placeholder,
        }],
      }]
      call_id = "codex_bridge_#{UUID.random}"
      output = @delivery.attachments.map do |attachment|
        {
          type: "input_text",
          text: {
            kind:     "model_context",
            source:   "mcp_app",
            sourceId: attachment.id,
            title:    attachment.title,
            text:     attachment.text,
          }.to_json,
        }
      end
      response_items = [
        {type: "function_call", call_id: call_id, name: "untrusted_input", arguments: "{}"},
        {type: "function_call_output", call_id: call_id, output: output},
      ]
      {
        input:                     input,
        model_context_attachments: attachments,
        response_items:            response_items,
      }
    end

    private def restore_message(attachments)
      instruction = @delivery.instruction
      {
        id:        @delivery.logical_message_id,
        text:      instruction,
        createdAt: Time.utc.to_unix_ms,
        context:   {
          prompt:                        instruction,
          turnTrigger:                   "codex_bridge",
          addedFiles:                    [] of String,
          fileAttachments:               [] of String,
          ideContext:                    nil,
          imageAttachments:              [] of String,
          workspaceRoots:                [] of String,
          mcpAppModelContextAttachments: attachments,
        },
      }
    end
  end
end
