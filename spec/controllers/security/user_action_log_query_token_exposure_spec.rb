# frozen_string_literal: true

# Security regression coverage for URL token leakage into user action logs.
#
# This example documents current vulnerable behavior: user-facing controllers
# persist request.original_fullpath into Admin::UserActionLog, which includes
# query parameters such as user_token when API-style authentication is used.

require 'rails_helper'

RSpec.describe MastersController, type: :controller do
  include UserSupport
  include MasterSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]

    @admin, = create_admin
    @user, = create_user
    @master = create_master(@user)

    sign_in @user
  end

  it 'stores user_token query parameter in user action log url' do
    get :show,
        params: {
          id: @master.id,
          user_token: @user.authentication_token
        },
        format: :json

    expect(response).to have_http_status(:ok)

    log_entry = Admin::UserActionLog.where(user_id: @user.id).order(:id).last
    expect(log_entry).to be_present
    expect(log_entry.url).to include('user_token=')
    expect(log_entry.url).to include(@user.authentication_token)
  end
end