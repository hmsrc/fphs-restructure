# frozen_string_literal: true

# Security regression coverage for sensitive credential exposure in admin action log payloads.
#
# AdminActionLogging stores object_instance.attributes as new_value (and prev_value before update).
# The users table contains:
#   - encrypted_password (bcrypt hash - enables offline password cracking attacks)
#   - encrypted_otp_secret (encrypted TOTP seed - combined with app key allows 2FA bypass)
#   - reset_password_token, unlock_token, confirmation_token (single-use account takeover tokens)
#
# All of these are persisted verbatim in Admin::AdminActionLog.new_value and prev_value on every
# admin update of a user record, exposing them to anyone with read access to the audit log table.

require 'rails_helper'

RSpec.describe Admin::ManageUsersController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]

    @admin, = create_admin
    @target_user, = create_user

    sign_in @admin
  end

  it 'stores bcrypt password hash in admin action log new_value payload' do
    # Verify the user has a password hash (they always will)
    expect(@target_user.encrypted_password).to be_present

    patch :update,
          params: {
            id: @target_user.id,
            user: {
              email: @target_user.email,
              first_name: @target_user.first_name,
              last_name: "#{@target_user.last_name}-updated"
            }
          },
          format: :js

    expect(response).to have_http_status(:ok)

    log_entry = Admin::AdminActionLog.where(admin_id: @admin.id).order(:id).last
    expect(log_entry).to be_present
    # The bcrypt password hash is stored verbatim in the audit log
    expect(log_entry.new_value['encrypted_password']).to eq(@target_user.encrypted_password)
  end

  it 'stores bcrypt password hash in admin action log prev_value before update' do
    original_password_hash = @target_user.encrypted_password
    expect(original_password_hash).to be_present

    patch :update,
          params: {
            id: @target_user.id,
            user: {
              email: @target_user.email,
              first_name: @target_user.first_name,
              last_name: "#{@target_user.last_name}-updated"
            }
          },
          format: :js

    expect(response).to have_http_status(:ok)

    log_entry = Admin::AdminActionLog.where(admin_id: @admin.id).order(:id).last
    expect(log_entry).to be_present
    # The previous bcrypt hash is also captured before the update
    expect(log_entry.prev_value['encrypted_password']).to eq(original_password_hash)
  end
end
