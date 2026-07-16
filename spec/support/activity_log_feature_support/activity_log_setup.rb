module ActivityLogSetup
  include ModelSupport

  # Most of the database items are set up in the DB seed. This method just allows for some additional
  # test specific items to be added
  def create_phone_log_config
    admin, = create_admin

    if Classification::GeneralSelection.enabled.where(item_type: 'activity_log__player_contact_phone_select_who').length >= 5

      gs = [
        ['Rob Standish', 'rob standish', 'activity_log__player_contact_phone_select_who'],
        ['Chris', 'chris', 'activity_log__player_contact_phone_select_who'],
        ['P Smith', 'p smith', 'activity_log__player_contact_phone_select_who'],
        ['Andy Morehouse', 'andy morehouse', 'activity_log__player_contact_phone_select_who']
      ]
      gs.each do |g|
        Classification::GeneralSelection.create!(name: g[0], value: g[2], item_type: g[2], current_admin: admin, disabled: false, create_with: true, edit_always: false, lock: true)
      end
    end

    setup_access :player_infos
    setup_access :trackers

    ActivityLog.active.each do |a|
      a.current_admin = admin
      a.update_tracker_events
    end

    # Ensure notes field always uses plain text, regardless of the app config
    # notes_field_format setting (which other specs may set to 'markdown').
    al = ActivityLog.active.where(name: 'Phone Log').first
    if al && al.extra_log_types.blank?
      al.update!(current_admin: admin, extra_log_types: <<~YAML)
        primary:
          field_options:
            notes:
              format: plain
        blank_log:
          field_options:
            notes:
              format: plain
      YAML
    end
  end
end
