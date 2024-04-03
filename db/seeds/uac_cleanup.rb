module Seeds
  module UacCleanup
    def self.setup
      log "In #{self}.setup"

      Admin::UserAccessControl.active.where(role_name: '').update_all(role_name: nil)
      ActivityLog.active.where(process_name: '').update_all(process_name: nil)
    end
  end
end
