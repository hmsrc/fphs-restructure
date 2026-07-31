# frozen_string_literal: true

module UserSupport
  UserPrefix = 'g-ttuser-'
  UserDomain = 'testing.com'

  def self.get_next_factory_user(part = nil, extra = '', opt = {})
    return # unless part.nil? && extra.blank?

    FactoryHelper.get_next_factory_item(:user)
  end

  def self.generate_factory_users(count)
    count.times do |i|
      part = "f#{i}"
      good_email = generate_username("#{part}--")
      user = User.find_by(email: good_email)
      if user
        good_password = UserSupport.generate_user_password(user.email)
        user.disabled = false
        admin, = create_admin
        if user.changed?
          user.current_admin = admin
          user.save!
        end
      else
        user, good_password = FactoryHelper.factory.create_user(part, nil, skip_if_exists: true)
      end
      FactoryHelper.add(:user, [user, good_password])
    end
  end

  def self.get_next_factory_admin(part = nil, with_matching_user: false)
    return # unless part.nil?

    FactoryHelper.get_next_factory_item(:admin)
  end

  def self.generate_factory_admins(count)
    count.times do |i|
      part = "f#{i}"
      good_email = UserSupport.generate_adminname(part)
      admin = Admin.find_by(email: good_email)
      if admin
        good_password = UserSupport.generate_user_password(admin.email)
        admin.disabled = false
        admin.save! if admin.changed?
      else
        admin, good_password = create_admin(part)
      end
      FactoryHelper.add(:admin, [admin, good_password])
    end
  end

  def create_user(part = nil, extra = '', opt = {})
    start_time = Time.now

    if opt[:email]
      user = User.find_by(email: opt[:email])
      good_password = UserSupport.generate_user_password(user.email)
    else
      user, good_password = UserSupport.get_next_factory_user(part, extra, opt)
    end

    if @admin
      admin = @admin
    else
      admin, = create_admin
    end

    if user
      FactoryHelper.factory_hit(:user)
      if opt[:email]
        user.current_admin = admin
        user.email = opt[:email]
        user.save! if user.changed?
      end
    else
      new_user = true
      FactoryHelper.factory_miss(:user)

      if part.is_a? Hash
        opt = part
        part = nil
      end
      part ||= SecureRandom.hex(10)
      good_email = opt[:email] || UserSupport.generate_username("#{part}-#{extra}-")
      attr = {
        email: good_email, current_admin: admin, first_name: "fn#{part}", last_name: "ln#{part}",
        password: UserSupport.generate_user_password(good_email)
      }

      good_password = attr[:password] if opt[:with_password]

      user = User.create! attr
    end

    # Save a new password, as required to handle temp passwords
    unless opt[:no_password_change]
      user = User.find(user.id)
      user.current_admin = admin
      good_password = UserSupport.generate_user_password(user.email)
      if Settings::TwoFactorAuthDisabledForUser
        user.otp_required_for_login = false
        user.new_two_factor_auth_code = false
      else
        user.otp_required_for_login = true
        user.new_two_factor_auth_code = false
      end
      user.save!
    end

    if Settings::TwoFactorAuthDisabledForUser
      user.otp_required_for_login = false
      user.new_two_factor_auth_code = false
    else
      user.otp_required_for_login = true
      user.new_two_factor_auth_code = false
    end

    # Set confirmed for system tests
    user.confirmed_at ||= Time.now if respond_to?(:page) && !opt[:not_confirmed]
    user.save! if user.changed?

    raise 'Two factor setup required!' if user.two_factor_setup_required?

    @user_authentication_token = user.authentication_token

    # # Can't reload, as that doesn't clear non-db attributes
    user = User.find(user.id)

    app_type = opt[:app_type] || @user&.app_type || Admin::AppType.active.first
    raise 'No active app type!' unless app_type

    unless opt[:no_app_type_setup]
      uac = Admin::UserAccessControl.find_or_initialize_by(
        user:, app_type:, resource_type: :general,
        resource_name: :app_type
      )
      unless uac.access == :read && uac.disabled == user.disabled
        uac.update! access: :read, current_admin: admin, disabled: user.disabled
      end
    end

    # Set a default app_type to use to allow non-interactive tests to continue
    if user.app_type != app_type
      user.app_type = app_type
      user.save!
    end

    if opt[:create_master]
      uac = Admin::UserAccessControl.find_or_initialize_by(
        app_type:, resource_type: :general,
        resource_name: :create_master, user:
      )

      unless uac.access == :read && uac.disabled == user.disabled
        uac.update!(access: :read, current_admin: @admin, disabled: user.disabled)
      end
    end
    @user = user
    @good_email = user.email
    @good_password = good_password
    let_user_create :player_contacts

    delay = Time.now - start_time
    puts "create_user took #{delay} seconds" if delay > 2.seconds

    [user, good_password]
  end

  #
  # Generates a test password based on the email address, so that it can be regenerated later if needed
  def self.generate_user_password(good_email)
    Digest::SHA256.hexdigest(good_email)
  end

  def grant_user_app_access(user, app_type = nil)
    app_type = app_type || user&.app_type || Admin::AppType.active.first
    raise 'No app type set' unless app_type

    uac = Admin::UserAccessControl.find_or_initialize_by(
      app_type:, resource_type: :general,
      resource_name: :app_type, user:
    )

    return if uac.access == :read && uac.disabled == user.disabled

    uac.update!(access: :read, current_admin: @admin, disabled: user.disabled)
  end

  def self.generate_adminname(part)
    "e-testadmin-tester#{part}@testing.com"
  end

  def self.create_admin(part = nil, with_matching_user: false)
    admin, good_admin_password = get_next_factory_admin(part, with_matching_user: with_matching_user)
    if admin
      FactoryHelper.factory_hit(:admin)
    else
      new_admin = true
      FactoryHelper.factory_miss(:admin)

      part ||= SecureRandom.hex(10)
      good_admin_email = UserSupport.generate_adminname(part)

      admin = Admin.create! email: good_admin_email

      # Save a new password, as required to handle temp passwords
      admin = Admin.find(admin.id)
      good_admin_password = UserSupport.generate_user_password(admin.email)
      # admin.generate_password
    end

    # Only set up 2FA if it's not disabled
    unless Admin.two_factor_auth_disabled
      admin.otp_secret = Admin.generate_otp_secret
      admin.otp_required_for_login = true
      admin.new_two_factor_auth_code = false
    end

    admin.disabled = false if admin.disabled
    admin.save! if admin.changed?

    # # Can't reload, as that doesn't clear non-db attributes
    admin = Admin.find(admin.id)

    if with_matching_user

      attr = {
        email: admin.email, current_admin: admin, first_name: admin.first_name, last_name: admin.last_name
      }
      good_password = attr[:password] = good_admin_password
      attr[:disabled] = false
      user = User.find_by(email: admin.email)
      if user
        User.update! attr
      else
        user = User.create attr
      end
      raise 'Not a user' unless user.is_a?(User)
      raise "User email #{user.email} does not match admin email #{admin.email}" unless user.email == admin.email
    end

    [admin, good_admin_password]
  end

  def create_admin(part = nil, with_matching_user: false)
    admin, good_admin_password = UserSupport.create_admin(part)
    @admin = admin
    admin_email = admin.email

    if with_matching_user
      user, good_user_password = create_user(nil, nil, email: admin_email)
      expect(user).to be_a User
      expect(user.email).to eq admin_email
      @user = user
    end

    @admin = admin
    [admin, good_admin_password]
  end

  def create_user_role(role_name, user: nil, app_type: nil)
    user ||= @user
    app_type ||= user.app_type
    Admin::UserRole.create! current_admin: @admin, app_type:, role_name:, user:
  end

  def self.generate_username(part)
    "#{UserPrefix}#{part}@#{UserDomain}"
  end

  #
  # Enable access to an app type for a user (or default @user)
  # @param [String | Integer | Admin::AppType] app_type - name, id or AppType
  # @param [User] user - optional user or default will be @user
  # @return [Admin::UserAccessControl]
  def enable_user_app_access(app_type, user = nil)
    user ||= @user

    case app_type
    when String
      app_type = Admin::AppType.where(name: app_type).first
    when Integer
      app_type = Admin::AppType.find(app_type)
    end

    res = user.has_access_to?(:access, :general, :app_type, alt_app_type_id: app_type.id)
    return res if res

    res = setup_access(:app_type, resource_type: :general, access: :read, user:, app_type:)
    expect(user.has_access_to?(:access, :general, :app_type, alt_app_type_id: app_type.id))
    res
  end

  def setup_access(resource_name = nil, resource_type: :table, access: :create, user: nil, app_type: nil)
    return if @path_prefix == '/admin'

    resource_name ||= objects_symbol

    unless resource_name
      Rails.logger.warn "No resource name for #{resource_type} - #{self.class}"
      Rails.logger.warn ExceptionExtensions.short_string_backtrace(caller)

      return
    end

    app_type ||= @user.app_type

    uac = Admin::UserAccessControl.where(app_type:, resource_type:, resource_name:, role_name: [nil, ''])
    uac = if user
            uac.where(user:)
          else
            uac.where(user_id: nil)
          end

    uac.active.update_all(disabled: true) if uac.active.length > 1
    uac = uac.active.first || uac.first
    admin = auto_admin
    admin.disabled = false
    if uac
      disabled = uac.user&.disabled # The UAC must be disabled if the user is disabled
      uac.access = access
      uac.disabled = disabled
      uac.current_admin = admin
      uac.updated_at = DateTime.now
      uac.save!
    else
      disabled = user&.disabled # The UAC must be disabled if the user is disabled
      uac = Admin::UserAccessControl.create! app_type:, access:, resource_type:,
                                             resource_name:, user:, current_admin: admin,
                                             disabled: disabled
    end

    if user && access && resource_name != :app_type
      check_access = (access == :see_presence ? access : :access)
      res = user.has_access_to?(check_access, resource_type, resource_name)
      expect(res).to be_truthy,
                     "Newly created User Access Control not working as expected: #{check_access}, #{resource_type}, #{resource_name}"
    end

    uac
  rescue StandardError => e
    puts "Failed to create access for #{resource_name}: #{e}"
    puts "resource_name needs to be one of:\n#{Admin::UserAccessControl.resource_names_for(resource_type.to_sym)}"
    puts "#{e}\n#{e.short_string_backtrace}"
    Rails.logger.info "Failed to create access for #{resource_name}"
  end

  def add_user_to_role(role_name, for_user: nil)
    for_user ||= @user
    Admin::UserRole.add_to_role for_user, for_user.app_type, role_name, @admin
  end

  def remove_user_from_role(role_name, for_user: nil)
    for_user ||= @user
    Admin::UserRole.remove_from_role for_user, for_user.app_type, role_name, @admin
  end

  def add_user_config(config_name, config_value, for_user: nil)
    for_user ||= @user
    Admin::AppConfiguration.add_user_config for_user, for_user.app_type, config_name, config_value, @admin
  end

  def remove_user_config(config_name, for_user: nil)
    for_user ||= @user
    Admin::AppConfiguration.remove_user_config for_user, for_user.app_type, config_name, @admin
  end

  def let_user_create_player_infos(in_app_type: nil)
    let_user_create :player_infos, in_app_type:
  end

  def let_user_create_player_contacts(in_app_type: nil)
    let_user_create :player_contacts, in_app_type:
  end

  def let_user_create(resource_name, in_app_type: nil, alt_user: nil)
    user = alt_user || @user
    res = user.has_access_to? :access, :table, resource_name
    if res && res.user_id == user.id
      # Find it, as the object is not actually a database record
      res = Admin::UserAccessControl.find(res.id)
      res.disabled = true
      res.current_admin = @admin
      res.save! unless res.disabled
    end

    in_app_type ||= user.app_type
    return unless in_app_type

    uac = Admin::UserAccessControl.find_or_initialize_by(
      app_type: in_app_type, user:,
      resource_type: :table, resource_name: resource_name
    )
    unless uac.access == :create && uac.disabled == user.disabled
      uac.update! access: :create, current_admin: @admin, disabled: user.disabled
    end
    uac
  end

  def revoke_user_create(resource_name, in_app_type: nil, alt_user: nil)
    user = alt_user || @user
    in_app_type ||= user.app_type
    res = user.has_access_to? :access, :table, resource_name, alt_app_type_id: in_app_type
    res = Admin::UserAccessControl.find(res.id)
    return unless res && res.user_id == user.id

    res.disabled = true
    res.current_admin = @admin
    res.save!
  end

  def validate_setup
    user = User.active.find_by(email: @good_email&.downcase)
    expect(user).to be_a User
    expect(user.id).to equal @user.id
    validate_scantron_setup
    validate_update_protocol_setup
  end

  def validate_update_protocol_setup
    expect(Classification::ProtocolEvent.active.reload.find_by(name: 'created player info')).not_to be nil
    expect(Classification::ProtocolEvent.active.reload.find_by(name: 'updated player info')).not_to be nil
    expect(Classification::ProtocolEvent.active.reload.find_by(name: 'created player contact')).not_to be nil
    expect(Classification::ProtocolEvent.active.reload.find_by(name: 'updated player contact')).not_to be nil
  end

  def validate_scantron_setup
    return if defined? Scantron

    puts 'Scantron was not defined!'
    Rails.logger.warn 'Scantron was not defined!'
    seed_database
    return if defined? Scantron

    m = Resources::Models.find_by(resource_name: 'scantrons')
    r = ExternalIdentifier.active.where(name: 'scantron').count
    Rails.logger.warn m
    Rails.logger.warn r
    raise FphsException, "Scantron is still not defined, even after seeding: \n#{m}\n#{r}"
  end
end
