class FixLogUserUpdateFn < ActiveRecord::Migration[7.2]
  def down 
    cols = ActiveRecord::Base.connection.columns('user_history').map(&:name)
    add_column :user_history, :expire_datetime, :timestamp if cols.include?('expire_datetime')
    add_column :user_history, :api_access_only, :boolean if cols.include?('api_access_only')

  end

  def up

    cols = ActiveRecord::Base.connection.columns('user_history').map(&:name)
    add_column :user_history, :expire_datetime, :timestamp unless cols.include?('expire_datetime')
    add_column :user_history, :api_access_only, :boolean unless cols.include?('api_access_only')

    execute <<~SQL
      CREATE OR REPLACE FUNCTION ml_app.log_user_update()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $function$
      BEGIN
        INSERT INTO user_history
        (
            user_id,
            email,
            encrypted_password,
            reset_password_token,
            reset_password_sent_at,
            remember_created_at,
            sign_in_count,
            current_sign_in_at,
            last_sign_in_at,
            current_sign_in_ip ,
            last_sign_in_ip ,
            created_at,
            updated_at,
            failed_attempts,
            unlock_token,
            locked_at,
            disabled,
            admin_id,
            app_type_id,
            authentication_token,
            consumed_timestep,
            otp_required_for_login,
            password_updated_at,
            first_name,
            last_name,
            confirmation_token,
            confirmed_at,
            confirmation_sent_at,
            do_not_email,
            country_code,
            terms_of_use_accepted,
            otp_secret,
            expire_datetime,
            api_access_only
        )
        SELECT
          NEW.id,
          NEW.email,
          NEW.encrypted_password,
          NEW.reset_password_token,
          NEW.reset_password_sent_at,
          NEW.remember_created_at,
          NEW.sign_in_count,
          NEW.current_sign_in_at,
          NEW.last_sign_in_at,
          NEW.current_sign_in_ip ,
          NEW.last_sign_in_ip ,
          NEW.created_at ,
          NEW.updated_at,
          NEW.failed_attempts,
          NEW.unlock_token,
          NEW.locked_at,
          NEW.disabled ,
          NEW.admin_id,
          NEW.app_type_id,
          NEW.authentication_token,
          NEW.consumed_timestep,
          NEW.otp_required_for_login,
          NEW.password_updated_at,
          NEW.first_name,
          NEW.last_name,
          NEW.confirmation_token,
          NEW.confirmed_at,
          NEW.confirmation_sent_at,
          NEW.do_not_email,
          NEW.country_code,
          NEW.terms_of_use_accepted,
          NEW.otp_secret,
          NEW.expire_datetime,
          NEW.api_access_only
        ;
        RETURN NEW;
        END;
        $function$
      ;
    SQL
  end
end
