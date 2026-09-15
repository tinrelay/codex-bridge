module CodexBridge
  class Error < Exception
    getter reason : String

    def initialize(@reason)
      super(reason)
    end
  end

  class NotReceived < Error; end

  class TaskUnavailable < NotReceived; end

  class MessageRejected < NotReceived; end

  class ReceiptUnknown < Error; end

  class InstallError < Error; end

  private class AppToolsRejected < Exception; end

  private class AppToolsReceiptUnknown < Exception; end
end
