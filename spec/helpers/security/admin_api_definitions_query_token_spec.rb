# frozen_string_literal: true

# Security regression coverage for generated API examples.
#
# These examples intentionally document current vulnerable behavior: the helper
# emits authentication credentials in URL query strings, which can leak through
# browser history, intermediary logs, analytics tools, and Referer headers.

require 'rails_helper'

RSpec.describe AdminApiDefinitionsHelper, type: :helper do
  it 'places the API user token in the curl example query string' do
    curl = helper.api_curl_example(method: 'GET', path: '/dynamic_model/test_models.json')

    expect(curl).to include('?use_app_type={{app_type_id}}&user_email={{user_email}}&user_token={{api_token}}')
  end

  it 'places the API shared secret in the generated save trigger URL' do
    report = instance_double(Report, alt_resource_name: 'security-report')

    yaml = helper.api_report_save_trigger_example(report, sa: 'status=open')

    expect(yaml).to include('user_token={{constants.api_shared_secret}}')
    expect(yaml).to include('/reports/security-report.json?status=open')
  end
end