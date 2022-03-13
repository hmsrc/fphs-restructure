require 'rails_helper'
require './app-scripts/supporting/admin_setup'

describe Admin do
  include ModelSupport
  before(:each) do
    ENV['FPHS_ADMIN_SETUP'] = 'yes'
    @admin, @good_password = create_admin 'test-admin'
    @good_email = @admin.email
  end

  it 'creates a admin' do
    new_admin = Admin.where email: @good_email
    expect(new_admin.first).to be_a Admin
  end

  it 'allows password change' do
    @admin.password = @good_password + '&&!'
    expect(@admin.save).to be true
  end

  it 'prevents own email address change by admin' do
    @admin.email = 'testadmin-change@testing.com'
    @admin.current_admin = @admin
    expect(@admin.save).to be false
  end

  it 'prevents admin disabled from authenticating' do
    create_admin
    @admin.disable!

    expect(@admin.active_for_authentication?).to be false
  end

  it 'prevent admin changing disabled flag outside of setup, except to disable' do
    allow(@admin).to receive(:can_manage_admins?).and_return(false)
    expect(@admin.disabled).to eq false

    # Can change nil or to false or vice versa
    @admin.disabled = nil

    expect(@admin.save).to be true
    @admin.disabled = true
    expect(@admin.save).to be true
    @admin.disabled = false
    expect(@admin.save).to be false
  end

  describe 'OS-user resets password' do

    context 'when OS-users are allowed to execute a setup script' do
      before do
        allow(@admin).to receive(:can_manage_admins?).and_return(true)
        AdminSetup.setup @good_email
      end
      it 'is expected to update the admin password' do
        admin = Admin.find_by(email: @good_email)
        expect(admin.disable!).to be_truthy
      end
      it 'is expected to re-enable an admin' do
        admin = Admin.find_by(email: @good_email)
        admin.disable!
        admin.disabled = false
        expect(admin).to be_valid
      end
    end

    context 'when OS-users NOT allowed to execute a setup script' do
      # Now simulate re-enabling the user outside of the admin setup script
      it 'is expected to not re-enabled an admin' do
        res = AdminSetup.setup @good_email

        admin = Admin.find_by(email: @good_email)
        allow(admin).to receive(:can_manage_admins?).and_return(true)
        admin.disable!
        allow(admin).to receive(:can_manage_admins?).and_return(false)
        admin.disabled = false
        expect(admin).to_not be_valid
      end
    end
  end

  describe 'create admin in the app' do
    context 'when admins are allowed to manage admins' do
      before { allow(@admin).to receive(:can_manage_admins?).and_return(true) }
      it 'expects to create an admin' do
        admin, good_password = create_admin 'test-admin-by-app'
        expect(admin).to be_valid
      end

    end

    context 'when admins are NOT allowed to manage admins' do
      before { allow_any_instance_of(Admin).to receive(:can_manage_admins?).and_return(false) }
      it 'expects not to create an admin' do
        expect { create_admin }.to raise_error(/can only create admins in console/)
      end
    end
  end

  describe 'password reset' do
    before { allow(@admin).to receive(:can_manage_admins?).and_return(true) }
    it 'prevents an admin from reusing a recent password' do

      create_admin

      # Generate 7 new passwords - 0 to 6
      expect do
        7.times do |n|
          @admin.password = "#{@good_password} #{n}"
          @admin.save!
        end
      end.not_to raise_error

      @admin.password = "#{@good_password} 3"
      expect(@admin.save).to be false

      @admin.password = "#{@good_password} 1"
      expect(@admin.save).to be false

      @admin.password = "#{@good_password} 0"
      expect(@admin.save).to be true

      @admin.password = @good_password.to_s
      expect(@admin.save).to be true

      @admin.password = "#{@good_password} 1"
      expect(@admin.save).to be true

      @admin.password = "#{@good_password} 1"
      expect(@admin.save).to be false
    end
  end

  after :all do
    ENV['FPHS_ADMIN_SETUP'] = 'yes'
  end
end
