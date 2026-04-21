# frozen_string_literal: true

# Security regression coverage for account-token exposure in admin action log payloads.
#
# AdminActionLogging stores object_instance.attributes as prev_value and new_value
# for admin updates. That captures single-use account takeover tokens when they are
# present on a user record, including unlock_token during admin unlock flows and
# confirmation_token on unconfirmed accounts.

require 'rails_helper'

RSpec.describe Admin::ManageUsersController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]

    @admin, = create_admin
    @target_user, = create_user

    sign_in @admin
  end

  it 'stores the previous unlock_token in admin action log payload when an admin unlocks an account' do
    seeded_unlock_token = SecureRandom.hex(12)
    @target_user.update_columns(
      locked_at: Time.current,
      failed_attempts: 10,
      unlock_token: seeded_unlock_token
    )

    patch :update,
          params: {
            id: @target_user.id,
            unlock_failed_attempts: '1',
            user: {
              email: @target_user.email,
              first_name: @target_user.first_name,
              last_name: @target_user.last_name
            }
          },
          format: :js

    expect(response).to have_http_status(:ok)

    log_entry = Admin::AdminActionLog.where(admin_id: @admin.id).order(:id).last
    expect(log_entry).to be_present
    expect(log_entry.prev_value['unlock_token']).to eq(seeded_unlock_token)
    expect(log_entry.new_value['unlock_token']).to be_nil
  end

  it 'stores confirmation_token in admin action log payload when an admin updates an unconfirmed user' do
    seeded_confirmation_token = SecureRandom.hex(12)
    @target_user.update_columns(
      confirmed_at: nil,
      confirmation_token: seeded_confirmation_token
    )

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
    expect(log_entry.prev_value['confirmation_token']).to eq(seeded_confirmation_token)
    expect(log_entry.new_value['confirmation_token']).to eq(seeded_confirmation_token)
  end
end