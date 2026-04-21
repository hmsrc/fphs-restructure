# frozen_string_literal: true

# Security regression coverage for admin reference data index authorization.
#
# This example documents current vulnerable behavior: the
# Admin::ReferenceDataController#index action is reachable by any authenticated
# user, even when that user does not have the view_data_reference capability.

require 'rails_helper'

RSpec.describe Admin::ReferenceDataController, type: :controller do
  include UserSupport

  before(:each) do
    @request.env['devise.mapping'] = Devise.mappings[:user]
    @user, = create_user

    @user = User.find(@user.id)
    @user.clear_has_access_to!

    sign_in @user
  end

  it 'allows a user without view_data_reference access to load index' do
    expect(@user.can?(:view_data_reference)).to be_nil

    get :index

    expect(response).not_to have_http_status(:unauthorized)
  end
end
