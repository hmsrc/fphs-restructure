# frozen_string_literal: true

# Security regression coverage for user profile JSON serialization.
#
# This example intentionally documents current vulnerable behavior: the
# user_profile JSON endpoint returns a serialized User record containing
# authentication_token, exposing an API credential in a standard profile response.

require 'rails_helper'

RSpec.describe UserProfilesController, type: :controller do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @request.env['devise.mapping'] = Devise.mappings[:user]
    @user, = create_user
    sign_in @user
  end

  it 'includes authentication_token in the user profile JSON payload' do
    get :show, format: :json

    expect(response).to have_http_status(:ok)

    body = JSON.parse(response.body)
    user_json = body.dig('user_profile', 'user')

    expect(user_json).to be_present
    expect(user_json['authentication_token']).to be_present
  end
end