# frozen_string_literal: true

# Security regression coverage for manage users JSON token exposure.
#
# This example documents current vulnerable behavior: the
# Admin::ManageUsersController#index JSON response includes user
# authentication_token values in serialized user records.

require 'rails_helper'

RSpec.describe Admin::ManageUsersController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]
    @admin, = create_admin

    @target_user, = create_user

    sign_in @admin
  end

  it 'includes authentication_token in the JSON index payload' do
    get :index, format: :json

    expect(response).to have_http_status(:ok)

    payload = JSON.parse(response.body)
    user_record = payload.find { |row| row['email'] == @target_user.email }

    expect(user_record).to be_present
    expect(user_record['authentication_token']).to eq(@target_user.authentication_token)
  end
end
