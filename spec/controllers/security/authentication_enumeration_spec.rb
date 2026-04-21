# frozen_string_literal: true

# Security regression coverage for user enumeration via authentication endpoints.
#
# Verifies the MFA step1 endpoint does not leak whether a user exists by
# returning different HTTP status codes or structurally different JSON responses
# for registered vs unregistered email addresses.
#
# The key security property: an attacker cannot distinguish valid from invalid
# emails based on the step1 response, preventing user harvesting.

require 'rails_helper'

RSpec.describe 'User Enumeration via Authentication', type: :request do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @registered_user, = create_user
    @unregistered_email = "enumeration-test-#{SecureRandom.hex(8)}@example.com"
  end

  it 'returns need_2fa flag for existing user via MFA step1 endpoint' do
    post '/mfa/step1.json',
         params: {
           user: {
             email: @registered_user.email,
             password: @good_password
           },
           resource_type: :user
         }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.key?('need_2fa')).to be true
  end

  it 'returns need_2fa flag for non-existent user via MFA step1 endpoint' do
    post '/mfa/step1.json',
         params: {
           user: {
             email: @unregistered_email,
             password: 'some-random-password'
           },
           resource_type: :user
         }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.key?('need_2fa')).to be true
  end

  it 'returns same HTTP status for valid and invalid user emails in MFA step1' do
    post '/mfa/step1.json',
         params: {
           user: {
             email: @registered_user.email,
             password: @good_password
           },
           resource_type: :user
         }

    valid_status = response.status
    valid_body_keys = JSON.parse(response.body).keys.sort

    post '/mfa/step1.json',
         params: {
           user: {
             email: @unregistered_email,
             password: 'random-password'
           },
           resource_type: :user
         }

    invalid_status = response.status
    invalid_body_keys = JSON.parse(response.body).keys.sort

    expect(valid_status).to eq(invalid_status), 'HTTP status differs for valid vs invalid users — enumeration risk'
    expect(valid_body_keys).to eq(invalid_body_keys), 'Response structure differs for valid vs invalid users — enumeration risk'
  end

  it 'returns same need_2fa value for valid and invalid user emails when 2FA is enabled' do
    skip 'Test assumes 2FA is enabled' if User.two_factor_auth_disabled

    post '/mfa/step1.json',
         params: {
           user: {
             email: @registered_user.email,
             password: @good_password
           },
           resource_type: :user
         }
    valid_need_2fa = JSON.parse(response.body)['need_2fa']

    post '/mfa/step1.json',
         params: {
           user: {
             email: @unregistered_email,
             password: 'random-password'
           },
           resource_type: :user
         }
    invalid_need_2fa = JSON.parse(response.body)['need_2fa']

    expect(valid_need_2fa).to eq(invalid_need_2fa), 'need_2fa value differs for valid vs invalid users — enumeration risk'
  end
end
