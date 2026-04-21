# frozen_string_literal: true

# Security regression coverage for credential exposure in admin action log payloads.
#
# This example documents current vulnerable behavior: AdminActionLogging stores
# object_instance.attributes as new_value, which includes User.authentication_token
# when admins update user records.

require 'rails_helper'

RSpec.describe Admin::ManageUsersController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]

    @admin, = create_admin
    @target_user, = create_user

    sign_in @admin
  end

  it 'stores updated user authentication_token in admin action log payload' do
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
    expect(log_entry.new_value['authentication_token']).to eq(@target_user.authentication_token)
  end
end