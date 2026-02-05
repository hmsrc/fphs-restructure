require 'hashie'
require 'json'
require 'rest-client'
require 'logger'
require 'dotenv'
require 'memoist'
require 'redcap/version'
require 'redcap/configuration'
require 'redcap/record'

Dotenv.load

module Redcap
  attr_reader :configuration

  class << self
    def new(options = {})
      if options.empty? && ENV
        options[:host] = ENV['REDCAP_HOST']
        options[:token] = ENV['REDCAP_TOKEN']
      end
      self.configure = options
      Redcap::Client.new(logger: configuration.logger, log_level: configuration.log_level)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def configure=(options)
      @configuration = if options.nil?
                         nil
                       else
                         Configuration.new(options)
                       end
    end

    def configure
      yield configuration
      configuration
    end
  end

  class Client
    extend Memoist

    attr_reader :logger
    attr_writer :log

    # raw_response - if true, treat the response as a plain string rather than attempting to parse JSON
    # response_code - HTTP response code from the last request
    attr_accessor :raw_response, :response_code

    ValidExportLogTypes = {
      export: 'Data export',
      manage: 'Manage/Design',
      user: 'User or role created-updated-deleted',
      record: 'Record created-updated-deleted',
      record_add: 'Record created (only)',
      record_edit: 'Record updated (only)',
      record_delete: 'Record deleted (only)',
      lock_record: 'Record locking & e-signatures',
      page_view: 'Page Views'
    }.freeze

    #
    # Initialize the client and optionally set logger options
    # @param [Logger] logger - default Logger, or for example pass an instance of a Rails logger
    # @param [Logger::Severity | nil] log_level - default level to log messages or nil to disable logging
    def initialize(logger: nil, log_level: nil)
      @logger = logger || Logger.new(STDOUT)
      @log = log_level
    end

    def configuration
      Redcap.configuration
    end

    #
    # Set to log only if the @log level is not nil
    # @return [Boolean]
    def log?
      !!@log
    end

    #
    # Log message using logger instance, at either the default level (@log)
    # or the specified `level` parameter
    # @param [String] message The message to log
    # @param [Logger::Severity | nil] level The log level to use, or nil to use the default
    def log(message, level: nil)
      level ||= @log
      return unless level

      @logger.add(level, message)
    end

    def project(request_options: nil)
      payload = build_payload(content: :project,
                              request_options: request_options)
      post payload
    end

    def user(request_options: nil)
      payload = build_payload(content: :user,
                              request_options: request_options)
      post payload
    end

    def project_xml(request_options: nil)
      payload = build_payload(content: :project_xml,
                              request_options: request_options)
      post_file_request payload
    end

    def max_id
      records(fields: %w[record_id]).map(&:values).flatten.map(&:to_i).max.to_i
    end

    def fields
      metadata.map { |m| m['field_name'].to_sym }
    end

    def metadata(request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: :metadata,
        fields: []
      }

      payload.merge! request_options if request_options
      post payload
    end

    def instrument(request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: :instrument
      }

      payload.merge! request_options if request_options
      post payload
    end

    def form_event_mapping(request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: :formEventMapping
      }

      payload.merge! request_options if request_options
      post payload
    end

    def export_field_names(request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: :exportFieldNames
      }

      payload.merge! request_options if request_options
      post payload
    end

    def records(records: [], fields: [], filter: nil, request_options: nil)
      # add :record_id if not included
      fields |= [:record_id] if fields.any?
      payload = build_payload(content: :record,
                              records: records,
                              fields: fields,
                              filter: filter,
                              request_options: request_options)
      post payload
    end

    def survey_link(instrument: nil, record_id: nil, request_options: nil)
      request_options ||= {}
      request_options[:instrument] = instrument if instrument
      request_options[:record] = record_id.to_s if record_id

      # Ensure that we interpret the response as a simple string, rather than attempting to parse JSON
      self.raw_response = true

      payload = build_payload(content: :surveyLink,
                              request_options: request_options)

      post payload
    end

    def participant_list(instrument: nil, event: nil, request_options: nil)
      request_options ||= {}
      request_options[:instrument] = instrument if instrument
      request_options[:event] = event if event

      payload = build_payload(content: :participantList,
                              request_options: request_options)

      post payload
    end

    def arm(request_options: nil)
      payload = build_payload(content: :arm,
                              request_options: request_options)

      post payload
    end

    def event(request_options: nil)
      payload = build_payload(content: :event,
                              request_options: request_options)

      post payload
    end

    def repeating_forms_events(request_options: nil)
      payload = build_payload(content: :repeatingFormsEvents,
                              request_options: request_options)

      post payload
    end

    def update(data = [], request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: :record,
        overwriteBehavior: :normal,
        type: :flat,
        returnContent: :count,
        data: data.to_json
      }

      payload.merge! request_options if request_options
      log flush_cache if ENV['REDCAP_CACHE'] == 'ON'
      result = post payload
      result['count'] == 1
    end

    def create(data = [], request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: :record,
        overwriteBehavior: :normal,
        type: :flat,
        returnContent: :ids,
        data: data.to_json
      }
      payload.merge! request_options if request_options
      log flush_cache if ENV['REDCAP_CACHE'] == 'ON'
      post payload
    end

    def delete(ids, request_options: nil)
      return unless ids.is_a?(Array) && ids.any?

      payload = build_payload content: :record, records: ids, action: :delete, request_options: request_options
      log flush_cache if ENV['REDCAP_CACHE'] == 'ON'
      post payload
    end

    def file(record_id, field_name, event: nil)
      request_options = { field: field_name, record: record_id }
      request_options[:event] = event if event
      payload = build_payload(content: :file,
                              action: :export,
                              request_options:)
      post_file_request payload
    end

    def export_log(record_id: nil, begin_time: nil, end_time: nil, log_type: nil, request_options: nil)
      request_options ||= {}
      request_options[:record] = record_id if record_id
      request_options[:beginTime] = begin_time if begin_time
      request_options[:endTime] = end_time if end_time
      request_options[:logType] = log_type if log_type
      
      if log_type && !ValidExportLogTypes.key?(log_type.to_sym)
        raise ArgumentError, "Redcap export_log invalid log_type '#{log_type}'. Valid types are: #{ValidExportLogTypes.keys.join(', ')}"
      end

      payload = build_payload(content: :log,
                              action: :export,
                              request_options: request_options)

      post payload
    end

    private

    def build_payload(content: nil, records: [], fields: [], filter: nil, action: nil, request_options: nil)
      payload = {
        token: configuration.token,
        format: configuration.format,
        content: content
      }
      payload[:action] = action if action

      records&.each_with_index do |record, index|
        payload["records[#{index}]"] = record
      end

      fields&.each_with_index do |field, index|
        payload["fields[#{index}]"] = field
      end

      payload[:filterLogic] = filter if filter
      payload.merge!(request_options) if request_options
      payload
    end

    def post(payload = {})
      log "Redcap POST to #{configuration.host} with #{clean_for_log(payload)}"
      response = RestClient.post configuration.host, payload
      self.response_code = response&.code

      if raw_response
        # For a raw response, just return a string (null will become an empty string)
        # Set the raw_response flag back to false for future requests
        self.raw_response = false
        response = response.to_s
      elsif response
        response = JSON.parse(response)
      elsif response.nil?
        log 'Response nil'
      end

      log "Response: #{response_code}"
      log response, level: Logger::DEBUG
      response
    end
    memoize(:post) if ENV['REDCAP_CACHE'] == 'ON'

    def post_file_request(payload = {})
      log "Redcap POST for file field to #{configuration.host} with #{clean_for_log(payload)}"
      response = RestClient::Request.execute method: :post, url: configuration.host, payload: payload,
                                             raw_response: true

      self.response_code = response&.code
      file = response&.file
      log 'File response nil' if response.nil?
      log "File response code: #{response_code}"
      log file, level: Logger::DEBUG
      file
    end

    def clean_for_log(payload)
      clean_payload = payload.dup
      clean_payload[:token] = '***FILTERED***' if clean_payload.key?(:token)
      clean_payload[:data] = '***FILTERED***' if clean_payload.key?(:data)
      clean_payload
    end
  end
end
