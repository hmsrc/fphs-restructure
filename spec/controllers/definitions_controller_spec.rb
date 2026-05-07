# frozen_string_literal: true

require 'rails_helper'

# Tests for DefinitionsController, which provides frontend definition lookups.
# The controller allows both users and admins to retrieve lists such as protocol_events,
# colleges, user_roles, etc. for use in typeahead and dropdown fields.
#
# Issue #1120: Tests for the user_roles endpoint used by the admin user roles typeahead field.
describe DefinitionsController, type: :controller do
  include MasterSupport
  include ControllerMacros

  describe 'when not authenticated' do
    it 'should require user login' do
      get :show, params:  { id: 'protocol_events' }, xhr: true
      expect(response).to have_http_status(302)
      expect(response).to redirect_to '/users/sign_in'
    end
  end

  describe 'when authenticated' do
    before_each_login_user
    before(:each) do
      @definitions_controller = DefinitionsController.new
    end

    it 'should get latest protocol_events' do
      get :show, params:  { id: 'protocol_events' }, xhr: true

      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).to be_a Array
      expect(j.length).to eq Classification::ProtocolEvent.enabled.length
    end

    it 'should not get an unexpected item' do
      get :show, params:  { id: 'new' }, xhr: true
      expect(response).to have_http_status(404)
    end
  end

  describe 'show that Brakeman security warning is not an issue' do
    before_each_login_user
    it 'attempts to force use of an invalid definition type' do
      get :show, params:  { id: 'addresses' }, xhr: true
      expect(response).to have_http_status(404)
      get :show, params:  { id: '&something' }, xhr: true
      expect(response).to have_http_status(404)
      get :show, params:  { id: '123654' }, xhr: true
      expect(response).to have_http_status(404)
    end
  end

  # Tests for the user_roles definitions endpoint - Issue #1120
  # The user_roles endpoint returns active role names for use in the admin user roles typeahead field.
  describe 'when authenticated as user - user_roles definitions' do
    before_each_login_user

    before(:each) do
      Rails.cache.clear
      @app_type = @user.app_type
      @some_admin = Admin.order(id: :desc).first
      @active_role_name = "active_role_#{SecureRandom.hex(4)}"
      Admin::UserRole.create!(
        user: @user,
        app_type: @app_type,
        role_name: @active_role_name,
        current_admin: @some_admin
      )
    end

    it 'returns an array of active role names via GET show' do
      get :show, params: { id: 'user_roles' }, xhr: true
      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).to be_a Array
      expect(j).to include(@active_role_name)
    end

    it 'returns user_roles data via POST create with names parameter' do
      post :create, params: { names: 'user_roles' }, xhr: true
      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).to be_a Hash
      expect(j['user_roles']).to be_a Array
      expect(j['user_roles']).to include(@active_role_name)
    end

    it 'does not include disabled role names in results' do
      Rails.cache.clear
      disabled_role_name = "disabled_role_#{SecureRandom.hex(4)}"
      Admin::UserRole.create!(
        user: @user,
        app_type: @app_type,
        role_name: disabled_role_name,
        current_admin: @some_admin
      )
      # Disable ALL roles with this name, including any template user copies created by save_template
      Admin::UserRole.where(role_name: disabled_role_name, app_type_id: @app_type.id).update_all(disabled: true)
      Rails.cache.clear

      get :show, params: { id: 'user_roles' }, xhr: true
      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).not_to include(disabled_role_name)
    end

    it 'filters role names by app_type_id' do
      get :show, params: { id: "user_roles-app_type_id+#{@app_type.id}" }, xhr: true
      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).to be_a Array
      expect(j).to include(@active_role_name)
    end
  end

  describe 'when authenticated as admin - user_roles definitions' do
    before_each_login_admin

    before(:each) do
      Rails.cache.clear
    end

    it 'admin can access user_roles definitions via GET show' do
      get :show, params: { id: 'user_roles' }, xhr: true
      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).to be_a Array
    end

    it 'admin can access user_roles definitions via POST create' do
      post :create, params: { names: 'user_roles' }, xhr: true
      expect(response).to have_http_status(:success)
      j = JSON.parse(response.body)
      expect(j).to be_a Hash
      expect(j['user_roles']).to be_a Array
    end
  end
end
