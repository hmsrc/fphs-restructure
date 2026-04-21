# frozen_string_literal: true

# Security regression coverage for 2FA bypass during user login.
#
# Verifies that the devise-two-factor Warden strategy correctly rejects login attempts
# when OTP is empty, missing, or invalid. A successful login with a valid OTP is
# also tested to confirm the happy path works, ensuring these are meaningful security tests.
#
# The key security property: when 2FA is enabled, a valid password alone is
# insufficient to create a session — a valid OTP must also be provided.

require 'rails_helper'

RSpec.describe 'User Login with 2FA', type: :request do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @user, = create_user

    expect(@user.otp_required_for_login).to be_truthy unless User.two_factor_auth_disabled
  end

  def warden_user
    request.env['warden'].user(:user)
  end

  it 'creates a user session when valid email, password, and OTP are provided' do
    skip 'Test assumes 2FA is enabled' if User.two_factor_auth_disabled

    otp_code = @user.current_otp

    post user_session_path,
         params: {
           user: {
             email: @user.email,
             password: @good_password,
             otp_attempt: otp_code
           }
         }

    follow_redirect! if response.redirect?
    expect(warden_user&.id).to eq(@user.id)
  end

  it 'rejects login when OTP attempt is empty but 2FA is required' do
    skip 'Test assumes 2FA is enabled' if User.two_factor_auth_disabled

    post user_session_path,
         params: {
           user: {
             email: @user.email,
             password: @good_password,
             otp_attempt: ''
           }
         }

    expect(warden_user).to be_nil
  end

  it 'rejects login when OTP attempt is invalid' do
    skip 'Test assumes 2FA is enabled' if User.two_factor_auth_disabled

    post user_session_path,
         params: {
           user: {
             email: @user.email,
             password: @good_password,
             otp_attempt: '000000'
           }
         }

    expect(warden_user).to be_nil
  end

  it 'rejects login when password is correct but OTP is missing' do
    skip 'Test assumes 2FA is enabled' if User.two_factor_auth_disabled

    post user_session_path,
         params: {
           user: {
             email: @user.email,
             password: @good_password
           }
         }

    expect(warden_user).to be_nil
  end
end
