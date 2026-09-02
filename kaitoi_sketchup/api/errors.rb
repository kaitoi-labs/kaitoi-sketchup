module Kaitoio
  class Error < StandardError
    attr_reader :status, :code, :details, :request_id
    def initialize(message, status: nil, code: nil, details: nil, request_id: nil)
      super(message)
      @status     = status
      @code       = code
      @details    = details
      @request_id = request_id
    end

    def to_s
      prefix = "[#{code || status || 'ERR'}]"
      prefix += " req=#{request_id}" if request_id
      "#{prefix} #{super}"
    end
  end

  class AuthError       < Error; end
  class VersionConflict < Error; end
  class RateLimited     < Error; end
  class NotFound        < Error; end
  class ValidationError < Error; end
  class FileInUse       < Error; end
end
