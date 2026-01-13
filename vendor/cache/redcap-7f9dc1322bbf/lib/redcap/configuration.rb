module Redcap
  class Configuration
    attr_accessor :host, :token, :format, :logger, :log_level

    def initialize(options = {})
      @host   = options[:host]
      @token  = options[:token]
      @format = options[:format] || :json
      @logger = options[:logger] || Logger.new(STDOUT)
      @log_level = options[:log_level]
    end
  end
end
