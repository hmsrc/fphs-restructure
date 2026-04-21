# frozen_string_literal: true

# Security regression coverage for the REDCap admin index JSON response.
#
# These examples intentionally document current vulnerable behavior: the admin
# JSON response serializes the decrypted REDCap API key, which exposes a live
# credential to any authenticated admin who can request the JSON format.

require 'rails_helper'

RSpec.describe Redcap::ProjectAdminsController, type: :controller do
  include UserSupport
  include Redcap::RedcapSupport
  include Redcap::ProjectAdminSupport

  render_views

  before(:context) do
    @admin, = ControllerMacros.create_admin
    setup_redcap_project_admin_configs
    create_admin_matching_user
  end

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]
    sign_in @admin
    create_admin_matching_user
  end

  it 'includes the decrypted api_key in the JSON index payload' do
    create_item

    get :index, params: { filter: { disabled: nil } }, format: :json

    expect(response).to have_http_status(:ok)

    json = JSON.parse(response.body)
    exposed_row = json.find do |row|
      row['name'] == @project_admin.name && row['study'] == @project_admin.study
    end

    expect(exposed_row).to be_present
    expect(exposed_row['api_key']).to eq(@project_admin.api_key)
  end
end