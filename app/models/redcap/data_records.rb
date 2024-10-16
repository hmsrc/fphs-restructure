# frozen_string_literal: true

module Redcap
  #
  # Handle and validate retrieved records
  # Works with the dynamic models created by Redcap::DynamicStorage, although this is not strictly required
  class DataRecords
    # The job request record will be updated every *n* records to provide feedback to the admin
    UpdateJobRequestEvery = 20

    attr_accessor :project_admin, :records, :class_name, :errors,
                  :created_ids, :updated_ids, :unchanged_ids, :disabled_ids, :storage_stage,
                  :current_admin, :retrieved_files, :upserted_records, :imported_files,
                  :step_count, :job, :done,
                  :integer_survey_identifier_field_name, :survey_identifier_field_name, :set_master_id_using_association,
                  :skip_store_if_no_survey_identifier, :skipped_ids

    def initialize(project_admin, class_name)
      super()
      self.project_admin = project_admin
      self.class_name = class_name
      self.storage_stage = ''
      self.updated_ids = []
      self.created_ids = []
      self.unchanged_ids = []
      self.disabled_ids = []
      self.skipped_ids = []
      self.errors = []
      self.current_admin = project_admin.admin
      self.project_admin.current_admin = current_admin
      self.retrieved_files = {}
      self.upserted_records = []
      self.imported_files = []
      self.step_count = UpdateJobRequestEvery
      self.survey_identifier_field_name = project_admin.survey_identifier_field.to_sym
      self.integer_survey_identifier_field_name = project_admin.integer_survey_identifier_field.to_sym
      self.set_master_id_using_association = project_admin.data_options.set_master_id_using_association
      self.skip_store_if_no_survey_identifier = project_admin.data_options.skip_store_if_no_survey_identifier
    end

    #
    # Request a background job retrieve records and save them to the specified model
    # @see Redcap::CaptureRecordsJob#perform_later
    # @param [Redcap::ProjectAdmin] project_admin
    # @param [String] class_name - the class name for the model to store to
    def request_records
      jobclass = Redcap::CaptureRecordsJob
      jobs = ProjectAdmin.existing_jobs(jobclass, project_admin)
      return if jobs.count > 0

      self.job = Redcap::CaptureRecordsJob.perform_later(project_admin, class_name)
      return if Rails.application.config.active_job.queue_adapter == :inline

      project_admin.record_job_request('setup job: store records', result: { requested: true, job: job&.job_id })
    end

    #
    # Immediately retrieve, validate and store the records from REDCap.
    # This is only intended to be called from a background job.
    def retrieve_validate_store
      self.storage_stage = 'retrieve_validate_store'
      update_job_request(create: true)
      retrieve
      summarize_fields
      handle_survey_identifier
      validate
      store
    end

    #
    # Immediately retrieve records from REDCap.
    # This is only intended to be called from a background job.
    # Each record is a Hash, keyed by a symbol
    # @return [Array{Hash}]
    def retrieve
      self.records = project_admin.api_client.records
      self.storage_stage = 'retrieve'
      update_job_request
      records
    end

    #
    # Summarize the multiple choice checkbox fields into _chosen_array fields
    # if the project requests it
    # The method runs through each of the columns, and for any fields requiring
    # summarization adds them to all the records in the current @records set.
    # At this point, prior to storage, the individual checkbox fields return a string
    # value "1" checked, or "0" unchecked. We check for "1" and add the
    # field value represented by that checkbox to the array. Subsequent tag_select UI field
    # processing can display these options appropriately, and SQL can make comparisons
    # against this single field without needing knowledge of additional options that may be
    # added in the future.
    def summarize_fields
      return unless project_admin.data_options.add_multi_choice_summary_fields

      self.storage_stage = 'summarize_fields'
      update_job_request

      all_rc_fields = data_dictionary.all_fields
      all_rc_fields.each_value do |field|
        next unless field.field_type.name == :checkbox

        next unless field.has_checkbox_summary_array?

        ccfs = field.checkbox_choice_fields
        next unless ccfs.present?

        cf_name = field.chosen_array_field_name
        records.each do |rec|
          vals = ccfs.map { |ccf| rec[ccf.to_sym] == '1' && DataDictionaries::Field.choice_field_value(ccf) }
                     .select { |item| item }
          rec[cf_name] = vals
        end
      end
    end

    #
    # The redcap_survey_identifier string field will be returned if the project option exportSurveyFields is true.
    # Other options require it to be processed for storage in other forms.
    def handle_survey_identifier
      records_request_options = project_admin.records_request_options
      return unless records_request_options.exportSurveyFields

      am = project_admin.data_options.associate_master_through_external_identifer
      return unless am

      si_name = survey_identifier_field_name
      integer_si_name = integer_survey_identifier_field_name

      return unless records.first.has_key?(si_name)

      records.each do |rec|
        val = rec[si_name]
        val = nil if val.blank?
        rec[integer_si_name] = val&.to_i
      end

      @has_integer_survey_identifier = true
    end

    #
    # Immediately retrieve file from a REDCap file field for a
    # specific record. The most recent request is stored to the
    # retrieved_files Hash.
    # @return [Hash{Symbol => File}] <description>
    def retrieve_file(record_id, field_name)
      retrieved_files[field_name] = project_admin.api_client.file record_id, field_name
    end

    #
    # Perform validations on the records returned
    # We choose to fail with an exception for these, since any of them
    # represent bad data retrieved from Redcap, which could indicate corruption
    # of the data, which should not make it to the local database
    def validate
      self.storage_stage = 'validate'
      update_job_request

      unless records.is_a? Array
        raise FphsException, "Redcap::DataRecords did not return an array: #{records.class.name}"
      end

      return unless records.first

      unless records.first.is_a? Hash
        raise FphsException,
              "Redcap::DataRecords did not return a hash as first item: #{records.first.class.name}"
      end

      overlapping_fields = records.first.keys & model.attribute_names.map(&:to_sym)
      unless overlapping_fields.length == records.first.keys.length
        missing_fields = records.first.keys - model.attribute_names.map(&:to_sym)
        raise FphsException, "Redcap::DataRecords::ModelMissingFields retrieved record fields are not present in the model:\n" \
                             "#{missing_fields.join(' ')}"
      end

      # We have to ignore fields named <form>_timestamp when checking
      # for completeness of the retrieved records, since the API offers
      # no way of recognizing which forms have surveys available and would
      # therefore return a _timestamp field when completed.
      timestamp_fields = project_admin.redcap_data_dictionary.form_names.map { |f| "#{f}_timestamp".to_sym }
      expected_minus_form_timestamps = all_data_dictionary_fields.keys - timestamp_fields
      records.each do |r|
        actual_fields_minus_timestamps = r.keys - timestamp_fields
        next if actual_fields_minus_timestamps.sort == expected_minus_form_timestamps.sort

        raise FphsException,
              "Redcap::DataRecords::MismatchFields retrieved record fields don't match the data dictionary:\n" \
              "missing: #{(expected_minus_form_timestamps - actual_fields_minus_timestamps).sort.join(' ')}\n" \
              "additional: #{(actual_fields_minus_timestamps - expected_minus_form_timestamps).sort.join(' ')}"
      end

      if project_admin.fail_on_deleted_records? && records.length < existing_records_length
        raise FphsException,
              "Redcap::DataRecords retrieved fewer records (#{records.length}) " \
              "than expected (#{existing_records_length})"
      end

      if retrieved_rec_ids.find { |r| r[record_id_field].blank? }
        raise FphsException, 'Redcap::DataRecords retrieved data that has a nil record id'
      end

      return if existing_not_in_retrieved_ids.empty? ||
                project_admin.ignore_deleted_records? || project_admin.disable_deleted_records?

      raise FphsException,
            'Redcap::DataRecords existing records were not in the retrieved records: ' \
            "#{existing_not_in_retrieved_ids.join(', ')}"
    end

    #
    # Store (upsert) each of the retrieved records into the named model.
    # This is done iteratively, to ensure that callbacks are fired.
    # Error will appear in #errors
    # IDs of created items will appear in #created_ids
    # IDs of updated items will appear in #updated_ids
    # For each updated or created record, also download the file fields to the
    # associated file store
    # The actual processing is paged, limiting the number of records processed
    # to the value set in #step_count. This is intended to limit the memory consumption
    # from holding record instances in #upserted_records
    def store
      disable_deleted_records if project_admin.disable_deleted_records?

      upserts = []
      self.storage_stage = 'store'
      update_job_request

      self.done = 0
      from = 0
      step = step_count

      (records.length / step + 1).times do
        subset = records[from, step]
        self.upserted_records = []
        subset.each do |record|
          res = create_or_update record
          upserts << res if res
        end

        upserted_records.each do |record|
          capture_files record
        end
        from += step
        self.done = from
        update_job_request
      end

      self.done = records.length
      self.storage_stage = 'store complete'
      update_job_request
    end

    #
    # Retrieve all model records
    # @return [ActiveRecord::Relation]
    def existing_records
      model.all
    end

    #
    # Count of existing records stored as the model
    # @return [Integer]
    def existing_records_length
      existing_records.count
    end

    #
    # Array of Redcap record ids, based on the record_id_field
    # These are full hashes of identifying attributes, to handle repeated records.
    # The values are cast to strings, to allow easier comparison later
    # @return [Array{Hash}]
    def retrieved_rec_ids
      return @retrieved_rec_ids if @retrieved_rec_ids

      @retrieved_rec_ids = records.map do |r|
        record_identifier_fields.map { |f| [f, r[f].to_s] }.to_h
      end
    end

    #
    # Array of database record ids that were not retrieved in the Redcap records.
    # These are full hashes of identifying attributes, to handle repeated records
    # @return [Array{Hash}]
    def existing_not_in_retrieved_ids
      return @existing_not_in_retrieved_ids if @existing_not_in_retrieved_ids

      existing_rec_ids = existing_records.select(record_identifier_fields).to_a
      existing_rec_ids = existing_rec_ids.map { |r| r.attributes.symbolize_keys.slice(*record_identifier_fields) }
      @existing_not_in_retrieved_ids = existing_rec_ids - retrieved_rec_ids
    end

    private

    def data_dictionary
      project_admin.redcap_data_dictionary
    end

    #
    # The sequential record_id field is not a fixed name. Get it from the data dictionary
    # @return [Symbol]
    def record_id_field
      data_dictionary.record_id_field
    end

    #
    # Extra fields used to uniquely identify a record (e.g. for repeat instruments)
    # @return [Array{Symbol} | nil]
    def record_id_extra_fields
      data_dictionary.record_id_extra_fields
    end

    #
    # Full list of fields used to identify a record
    # @return [Array]
    def record_identifier_fields
      getfields = [record_id_field]
      getfields += record_id_extra_fields if record_id_extra_fields
      getfields
    end

    #
    # All fields expected to be retrieved from REDCap to be stored as a record
    # @return [Hash{Symbol => Redcap::DataDictionaries::Field}]
    def all_data_dictionary_fields
      @all_data_dictionary_fields ||= data_dictionary.all_retrievable_fields(summary_fields: true)
    end

    #
    # The model we are using to instantiate records
    # @return [DynamicModel]
    def model
      @model ||= class_name.constantize
      return @model if @model < Dynamic::DynamicModelBase

      raise FphsException,
            "Redcap::DataRecords model is not a valid type: #{class_name}"
    end

    #
    # Hash of fields that identify the current record. For classic instruments,
    # this is simply a record id field. For repeating instruments, additional fields
    # are required to uniquely identify the record.
    # @param [Hash] record
    # @return [Hash]
    def record_identifiers(record)
      rec_ids = { record_id_field => record[record_id_field] }

      record_id_extra_fields&.each do |f|
        rec_ids[f] = record[f]
      end

      rec_ids
    end

    #
    # If Redcap records were previously transferred to the local database then
    # subsequently deleted, set them as disabled
    # @return [Array] of record identifier hashes, false or nil results
    def disable_deleted_records
      self.storage_stage = 'disable_deleted_records'
      update_job_request

      self.done = 0
      existing_not_in_retrieved_ids.each do |dbrec|
        record = existing_records.find_by(dbrec)
        self.done += 1
        update_job_request if done % step_count == 0

        next if record.disabled?

        record.disabled = true
        attrs = record.attributes
                      .reject { |k, _v| k.in?(%w[id created_at updated_at user_id]) }
                      .symbolize_keys

        res = create_or_update(attrs, keep_results: false)
        disabled_ids << res[record_id_field] if res
      end

      self.storage_stage = 'disable_deleted_records complete'
      update_job_request
    end

    #
    # Should we handle setting the master_id on a record?
    def do_handle_setting_master_id
      return @do_handle_setting_master_id unless @do_handle_setting_master_id.nil?

      @do_handle_setting_master_id = !!(@has_integer_survey_identifier && set_master_id_using_association)
    end

    #
    # If the project has the option set_master_id_using_association, update
    # the new/update record master_id value with the master_id returned from the
    # external id association.
    # @return [Integer | nil] - master_id if it was set, -1 if we don't handle setting the master id,
    #                           or nil if the record is to be skipped
    def handle_setting_master_id(update_record, retrieved_record)
      return -1 unless do_handle_setting_master_id

      isi = retrieved_record[integer_survey_identifier_field_name]
      recid = retrieved_record.first.last
      if !isi && !skip_store_if_no_survey_identifier
        raise FphsException,
              "Integer survey identifier field is empty, can't set master id, for record #{recid}"
      elsif isi
        # Start by setting the integer survey identifier field, so the association can get the master with the new value
        update_record[integer_survey_identifier_field_name] = isi
      elsif skip_store_if_no_survey_identifier
        # No survey identifier is returned and the project option skip_store_if_no_survey_identifier is set, so
        # just return with no result, indicating a skip.
        return
      end

      # Retrieve the master_id from the record (which goes through the association), then set the value returned
      # on the actual underlying attribute. Although this looks like it is assigning the same value, this is not
      # actually what is happening.
      res = update_record.master_id = update_record.master_id

      unless res
        raise FphsException,
              "Redcap pull failed to get master id through association, for record #{recid} with survey identifier #{isi}"
      end

      res
    end

    #
    # Handle creation of new record if the record does not already exist based on its
    # record_id_field matching, update if it does exist and has new information, or
    # do nothing if it exists and is unchanged.
    # Validations are applied to creates and updates and errors are returned within an
    # errors array. Callbacks (dynamic save triggers) are fired.
    # If an update or create is successful, return the record identifiers,
    # if there is no change return false
    # and if there is any other result (an error) return nil.
    # @param [Hash] record
    # @param [true | false] keep_results - save each existing or new record to @upserted_records
    # @return [Integer | false | nil]
    def create_or_update(retrieved_record, keep_results: true)
      rec_ids = record_identifiers(retrieved_record)
      existing_record = model.where(rec_ids).first
      if existing_record
        existing_record.no_track = true if existing_record.respond_to? :no_track
        existing_record.current_user = current_user if existing_record.respond_to? :current_user=

        # Check if there is an exact match for the record. If so, we are done
        if record_matches_retrieved(existing_record, retrieved_record)
          unchanged_ids << rec_ids
          return false
        end

        res = handle_setting_master_id(existing_record, retrieved_record)
        # No valid result, but no exception, so just skip this one
        unless res
          skipped_ids << rec_ids
          return
        end

        existing_record.force_save!
        if existing_record.update(retrieved_record)
          if keep_results
            updated_ids << rec_ids
            upserted_records << existing_record
          end
          return rec_ids
        else
          errors << { id: rec_ids, errors: existing_record.errors, action: :update }
        end
      else
        new_record = model.new(retrieved_record)
        new_record.no_track = true if new_record.respond_to? :no_track
        new_record.current_user = current_user if new_record.respond_to? :current_user=

        res = handle_setting_master_id(new_record, retrieved_record)
        unless res
          skipped_ids << rec_ids
          return
        end

        new_record.force_save!
        if new_record.save
          if keep_results
            created_ids << rec_ids
            upserted_records << new_record
          end
          return rec_ids
        else
          errors << { id: rec_ids, errors: new_record.errors, action: :create }
        end
      end

      nil
    end

    #
    # Capture files from file fields in the requested record, which typically represents
    # an updated or created dynamic model instance.
    # Files are only retrieved if the record includes a string entry in the
    # retrieved record field.
    # Once retrieved, files are stored in the project's filestore,
    # with the path: file-fields/<record id>
    # and file name: <field name>
    # @param [UserBase] record - the record to capture the file fields from
    def capture_files(record)
      self.done = 0
      file_fields.each do |field_name|
        next if record[field_name].blank?

        self.done += 1
        update_job_request if done % step_count == 0

        record_id = record[record_id_field]
        begin
          temp_file = retrieve_file(record_id, field_name)
          # We must change the permissions now, since the final NFS store
          # requires the group to have read-write.
          path = "#{project_admin.dynamic_model_table}/file-fields/#{record_id}"
          filename = field_name
          container = project_admin.file_store

          res = NfsStore::Import.import_file(container.id,
                                             filename,
                                             temp_file.path,
                                             current_user,
                                             path:,
                                             replace: true)
          imported_files << res if res
        rescue Exception => e # rubocop:disable Lint/RescueException
          # We rescue Exception rather than StandardError, since file errors inherit from Exception
          msg = "Failed to retrieve or import REDCap file for record: #{record_id} - field name: #{field_name} - with user: #{current_user.email}.\n#{e}"
          Rails.logger.warn msg
          errors << { id: record_id, errors: { capture_files: msg }, action: :capture_files }
          raise
        ensure
          temp_file&.close
          temp_file&.unlink
        end
      end
    end

    #
    # Array of file field fieldnames
    # @return [Array{Symbol}]
    def file_fields
      data_dictionary.all_fields_of_type(:file).keys
    end

    #
    # Check if a stored record matches the retrieved record.
    # Care must be taken, since REDCap retrieved records have every
    # attribute as a string. A dynamic model may also have fields that are not
    # exclusively part of the data dictionary.
    # We cast retrieved record field value strings to real values for comparison
    # since this reduces the sensitivity of string comparisons. For example,
    # converting a number 243.0 and 243 should be equivalent, but string comparisons
    # will fail.
    # @param [Dynamic::DynamicModelBase] existing_record
    # @param [Hash{Symbol => String}] new_record
    # @return [true]
    def record_matches_retrieved(existing_record, new_record)
      new_attrs = new_record.dup
      existing_attrs = existing_record.attributes.symbolize_keys.dup
      existing_attrs.slice!(*all_data_dictionary_fields.keys)

      res = new_attrs.reject do |field_name, new_value|
        # We allow the field_name to return nothing from the fields, since attributes like
        # *disabled* can be updated in this way
        all_data_dictionary_fields[field_name]&.field_type&.values_match?(new_value, existing_attrs[field_name])
      end

      # Handle special case - if the option to set_master_id_using_association && the current master_id is not set
      # This will allow the lookup of the master to run by treating it as having changed.
      res[:master_id] = true if set_master_id_using_association && existing_record['master_id'].nil?

      res.empty?
    end

    #
    # The current user to use for storing records and files
    # @return [User]
    def current_user
      @current_user ||= project_admin.current_user
    end

    #
    # Create or update job request record
    # @param [true | nil] create - optional - create a new record for this request
    def update_job_request(create: nil)
      result = {
        storage_stage:,
        count_retrieved: records&.length,
        count_created_ids: created_ids&.length,
        count_updated_ids: updated_ids&.length,
        count_unchanged_ids: unchanged_ids&.length,
        count_disabled_ids: disabled_ids&.length,
        count_skipped_ids: skipped_ids&.length,
        count_processed: done,
        table: project_admin.dynamic_model_table,
        errors:,
        imported_files_count: imported_files&.length,
        job: job&.id
      }

      if create
        project_admin.record_job_request('store records', result:)
      else
        project_admin.update_job_request('store records', result:)
      end
    end
  end
end
