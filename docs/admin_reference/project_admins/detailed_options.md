# REDCap Project Transfer: Detailed Options

!defs(project_admin_field_defs.yaml)

---

## Options

Options are set with reasonable defaults when a project is first saved.

```yaml
records_request_options:
  exportSurveyFields: true | false | (blank)
    # The admin must set this value based on the 
    # actual configuration of the REDCap project. 
    # If surveys are enabled for the project, set 
    # this value to **true** otherwise leave it 
    # blank or **false**.
  returnMetadataOnly:
  exportDataAccessGroups:
  returnFormat:
metadata_request_options:
  returnFormat:
data_options:
  add_multi_choice_summary_fields: true | null | (blank)
    # If *true*, Adds an extra array field to the
    # database for checkbox fields, providing
    # a single field summarizing all selected 
    # checkboxes for a single REDCap field.
    # By default (*false* or blank) only the 
    # individual checkbox fields for each option will
    # be added, as 
    # `<field_name>___1`, `<field_name>___2`,...
  handle_deleted_records: value
    # one of
    #   - disable
    #   - ignore
    #   - (blank)
    #   - null
    #   - false
  prefix_dynamic_model_config_library: category name
    # The "<category> <name>" string identifier for a
    # config library to be prefixed to the dynamic
    # model definition whenever it is updated.
    # For example: "redcap test_library"
  associate_master_through_external_identifer: <external identifier> (optional: foreign key name)
    # Specify an external identifier resource name to use to look up the master record each
    # stored record is associated with. By default, "redcap_survey_identifier_id" is used as the
    # foreign key name used to look up the the external id. Optionally specify an alternative field name.
    # When this is specified, and the project is set to `exportSurveyFields: true` then an additional
    # `redcap_survey_identifier_id` field is added to the dynamic model database table, defined as an
    # integer type. This allows it to be correctly joined to integer typed external id fields on other tables.
  set_master_id_using_association: true|false
    # If option `associate_master_through_external_identifer` is set, the ability to retrieve the master record
    # can be used to set a `master_id` field directly on the dynamic model. Setting this option to *true* will
    # add a `master_id` field automatically, and ensure it is set when records are retrieved from REDCap.
    # NOTE: for large datasets that change regularly, this may slow down record retrieval significantly.  
  run_jobs_as_user: <username>
    # Sets the admin and matching user that will be used to run background jobs, 
    # such as getting project metadata or retrieving records from REDCap.
    # New projects set this to the email address or id in settings `RedcapJobUserEmail`, which may be set by
    # the environment variable `FPHS_RC_JOB_USER_EMAIL` or will default to the setting `BatchUserEmail`.
    # If left blank in earlier projects or explicitly set to blank, the user matching the project's current admin will be used.
  run_jobs_in_app_type: <app type name or id>
    # Sets the app type that will be set on the `run_as_jobs_user`, effectively setting the
    # access controls that authorize actions performed in background jobs such as retrieving records.
    # This avoids an arbitrary app type being set, especially where the dynamic model being stored to has save triggers
    # specified that may depend on access to specific resources.

data_dictionary_version: random hash
    # do not change - a hash generated internally to 
    # identify whether the data dictionary has changed
```
