# frozen_string_literal: true

# Security regression coverage for admin password hash exposure in admin action log payloads.
#
# AdminActionLogging stores object_instance.attributes as new_value on every create/update action.
# Admin::ManageAdminsController extends AdminController which includes AdminActionLogging.
# The 'admins' table, like 'users', contains:
#   - encrypted_password (bcrypt hash — enables offline password cracking)
#   - encrypted_otp_secret (encrypted TOTP seed — enables 2FA bypass if encryption key compromised)
#
# Even a benign update (e.g. changing an admin's first_name) causes these hashes to be persisted
# in Admin::AdminActionLog.new_value, giving anyone with audit log read access a crackable target.

require 'rails_helper'

RSpec.describe Admin::ManageAdminsController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]

    @admin, = create_admin
    # Create a second admin to be the update target
    @target_admin, = UserSupport.create_admin('target')

    sign_in @admin
  end

  it 'stores target admin encrypted_password hash in action log new_value after name update' do
    expect(@target_admin.encrypted_password).to be_present

    patch :update,
          params: {
            id: @target_admin.id,
            admin: {
              first_name: 'Updated',
              last_name: @target_admin.last_name
            }
          },
          format: :js

    expect(response).to have_http_status(:ok)

    log_entry = Admin::AdminActionLog.where(admin_id: @admin.id).order(:id).last
    expect(log_entry).to be_present
    # Full attribute hash including bcrypt hash is stored verbatim in the audit log
    expect(log_entry.new_value['encrypted_password']).to eq(@target_admin.encrypted_password)
  end

  it 'stores target admin encrypted_password hash in action log prev_value before update' do
    original_hash = @target_admin.encrypted_password
    expect(original_hash).to be_present

    patch :update,
          params: {
            id: @target_admin.id,
            admin: {
              first_name: 'Updated',
              last_name: @target_admin.last_name
            }
          },
          format: :js

    expect(response).to have_http_status(:ok)

    log_entry = Admin::AdminActionLog.where(admin_id: @admin.id).order(:id).last
    expect(log_entry).to be_present
    # The previous snapshot also stores the bcrypt hash
    expect(log_entry.prev_value['encrypted_password']).to eq(original_hash)
  end
end
