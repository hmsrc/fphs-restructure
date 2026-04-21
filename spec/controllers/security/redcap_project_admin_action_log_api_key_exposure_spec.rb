# frozen_string_literal: true

# Security regression coverage for REDCap API key exposure in admin action logs.
#
# Redcap::ProjectAdmin stores api_key encrypted at rest, but AdminActionLogging
# copies raw model attributes into prev_value and new_value for every admin
# update. That persists the encrypted API credential in a broadly readable audit
# table, where it remains recoverable with application secrets.

require 'rails_helper'

RSpec.describe Redcap::ProjectAdminsController, type: :controller do
  include UserSupport
  include Redcap::RedcapSupport
  include Redcap::ProjectAdminSupport

  before(:context) do
    @admin, = ControllerMacros.create_admin
    setup_redcap_project_admin_configs
    create_admin_matching_user
  end

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]
    sign_in @admin
    create_admin_matching_user
    create_item
  end

  it 'stores the REDCap project api_key in admin action log payloads during update' do
    raw_api_key = @project_admin.api_key

    patch :update,
          params: {
            id: @project_admin.id,
            redcap_project_admin: {
              study: @project_admin.study,
              name: @project_admin.name,
              server_url: @project_admin.server_url,
              api_key: raw_api_key,
              dynamic_model_table: @project_admin.dynamic_model_table,
              transfer_mode: @project_admin.transfer_mode,
              frequency: @project_admin.frequency,
              notes: "#{@project_admin.notes} security-log-update"
            }
          },
          format: :js

    expect(response).to have_http_status(:ok)

    log_entry = Admin::AdminActionLog.where(admin_id: @admin.id).order(:id).last
    expect(log_entry).to be_present
    expect(::Utilities::Encryption.decrypt(log_entry.prev_value['api_key'])).to eq(raw_api_key)
    expect(::Utilities::Encryption.decrypt(log_entry.new_value['api_key'])).to eq(raw_api_key)
  end
end