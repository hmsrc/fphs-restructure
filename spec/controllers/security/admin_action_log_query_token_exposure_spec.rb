# frozen_string_literal: true

# Security regression coverage for URL token leakage into admin action logs.
#
# This example documents current vulnerable behavior: admin controllers persist
# request.original_fullpath into Admin::AdminActionLog, which includes query
# parameters such as user_token when present.

require 'rails_helper'

RSpec.describe Admin::ManageUsersController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:admin]

    @admin, = create_admin
    @target_user, = create_user

    sign_in @admin
  end

  it 'stores user_token query parameter in admin action log url' do
    sensitive_token = SecureRandom.hex(16)
    @request.env['QUERY_STRING'] = "user_token=#{sensitive_token}"

    patch :update,
          params: {
            id: @target_user.id,
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
    expect(log_entry.url).to include('user_token=')
    expect(log_entry.url).to include(sensitive_token)
  end
end