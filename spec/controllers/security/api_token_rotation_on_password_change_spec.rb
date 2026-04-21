# frozen_string_literal: true

# Security regression coverage for API token rotation on password change.
#
# When a user changes their password, the authentication_token (API token) should
# be rotated to prevent a compromised token from remaining valid after the user
# secures their account. Currently, handle_password_change clears unlock-related
# fields but does NOT rotate the authentication_token.
#
# This spec documents and verifies the current (insecure) behavior so that once
# the fix is applied, the expectations can be updated to reflect the secure state.

require 'rails_helper'

RSpec.describe 'API token rotation on password change', type: :model do
  include UserSupport

  before(:each) do
    @admin, = create_admin
    @user, = create_user
  end

  it 'stores authentication_token as a plain string column (not hashed)' do
    # The authentication_token column is a plain varchar — tokens are stored in cleartext.
    # This test documents that reality; a future fix should hash the token.
    token = @user.authentication_token
    expect(token).to be_present

    raw_db_token = User.where(id: @user.id).pick(:authentication_token)
    expect(raw_db_token).to eq(token), 'Token is stored in plaintext in the database'
  end

  it 'does NOT rotate the authentication_token when a user changes their password' do
    # CURRENT BEHAVIOR (insecure): token survives a password change.
    # When fixed, change the final expectation to `not_to eq(token_before)`.
    token_before = @user.authentication_token
    expect(token_before).to be_present

    new_password = "N3wSecur3P@ss!#{SecureRandom.hex(4)}"
    @user.password = new_password
    @user.password_confirmation = new_password
    @user.save!

    @user.reload
    token_after = @user.authentication_token

    # This expectation documents the INSECURE status quo:
    # The token is NOT rotated on password change.
    expect(token_after).to eq(token_before),
                           'API token should be rotated on password change but currently is not'
  end

  it 'clears lockout fields but not the API token on password change' do
    # Lock the account first
    @user.update_columns(
      locked_at: Time.current,
      failed_attempts: 10,
      unlock_token: SecureRandom.hex(12)
    )

    token_before = @user.authentication_token
    expect(token_before).to be_present

    new_password = "An0therS3cur3!#{SecureRandom.hex(4)}"
    @user.password = new_password
    @user.password_confirmation = new_password
    @user.save!

    @user.reload

    # Lockout fields are correctly cleared
    expect(@user.locked_at).to be_nil
    expect(@user.failed_attempts).to eq(0)
    expect(@user.unlock_token).to be_nil

    # But the API token remains unchanged (insecure)
    expect(@user.authentication_token).to eq(token_before),
                                          'API token should be rotated alongside lockout reset'
  end
end
