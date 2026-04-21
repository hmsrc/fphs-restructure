# frozen_string_literal: true

# Security regression coverage for session handling.
#
# Verifies critical session security properties:
# - Session fixation: session ID changes after authentication
# - Session invalidation: signing out destroys the session
# - Expired accounts are rejected mid-session
# - API-only users cannot log in via the web UI
# - Expired passwords force logout on authentication
#
# These properties prevent attackers from hijacking sessions,
# replaying old sessions, or bypassing access restrictions.

require 'rails_helper'

RSpec.describe 'Session Security', type: :request do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @user, = create_user
  end

  describe 'Session fixation prevention' do
    it 'changes session ID after successful login' do
      skip 'Test assumes 2FA is enabled' if User.two_factor_auth_disabled

      # Get a session before login
      get new_user_session_path
      pre_login_session = session.id

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
      post_login_session = session.id

      # Session ID must change after authentication to prevent fixation
      expect(post_login_session).not_to eq(pre_login_session)
    end
  end

  describe 'Session invalidation on logout' do
    it 'destroys user session on sign out' do
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

      # Verify user is logged in
      expect(request.env['warden'].user(:user)).not_to be_nil

      # Sign out
      delete destroy_user_session_path

      # Verify session is destroyed
      expect(request.env['warden'].user(:user)).to be_nil
    end
  end

  describe 'Expired account rejection' do
    it 'rejects authentication for expired users' do
      # Expire the account
      @user.update_columns(expire_datetime: 1.day.ago)

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

      # Even with valid credentials, expired user should not be signed in
      expect(request.env['warden'].user(:user)).to be_nil
    end
  end

  describe 'API-only user web login prevention' do
    it 'rejects web login for API-only users' do
      @user.update!(current_admin: @admin, api_access_only: true)

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

      # API-only users should be rejected by the after_authentication hook
      expect(request.env['warden'].user(:user)).to be_nil
    end
  end

  describe 'Password expiration enforcement' do
    it 'rejects login when password has expired' do
      # Set password_updated_at far enough in the past to expire
      @user.update_columns(password_updated_at: (Settings::PasswordAgeLimit + 1).days.ago)

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

      # Expired password users should be logged out by the after_authentication hook
      expect(request.env['warden'].user(:user)).to be_nil
    end
  end

  describe 'Disabled account rejection' do
    it 'rejects login for disabled users' do
      @user.update!(current_admin: @admin, disabled: true)

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

      expect(request.env['warden'].user(:user)).to be_nil
    end
  end

  describe 'Account lockout after failed attempts' do
    it 'locks account after maximum failed login attempts' do
      max_attempts = Settings::PasswordMaxAttempts

      max_attempts.times do
        post user_session_path,
             params: {
               user: {
                 email: @user.email,
                 password: 'wrong-password',
                 otp_attempt: '000000'
               }
             }
      end

      @user.reload
      expect(@user.access_locked?).to be true
    end
  end
end
