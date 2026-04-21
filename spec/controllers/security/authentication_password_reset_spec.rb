# frozen_string_literal: true

# Security regression coverage for password reset token handling.
#
# Verifies that the Devise password reset mechanism is secure at the model level:
# - Raw tokens are generated and stored as digests (not plaintext)
# - Tokens can be used to look up the correct user
# - Tokens are single-use (cleared after successful password reset)
# - Reuse of a consumed token is rejected
#
# These tests exercise the Devise Recoverable module directly, which is
# what the Devise::PasswordsController delegates to under the hood.

require 'rails_helper'

RSpec.describe 'Password Reset Token Security', type: :request do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @user, = create_user
  end

  it 'generates a hashed password reset token (not stored in plaintext)' do
    raw_token = @user.send(:set_reset_password_token)
    expect(raw_token).to be_present
    stored_digest = @user.reload.reset_password_token
    expect(stored_digest).to be_present
    # The stored value must be a digest, not the raw token
    expect(stored_digest).not_to eq(raw_token)
  end

  it 'finds the correct user when looking up by raw token' do
    raw_token = @user.send(:set_reset_password_token)

    found = User.with_reset_password_token(raw_token)
    expect(found).to eq(@user)
  end

  it 'does not find a user with a fabricated token' do
    @user.send(:set_reset_password_token)

    found = User.with_reset_password_token('fabricated-invalid-token')
    expect(found).to be_nil
  end

  it 'clears token after successful password reset via reset_password_by_token' do
    raw_token = @user.send(:set_reset_password_token)
    # Generate a password that will pass all validators
    new_password = "#{Devise.friendly_token.first(16)}!1Aa"

    result = User.reset_password_by_token(
      reset_password_token: raw_token,
      password: new_password,
      password_confirmation: new_password
    )

    expect(result.errors).to be_empty
    expect(result.reload.reset_password_token).to be_nil
  end

  it 'prevents token reuse after password has been changed' do
    raw_token = @user.send(:set_reset_password_token)
    first_password = "#{Devise.friendly_token.first(16)}!1Aa"

    # First reset succeeds
    User.reset_password_by_token(
      reset_password_token: raw_token,
      password: first_password,
      password_confirmation: first_password
    )

    second_password = "#{Devise.friendly_token.first(16)}!2Bb"

    # Second reset with same token fails
    result = User.reset_password_by_token(
      reset_password_token: raw_token,
      password: second_password,
      password_confirmation: second_password
    )

    expect(result.errors).not_to be_empty
    # Password should still be from the first reset, not the second
    @user.reload
    expect(@user.valid_password?(second_password)).to be false
  end
end
