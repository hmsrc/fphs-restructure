begin;
--
-- PostgreSQL database dump
--

-- Dumped from database version 15.6
-- Dumped by pg_dump version 15.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ml_app; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ml_app;


--
-- Name: SCHEMA ml_app; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA ml_app IS 'The primary Zeus application, player contact and tracking schema';


--
-- Name: ref_data; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ref_data;


--
-- Name: activity_log_bhs_assignment_info_request_notification(integer); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.activity_log_bhs_assignment_info_request_notification(activity_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
    DECLARE
        dl_users INTEGER[];
        activity_record RECORD;
        message_id INTEGER;
        current_app_type_id INTEGER;
    BEGIN

        current_app_type_id := get_app_type_id_by_name('bhs');

        dl_users := get_user_ids_for_app_type_role(current_app_type_id, 'pi');

        SELECT * INTO activity_record FROM activity_log_bhs_assignments WHERE id = activity_id;

        IF activity_record.bhs_assignment_id IS NOT NULL AND activity_record.extra_log_type = 'primary'
        THEN

          SELECT
          INTO message_id
            create_message_notification_email(
              current_app_type_id,
              activity_record.master_id,
              activity_record.id,
              'ActivityLog::BhsAssignment'::VARCHAR,
              activity_record.user_id,
              dl_users,
              'bhs notification layout'::VARCHAR,
              'bhs pi notification content'::VARCHAR,
              'New Brain Health Study Info Request'::VARCHAR,
              now()::TIMESTAMP
            )
          ;

        END IF;
        RETURN message_id;
    END;
$$;


--
-- Name: activity_log_bhs_assignment_insert_defaults(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.activity_log_bhs_assignment_insert_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        DECLARE
          found_bhs RECORD;
          found_phone RECORD;
        BEGIN

            -- if there is no player contact phone set, try and set it
            -- in case the sync from Zeus to Elaine happened between the time the
            -- user opened the new form (with an empty drop down) and now.
            -- This avoids missing the population of this field
            IF NEW.select_record_from_player_contact_phones IS NULL THEN
              SELECT * FROM player_contacts
              INTO found_phone
              WHERE master_id = NEW.master_id AND rec_type = 'phone'
              ORDER BY rank desc
              LIMIT 1;

              IF found_phone.data is not null THEN
                NEW.select_record_from_player_contact_phones := found_phone.data;
              END IF;

            END IF;


            -- Generate the testmybrain URL from the BHS ID
            select * from bhs_assignments
            into found_bhs
            where master_id = NEW.master_id
            limit 1;


            IF found_bhs.bhs_id is not null THEN
              NEW.results_link := ('https://testmybrain.org?demotestid=' || found_bhs.bhs_id::varchar);
            END IF;
            RETURN NEW;
        END;
    $$;


--
-- Name: activity_log_bhs_assignment_insert_notification(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.activity_log_bhs_assignment_insert_notification() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      message_id INTEGER;
      to_user_ids INTEGER[];
      num_primary_logs INTEGER;
      current_app_type_id INTEGER;
  BEGIN

        current_app_type_id := get_app_type_id_by_name('bhs');

        IF NEW.extra_log_type = 'contact_initiator' THEN

            -- Get the most recent info request from the activity log records for this master_id
            -- This gives us the user_id of the initiator of the request
            select array_agg(user_id)
            into to_user_ids
            from
            (select user_id
            from activity_log_bhs_assignments
            where
              master_id = NEW.master_id
              and extra_log_type = 'primary'
            order by id desc
            limit 1) t;

            -- If nobody was set, send to all users in the RA role
            IF to_user_ids IS NULL THEN
              to_user_ids := get_user_ids_for_app_type_role(current_app_type_id, 'ra');
            END IF;

            SELECT
            INTO message_id
              create_message_notification_email(
                current_app_type_id,
                NEW.master_id,
                NEW.id,
                'ActivityLog::BhsAssignment'::VARCHAR,
                NEW.user_id,
                to_user_ids,
                'bhs notification layout'::VARCHAR,
                'bhs message notification content'::VARCHAR,
                'Brain Health Study contact from PI'::VARCHAR,
                now()::TIMESTAMP
              )
            ;

            RETURN NEW;
        END IF;

        IF NEW.extra_log_type = 'respond_to_pi' THEN

            -- Get the most recent contact_initiator from the activity log records for this master_id
            -- This gives us the user_id of the PI making the Contact RA request
            select array_agg(user_id)
            into to_user_ids
            from
            (select user_id
            from activity_log_bhs_assignments
            where
              master_id = NEW.master_id
              and extra_log_type = 'contact_initiator'
            order by id desc
            limit 1) t;

            -- If nobody was set, send to all users in the PI role
            IF to_user_ids IS NULL THEN
              to_user_ids := get_user_ids_for_app_type_role(current_app_type_id, 'pi');
            END IF;


            SELECT
            INTO message_id
              create_message_notification_email(
                current_app_type_id,
                NEW.master_id,
                NEW.id,
                'ActivityLog::BhsAssignment'::VARCHAR,
                NEW.user_id,
                to_user_ids,
                'bhs notification layout'::VARCHAR,
                'bhs message notification content'::VARCHAR,
                'Brain Health Study contact from RA'::VARCHAR,
                now()::TIMESTAMP
              );

            RETURN NEW;
        END IF;

        -- If this is a primary type (info request), and there are already
        -- info request activities for this master
        -- then send another info request notification
        -- Don't do this otherwise, since the sync process is responsible for notifications
        -- related to the initial info request only when the sync has completed
        IF NEW.extra_log_type = 'primary' THEN
          SELECT count(id)
          INTO num_primary_logs
          FROM activity_log_bhs_assignments
          WHERE master_id = NEW.master_id AND id <> NEW.id AND extra_log_type = 'primary';

          IF num_primary_logs > 0 THEN
            PERFORM activity_log_bhs_assignment_info_request_notification(NEW.id);
          END IF;
        END IF;


        RETURN NEW;
    END;
$$;


--
-- Name: add_study_update_entry(integer, character varying, character varying, date, character varying, integer, integer, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.add_study_update_entry(master_id integer, update_type character varying, update_name character varying, event_date date, update_notes character varying, user_id integer, item_id integer, item_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
        DECLARE
          new_tracker_id integer;
          protocol_record RECORD;
        BEGIN
        
          SELECT add_tracker_entry_by_name(master_id, 'Updates', 'record updates', (update_type || ' ' || update_name), event_date, update_notes, user_id, item_id, item_type) into new_tracker_id;
          /*
          SELECT p.id protocol_id, sp.id sub_process_id, pe.id protocol_event_id 
          INTO protocol_record           
          FROM protocol_events pe 
          INNER JOIN sub_processes sp on pe.sub_process_id = sp.id 
          INNER JOIN protocols p on sp.protocol_id = p.id
          WHERE p.name = 'Updates' 
          AND sp.name = 'record updates' 
          AND pe.name = (update_type || ' ' || update_name) 
          AND (p.disabled IS NULL or p.disabled = FALSE) AND (sp.disabled IS NULL or sp.disabled = FALSE) AND (pe.disabled IS NULL or pe.disabled = FALSE);

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Nonexistent protocol record --> %', (update_type || ' ' || update_name );
          ELSE

            INSERT INTO trackers 
            (master_id, protocol_id, sub_process_id, protocol_event_id, item_type, item_id, user_id, event_date, updated_at, created_at, notes)
            VALUES
            (master_id, protocol_record.protocol_id, protocol_record.sub_process_id, protocol_record.protocol_event_id, 
             item_type, item_id, user_id, now(), now(), now(), update_notes);                        

            RETURN new_tracker_id;
          END IF;
          */  
          RETURN new_tracker_id;
        END;   
    $$;


--
-- Name: add_tracker_entry_by_name(integer, character varying, character varying, character varying, character varying, integer, integer, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.add_tracker_entry_by_name(master_id integer, protocol_name character varying, sub_process_name character varying, protocol_event_name character varying, set_notes character varying, user_id integer, item_id integer, item_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
        DECLARE
          new_tracker_id integer;
          protocol_record RECORD;
        BEGIN

          
          SELECT p.id protocol_id, sp.id sub_process_id, pe.id protocol_event_id 
          INTO protocol_record           
          FROM protocol_events pe 
          INNER JOIN sub_processes sp on pe.sub_process_id = sp.id 
          INNER JOIN protocols p on sp.protocol_id = p.id
          WHERE p.name = protocol_name
          AND sp.name = sub_process_name 
          AND pe.name = protocol_event_name
          AND (p.disabled IS NULL or p.disabled = FALSE) AND (sp.disabled IS NULL or sp.disabled = FALSE) AND (pe.disabled IS NULL or pe.disabled = FALSE);

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Nonexistent protocol record --> %', (protocol_name || ' ' || sub_process_name || ' ' || protocol_event_name);
          ELSE

            INSERT INTO trackers 
            (master_id, protocol_id, sub_process_id, protocol_event_id, item_type, item_id, user_id, event_date, updated_at, created_at, notes)
            VALUES
            (master_id, protocol_record.protocol_id, protocol_record.sub_process_id, protocol_record.protocol_event_id, 
             item_type, item_id, user_id, now(), now(), now(), set_notes);                        

            RETURN new_tracker_id;
          END IF;
            
        END;   
    $$;


--
-- Name: add_tracker_entry_by_name(integer, character varying, character varying, character varying, date, character varying, integer, integer, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.add_tracker_entry_by_name(master_id integer, protocol_name character varying, sub_process_name character varying, protocol_event_name character varying, event_date date, set_notes character varying, user_id integer, item_id integer, item_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
        DECLARE
          new_tracker_id integer;
          protocol_record RECORD;
        BEGIN

          
          SELECT p.id protocol_id, sp.id sub_process_id, pe.id protocol_event_id 
          INTO protocol_record           
          FROM protocol_events pe 
          INNER JOIN sub_processes sp on pe.sub_process_id = sp.id 
          INNER JOIN protocols p on sp.protocol_id = p.id
          WHERE lower(p.name) = lower(protocol_name)
          AND lower(sp.name) = lower(sub_process_name) 
          AND lower(pe.name) = lower(protocol_event_name)
          AND (p.disabled IS NULL or p.disabled = FALSE) AND (sp.disabled IS NULL or sp.disabled = FALSE) AND (pe.disabled IS NULL or pe.disabled = FALSE);

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Nonexistent protocol record --> %', (protocol_name || ' ' || sub_process_name || ' ' || protocol_event_name);
          ELSE

            INSERT INTO trackers 
            (master_id, protocol_id, sub_process_id, protocol_event_id, item_type, item_id, user_id, event_date, updated_at, created_at, notes)
            VALUES
            (master_id, protocol_record.protocol_id, protocol_record.sub_process_id, protocol_record.protocol_event_id, 
             item_type, item_id, user_id, now(), now(), now(), set_notes);                        

            RETURN new_tracker_id;
          END IF;
            
        END;   
    $$;


--
-- Name: assign_sage_ids_to_players(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.assign_sage_ids_to_players() RETURNS record
    LANGUAGE plpgsql
    AS $$
      DECLARE
        min_sa integer;
        max_sa integer;
        res record;
      BEGIN

        -- update the precreated Sage ID records with the master_id from the player info, based on matching ID. 
        -- apply an offset here if the Sage ID does not start at zero
        -- find the first unassigned Sage ID
        select min(id) into min_sa from sage_assignments where master_id is null;
        -- update the sage assignments in a block starting from the minimum unassigned ID
        update sage_assignments sa set master_id = (select master_id from temp_pit where id = sa.id - min_sa) where sa.master_id is null and sa.id >= min_sa;
        -- get the max value to return the results
        select max(id) into max_sa from sage_assignments where master_id is not null;
        select min_sa, max_sa into res;
        return res;

       END;
    $$;


--
-- Name: create_all_remote_bhs_records(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_all_remote_bhs_records() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
bhs_record RECORD;
BEGIN

FOR bhs_record IN
  SELECT * from temp_bhs_assignments
LOOP

PERFORM create_remote_bhs_record(
bhs_record.bhs_id,
(SELECT (pi::varchar)::player_infos FROM temp_player_infos pi WHERE master_id = bhs_record.master_id LIMIT 1),
ARRAY(SELECT distinct (pc::varchar)::player_contacts FROM temp_player_contacts pc WHERE master_id = bhs_record.master_id)
);

END LOOP;

return 1;

END;
$$;


--
-- Name: create_all_remote_sleep_records(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_all_remote_sleep_records() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	sleep_record RECORD;
BEGIN

	FOR sleep_record IN
	  SELECT * from temp_sleep_assignments
	LOOP

		PERFORM create_remote_sleep_record(
			sleep_record.sleep_id::BIGINT,
			(SELECT (pi::varchar)::player_infos FROM temp_player_infos pi WHERE master_id = sleep_record.master_id LIMIT 1),
			ARRAY(SELECT distinct (pc::varchar)::player_contacts FROM temp_player_contacts pc WHERE master_id = sleep_record.master_id),
			ARRAY(SELECT distinct (a::varchar)::addresses FROM temp_addresses a WHERE master_id = sleep_record.master_id)
		);

	END LOOP;

	return 1;

END;
$$;


--
-- Name: create_all_remote_tbs_records(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_all_remote_tbs_records() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	tbs_record RECORD;
BEGIN

	FOR tbs_record IN
	  SELECT * from temp_tbs_assignments
	LOOP

		PERFORM create_remote_tbs_record(
			tbs_record.tbs_id::BIGINT,
			(SELECT (pi::varchar)::player_infos FROM temp_player_infos pi WHERE master_id = tbs_record.master_id LIMIT 1),
			ARRAY(SELECT distinct (pc::varchar)::player_contacts FROM temp_player_contacts pc WHERE master_id = tbs_record.master_id),
			ARRAY(SELECT distinct (a::varchar)::addresses FROM temp_addresses a WHERE master_id = tbs_record.master_id)
		);

	END LOOP;

	return 1;

END;
$$;


--
-- Name: create_all_remote_test_baseline_study_records(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_all_remote_test_baseline_study_records() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	test_baseline_study_record RECORD;
BEGIN

	FOR test_baseline_study_record IN
	  SELECT * from temp_test_baseline_study_assignments
	LOOP

		PERFORM create_remote_test_baseline_study_record(
			test_baseline_study_record.test_baseline_study_id::BIGINT,
			(SELECT (pi::varchar)::player_infos FROM temp_player_infos pi WHERE master_id = test_baseline_study_record.master_id LIMIT 1),
			ARRAY(SELECT distinct (pc::varchar)::player_contacts FROM temp_player_contacts pc WHERE master_id = test_baseline_study_record.master_id),
			ARRAY(SELECT distinct (a::varchar)::addresses FROM temp_addresses a WHERE master_id = test_baseline_study_record.master_id)
		);

	END LOOP;

	return 1;

END;
$$;


--
-- Name: create_message_notification_email(character varying, character varying, character varying, json, character varying[], character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_message_notification_email(layout_template_name character varying, content_template_name character varying, subject character varying, data json, recipient_emails character varying[], from_user_email character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  last_id INTEGER;
BEGIN

  INSERT INTO ml_app.message_notifications
  (
    message_type,
    created_at,
    updated_at,
    layout_template_name,
    content_template_name,
    subject,
    data,
    recipient_emails,
    from_user_email
  )
  VALUES
  (
    'email',
    now(),
    now(),
    layout_template_name,
    content_template_name,
    subject,
    data,
    recipient_emails,
    from_user_email
  )
  RETURNING id
  INTO last_id
  ;

  SELECT create_message_notification_job(last_id)
  INTO last_id
  ;

  RETURN last_id;
END;
$$;


--
-- Name: create_message_notification_email(character varying, character varying, character varying, json, character varying[], character varying, timestamp without time zone); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_message_notification_email(layout_template_name character varying, content_template_name character varying, subject character varying, data json, recipient_data character varying[], from_user_email character varying, run_at timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql
    AS $$
    DECLARE
      last_id INTEGER;
    BEGIN

      IF run_at IS NULL THEN
        run_at := now();
      END IF;

      INSERT INTO ml_app.message_notifications
      (
        message_type,
        created_at,
        updated_at,
        layout_template_name,
        content_template_name,
        subject,
        data,
        recipient_data,
        from_user_email
      )
      VALUES
      (
        'email',
        now(),
        now(),
        layout_template_name,
        content_template_name,
        subject,
        data,
        recipient_data,
        from_user_email
      )
      RETURNING id
      INTO last_id
      ;

      SELECT create_message_notification_job(last_id, run_at)
      INTO last_id
      ;

      RETURN last_id;
    END;
    $$;


--
-- Name: create_message_notification_email(integer, integer, integer, character varying, integer, integer[], character varying, character varying, character varying, timestamp without time zone); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_message_notification_email(app_type_id integer, master_id integer, item_id integer, item_type character varying, user_id integer, recipient_user_ids integer[], layout_template_name character varying, content_template_name character varying, subject character varying, run_at timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql
    AS $$
    DECLARE
      last_id INTEGER;
    BEGIN

      IF run_at IS NULL THEN
        run_at := now();
      END IF;

      INSERT INTO ml_app.message_notifications
      (
        subject,
        app_type_id,
        user_id,
        recipient_user_ids,
        layout_template_name,
        content_template_name,
        item_type,
        item_id,
        master_id,
        message_type,
        created_at,
        updated_at
      )
      VALUES
      (
        subject,
        app_type_id,
        user_id,
        recipient_user_ids,
        layout_template_name,
        content_template_name,
        item_type,
        item_id,
        master_id,
        'email',
        now(),
        now()
      )
      RETURNING id
      INTO last_id
      ;

      SELECT create_message_notification_job(last_id, run_at)
      INTO last_id
      ;

      RETURN last_id;
    END;
    $$;


--
-- Name: create_message_notification_job(integer); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_message_notification_job(message_notification_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  last_id INTEGER;
BEGIN

  INSERT INTO ml_app.delayed_jobs
  (
    priority,
    attempts,
    handler,
    run_at,
    queue,
    created_at,
    updated_at
  )
  VALUES
  (
    0,
    0,
    '--- !ruby/object:ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper
    job_data:
      job_class: HandleMessageNotificationJob
      job_id: ' || gen_random_uuid() || '
      queue_name: default
      arguments:
      - _aj_globalid: gid://fpa1/MessageNotification/' || message_notification_id::varchar || '
      locale: :en',
    now(),
    'default',
    now(),
    now()
  )
  RETURNING id
  INTO last_id
  ;

RETURN last_id;
END;
$$;


--
-- Name: create_message_notification_job(integer, timestamp without time zone); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_message_notification_job(message_notification_id integer, run_at timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS integer
    LANGUAGE plpgsql
    AS $$
    DECLARE
      last_id INTEGER;
    BEGIN

      IF run_at IS NULL THEN
        run_at := now();
      END IF;

      INSERT INTO ml_app.delayed_jobs
      (
        priority,
        attempts,
        handler,
        run_at,
        queue,
        created_at,
        updated_at
      )
      VALUES
      (
        0,
        0,
        '--- !ruby/object:ActiveJob::QueueAdapters::DelayedJobAdapter::JobWrapper
        job_data:
          job_class: HandleMessageNotificationJob
          job_id: ' || gen_random_uuid() || '
          queue_name: default
          arguments:
          - _aj_globalid: gid://fpa1/MessageNotification/' || message_notification_id::varchar || '
          locale: :en',
        run_at,
        'default',
        now(),
        now()
      )
      RETURNING id
      INTO last_id
      ;

    	RETURN last_id;
    END;
    $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: player_contacts; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.player_contacts (
    id integer NOT NULL,
    master_id integer,
    rec_type character varying,
    data character varying,
    source character varying,
    rank integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:36.922871'::timestamp without time zone
);


--
-- Name: player_infos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.player_infos (
    id integer NOT NULL,
    master_id integer,
    first_name character varying,
    last_name character varying,
    middle_name character varying,
    nick_name character varying,
    birth_date date,
    death_date date,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:37.094626'::timestamp without time zone,
    contact_pref character varying,
    start_year integer,
    rank integer,
    notes character varying,
    contact_id integer,
    college character varying,
    end_year integer,
    source character varying
);


--
-- Name: TABLE player_infos; Type: COMMENT; Schema: ml_app; Owner: -
--

COMMENT ON TABLE ml_app.player_infos IS 'Player biographical information';


--
-- Name: COLUMN player_infos.first_name; Type: COMMENT; Schema: ml_app; Owner: -
--

COMMENT ON COLUMN ml_app.player_infos.first_name IS 'First Name';


--
-- Name: create_remote_bhs_record(bigint, ml_app.player_infos, ml_app.player_contacts[]); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_remote_bhs_record(match_bhs_id bigint, new_player_info_record ml_app.player_infos, new_player_contact_records ml_app.player_contacts[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
found_bhs record;
player_contact record;
pc_length INTEGER;
found_pc record;
last_id INTEGER;
phone VARCHAR;
BEGIN

-- Find the bhs_assignments external identifier record for this master record and
-- validate that it exists
SELECT *
INTO found_bhs
FROM bhs_assignments bhs
WHERE bhs.bhs_id = match_bhs_id
LIMIT 1;

-- At this point, if we found the above record, then the master record can be referred to with found_bhs.master_id
-- We also create the new records setting the user_id to match that of the found_bhs record, rather than the original
-- value from the source database, which probably would not match the user IDs in the remote database. The user_id of the
-- found_bhs record is conceptually valid, since it is that user that has effectively kicked off the synchronization process
-- and requested the new player_infos and player_contacts records be created.

IF NOT FOUND THEN
RAISE EXCEPTION 'No bhs_assigments record found for BHS_ID --> %', (match_bhs_id);
END IF;




IF new_player_info_record.master_id IS NULL THEN
RAISE NOTICE 'No new_player_info_record found for BHS_ID --> %', (match_bhs_id);
RETURN NULL;
ELSE

RAISE NOTICE 'Syncing player info record %', (new_player_info_record::varchar);

-- Create the player info record
  INSERT INTO player_infos
  (
    master_id,
    first_name,
    last_name,
    middle_name,
    nick_name,
    birth_date,
    death_date,
    user_id,
    created_at,
    updated_at,
    contact_pref,
    start_year,
    rank,
    notes,
    contact_id,
    college,
    end_year,
    source
  )
  SELECT
    found_bhs.master_id,
    new_player_info_record.first_name,
    new_player_info_record.last_name,
    new_player_info_record.middle_name,
    new_player_info_record.nick_name,
    new_player_info_record.birth_date,
    new_player_info_record.death_date,
    found_bhs.user_id,
    new_player_info_record.created_at,
    new_player_info_record.updated_at,
    new_player_info_record.contact_pref,
    new_player_info_record.start_year,
    new_player_info_record.rank,
    new_player_info_record.notes,
    new_player_info_record.contact_id,
    new_player_info_record.college,
    new_player_info_record.end_year,
    new_player_info_record.source

RETURNING id
  INTO last_id
  ;


END IF;



SELECT array_length(new_player_contact_records, 1)
INTO pc_length;


IF pc_length IS NULL THEN
RAISE NOTICE 'No new_player_contact_records found for BHS_ID --> %', (match_bhs_id);
ELSE

RAISE NOTICE 'player contacts length %', (pc_length);

FOREACH player_contact IN ARRAY new_player_contact_records LOOP

SELECT * from player_contacts
INTO found_pc
WHERE
master_id = found_bhs.master_id AND
rec_type = player_contact.rec_type AND
data = player_contact.data
LIMIT 1;

IF found_pc.id IS NULL THEN

  INSERT INTO player_contacts
(
master_id,
rec_type,
data,
source,
rank,
user_id,
created_at,
updated_at
)
SELECT
found_bhs.master_id,
player_contact.rec_type,
player_contact.data,
player_contact.source,
player_contact.rank,
found_bhs.user_id,
player_contact.created_at,
player_contact.updated_at
;
END IF;

END LOOP;


SELECT id
INTO last_id
FROM activity_log_bhs_assignments
WHERE
bhs_assignment_id IS NOT NULL
AND (select_record_from_player_contact_phones is null OR select_record_from_player_contact_phones = '')
AND master_id = found_bhs.master_id
AND extra_log_type = 'primary'
ORDER BY id ASC
LIMIT 1;


-- Get the best phone number
SELECT data FROM player_contacts
INTO phone
WHERE rec_type='phone' AND rank is not null AND master_id = found_bhs.master_id
ORDER BY rank desc
LIMIT 1;

RAISE NOTICE 'best phone number %', (phone);
  RAISE NOTICE 'AL ID %', (last_id);

  -- Now update the activity log record.
UPDATE activity_log_bhs_assignments
SET
  select_record_from_player_contact_phones = phone,
results_link = ('https://testmybrain.org?demotestid=' || found_bhs.bhs_id::varchar),
updated_at = now()
WHERE
id = last_id;


-- Now send a notification to the PI
PERFORM activity_log_bhs_assignment_info_request_notification(last_id);


END IF;

return found_bhs.master_id;

END;
$$;


--
-- Name: addresses; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.addresses (
    id integer NOT NULL,
    master_id integer,
    street character varying,
    street2 character varying,
    street3 character varying,
    city character varying,
    state character varying,
    zip character varying,
    source character varying,
    rank integer,
    rec_type character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:35.929228'::timestamp without time zone,
    country character varying(3),
    postal_code character varying,
    region character varying
);


--
-- Name: create_remote_sleep_record(bigint, ml_app.player_infos, ml_app.player_contacts[], ml_app.addresses[]); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_remote_sleep_record(match_sleep_id bigint, new_player_info_record ml_app.player_infos, new_player_contact_records ml_app.player_contacts[], new_address_records ml_app.addresses[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	found_ipa record;
	etl_user_id INTEGER;
	new_master_id INTEGER;
	player_contact record;
	address record;
	pc_length INTEGER;
	found_pc record;
	a_length INTEGER;
	found_a record;
	last_id INTEGER;
BEGIN

-- Find the sleep_assignments external identifier record for this master record and
-- validate that it exists
SELECT *
INTO found_ipa
FROM sleep.sleep_assignments ipa
WHERE ipa.sleep_id = match_sleep_id
LIMIT 1;

-- If the IPA external identifier already exists then the sync should fail.

IF FOUND THEN
	RAISE NOTICE 'Already transferred: sleep_assigments record found for IPA_ID --> %', (match_sleep_id);
	UPDATE temp_sleep_assignments SET status='already transferred', to_master_id=new_master_id WHERE sleep_id = match_sleep_id;
  RETURN found_ipa.master_id;
END IF;

-- We create new records setting user_id for the user with email fphsetl@hms.harvard.edu, rather than the original
-- value from the source database, which probably would not match the user IDs in the remote database.
SELECT id
INTO etl_user_id
FROM users u
WHERE u.email = 'fphsetl@hms.harvard.edu'
LIMIT 1;

IF NOT FOUND THEN
	RAISE EXCEPTION 'No user with email fphsetl@hms.harvard.edu was found. Can not continue.';
END IF;

UPDATE temp_sleep_assignments SET status='started sync' WHERE sleep_id = match_sleep_id;


RAISE NOTICE 'Creating master record with user_id %', (etl_user_id::varchar);

INSERT INTO masters
(user_id, created_at, updated_at) VALUES (etl_user_id, now(), now())
RETURNING id
INTO new_master_id;

RAISE NOTICE 'Creating external identifier record %', (match_sleep_id::varchar);

INSERT INTO sleep.sleep_assignments
(sleep_id, master_id, user_id, created_at, updated_at)
VALUES (match_sleep_id, new_master_id, etl_user_id, now(), now());



IF new_player_info_record.master_id IS NULL THEN
	RAISE NOTICE 'No new_player_info_record found for IPA_ID --> %', (match_sleep_id);
	UPDATE temp_sleep_assignments SET status='failed - no player info provided' WHERE sleep_id = match_sleep_id;
	RETURN NULL;
ELSE

	RAISE NOTICE 'Syncing player info record %', (new_player_info_record::varchar);

	-- Create the player info record
  INSERT INTO player_infos
  (
    master_id,
    first_name,
    last_name,
    middle_name,
    nick_name,
    birth_date,
    death_date,
    user_id,
    created_at,
    updated_at,
    contact_pref,
    start_year,
    rank,
    notes,
    contact_id,
    college,
    end_year,
    source
  )
  SELECT
    new_master_id,
    new_player_info_record.first_name,
    new_player_info_record.last_name,
    new_player_info_record.middle_name,
    new_player_info_record.nick_name,
    new_player_info_record.birth_date,
    new_player_info_record.death_date,
    etl_user_id,
    new_player_info_record.created_at,
    new_player_info_record.updated_at,
    new_player_info_record.contact_pref,
    new_player_info_record.start_year,
    new_player_info_record.rank,
    new_player_info_record.notes,
    new_player_info_record.contact_id,
    new_player_info_record.college,
    new_player_info_record.end_year,
    new_player_info_record.source

		RETURNING id
	  INTO last_id
	  ;


END IF;



SELECT array_length(new_player_contact_records, 1)
INTO pc_length;


IF pc_length IS NULL THEN
	RAISE NOTICE 'No new_player_contact_records found for IPA_ID --> %', (match_sleep_id);
ELSE

	RAISE NOTICE 'player contacts length %', (pc_length);

	FOREACH player_contact IN ARRAY new_player_contact_records LOOP

		SELECT * from player_contacts
		INTO found_pc
		WHERE
			master_id = new_master_id AND
			rec_type = player_contact.rec_type AND
			data = player_contact.data
		LIMIT 1;

		IF found_pc.id IS NULL THEN

		  INSERT INTO player_contacts
			(
							master_id,
							rec_type,
							data,
							source,
							rank,
							user_id,
							created_at,
							updated_at
			)
			SELECT
					new_master_id,
					player_contact.rec_type,
					player_contact.data,
					player_contact.source,
					player_contact.rank,
					etl_user_id,
					player_contact.created_at,
					player_contact.updated_at
			;
		END IF;

	END LOOP;

END IF;




SELECT array_length(new_address_records, 1)
INTO a_length;


IF a_length IS NULL THEN
	RAISE NOTICE 'No new_address_records found for IPA_ID --> %', (match_sleep_id);
ELSE

	RAISE NOTICE 'addresses length %', (a_length);

	FOREACH address IN ARRAY new_address_records LOOP

		SELECT * from addresses
		INTO found_a
		WHERE
			master_id = new_master_id AND
			street = address.street AND
			zip = address.zip
		LIMIT 1;

		IF found_a.id IS NULL THEN

		  INSERT INTO addresses
			(
							master_id,
							street,
							street2,
							street3,
							city,
							state,
							zip,
							source,
							rank,
							rec_type,
							user_id,
							created_at,
							updated_at
			)
			SELECT
					new_master_id,
					address.street,
					address.street2,
					address.street3,
					address.city,
					address.state,
					address.zip,
					address.source,
					address.rank,
					address.rec_type,
					etl_user_id,
					address.created_at,
					address.updated_at
			;
		END IF;

	END LOOP;

END IF;

RAISE NOTICE 'Setting results for master_id %', (new_master_id);

UPDATE temp_sleep_assignments SET status='completed', to_master_id=new_master_id WHERE sleep_id = match_sleep_id;

return new_master_id;

END;
$$;


--
-- Name: create_remote_tbs_record(bigint, ml_app.player_infos, ml_app.player_contacts[], ml_app.addresses[]); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_remote_tbs_record(match_tbs_id bigint, new_player_info_record ml_app.player_infos, new_player_contact_records ml_app.player_contacts[], new_address_records ml_app.addresses[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	found_ipa record;
	etl_user_id INTEGER;
	new_master_id INTEGER;
	player_contact record;
	address record;
	pc_length INTEGER;
	found_pc record;
	a_length INTEGER;
	found_a record;
	last_id INTEGER;
BEGIN

-- Find the tbs_assignments external identifier record for this master record and
-- validate that it exists
SELECT *
INTO found_ipa
FROM tbs.tbs_assignments ipa
WHERE ipa.tbs_id = match_tbs_id
LIMIT 1;

-- If the IPA external identifier already exists then the sync should fail.

IF FOUND THEN
	RAISE NOTICE 'Already transferred: tbs_assigments record found for IPA_ID --> %', (match_tbs_id);
	UPDATE temp_tbs_assignments SET status='already transferred', to_master_id=new_master_id WHERE tbs_id = match_tbs_id;
  RETURN found_ipa.master_id;
END IF;

-- We create new records setting user_id for the user with email fphsetl@hms.harvard.edu, rather than the original
-- value from the source database, which probably would not match the user IDs in the remote database.
SELECT id
INTO etl_user_id
FROM users u
WHERE u.email = 'fphsetl@hms.harvard.edu'
LIMIT 1;

IF NOT FOUND THEN
	RAISE EXCEPTION 'No user with email fphsetl@hms.harvard.edu was found. Can not continue.';
END IF;

UPDATE temp_tbs_assignments SET status='started sync' WHERE tbs_id = match_tbs_id;


RAISE NOTICE 'Creating master record with user_id %', (etl_user_id::varchar);

INSERT INTO masters
(user_id, created_at, updated_at) VALUES (etl_user_id, now(), now())
RETURNING id
INTO new_master_id;

RAISE NOTICE 'Creating external identifier record %', (match_tbs_id::varchar);

INSERT INTO tbs.tbs_assignments
(tbs_id, master_id, user_id, created_at, updated_at)
VALUES (match_tbs_id, new_master_id, etl_user_id, now(), now());



IF new_player_info_record.master_id IS NULL THEN
	RAISE NOTICE 'No new_player_info_record found for IPA_ID --> %', (match_tbs_id);
	UPDATE temp_tbs_assignments SET status='failed - no player info provided' WHERE tbs_id = match_tbs_id;
	RETURN NULL;
ELSE

	RAISE NOTICE 'Syncing player info record %', (new_player_info_record::varchar);

	-- Create the player info record
  INSERT INTO player_infos
  (
    master_id,
    first_name,
    last_name,
    middle_name,
    nick_name,
    birth_date,
    death_date,
    user_id,
    created_at,
    updated_at,
    contact_pref,
    start_year,
    rank,
    notes,
    contact_id,
    college,
    end_year,
    source
  )
  SELECT
    new_master_id,
    new_player_info_record.first_name,
    new_player_info_record.last_name,
    new_player_info_record.middle_name,
    new_player_info_record.nick_name,
    new_player_info_record.birth_date,
    new_player_info_record.death_date,
    etl_user_id,
    new_player_info_record.created_at,
    new_player_info_record.updated_at,
    new_player_info_record.contact_pref,
    new_player_info_record.start_year,
    new_player_info_record.rank,
    new_player_info_record.notes,
    new_player_info_record.contact_id,
    new_player_info_record.college,
    new_player_info_record.end_year,
    new_player_info_record.source

		RETURNING id
	  INTO last_id
	  ;


END IF;



SELECT array_length(new_player_contact_records, 1)
INTO pc_length;


IF pc_length IS NULL THEN
	RAISE NOTICE 'No new_player_contact_records found for IPA_ID --> %', (match_tbs_id);
ELSE

	RAISE NOTICE 'player contacts length %', (pc_length);

	FOREACH player_contact IN ARRAY new_player_contact_records LOOP

		SELECT * from player_contacts
		INTO found_pc
		WHERE
			master_id = new_master_id AND
			rec_type = player_contact.rec_type AND
			data = player_contact.data
		LIMIT 1;

		IF found_pc.id IS NULL THEN

		  INSERT INTO player_contacts
			(
							master_id,
							rec_type,
							data,
							source,
							rank,
							user_id,
							created_at,
							updated_at
			)
			SELECT
					new_master_id,
					player_contact.rec_type,
					player_contact.data,
					player_contact.source,
					player_contact.rank,
					etl_user_id,
					player_contact.created_at,
					player_contact.updated_at
			;
		END IF;

	END LOOP;

END IF;




SELECT array_length(new_address_records, 1)
INTO a_length;


IF a_length IS NULL THEN
	RAISE NOTICE 'No new_address_records found for IPA_ID --> %', (match_tbs_id);
ELSE

	RAISE NOTICE 'addresses length %', (a_length);

	FOREACH address IN ARRAY new_address_records LOOP

		SELECT * from addresses
		INTO found_a
		WHERE
			master_id = new_master_id AND
			street = address.street AND
			zip = address.zip
		LIMIT 1;

		IF found_a.id IS NULL THEN

		  INSERT INTO addresses
			(
							master_id,
							street,
							street2,
							street3,
							city,
							state,
							zip,
							source,
							rank,
							rec_type,
							user_id,
							created_at,
							updated_at
			)
			SELECT
					new_master_id,
					address.street,
					address.street2,
					address.street3,
					address.city,
					address.state,
					address.zip,
					address.source,
					address.rank,
					address.rec_type,
					etl_user_id,
					address.created_at,
					address.updated_at
			;
		END IF;

	END LOOP;

END IF;

RAISE NOTICE 'Setting results for master_id %', (new_master_id);

UPDATE temp_tbs_assignments SET status='completed', to_master_id=new_master_id WHERE tbs_id = match_tbs_id;

return new_master_id;

END;
$$;


--
-- Name: create_remote_test_baseline_study_record(bigint, ml_app.player_infos, ml_app.player_contacts[], ml_app.addresses[]); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.create_remote_test_baseline_study_record(match_test_baseline_study_id bigint, new_player_info_record ml_app.player_infos, new_player_contact_records ml_app.player_contacts[], new_address_records ml_app.addresses[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	found_ipa record;
	etl_user_id INTEGER;
	new_master_id INTEGER;
	player_contact record;
	address record;
	pc_length INTEGER;
	found_pc record;
	a_length INTEGER;
	found_a record;
	last_id INTEGER;
BEGIN

-- Find the test_baseline_study_assignments external identifier record for this master record and
-- validate that it exists
SELECT *
INTO found_ipa
FROM tbs.test_baseline_study_assignments ipa
WHERE ipa.test_baseline_study_id = match_test_baseline_study_id
LIMIT 1;

-- If the IPA external identifier already exists then the sync should fail.

IF FOUND THEN
	RAISE NOTICE 'Already transferred: test_baseline_study_assigments record found for IPA_ID --> %', (match_test_baseline_study_id);
	UPDATE temp_test_baseline_study_assignments SET status='already transferred', to_master_id=new_master_id WHERE test_baseline_study_id = match_test_baseline_study_id;
  RETURN found_ipa.master_id;
END IF;

-- We create new records setting user_id for the user with email fphsetl@hms.harvard.edu, rather than the original
-- value from the source database, which probably would not match the user IDs in the remote database.
SELECT id
INTO etl_user_id
FROM users u
WHERE u.email = 'fphsetl@hms.harvard.edu'
LIMIT 1;

IF NOT FOUND THEN
	RAISE EXCEPTION 'No user with email fphsetl@hms.harvard.edu was found. Can not continue.';
END IF;

UPDATE temp_test_baseline_study_assignments SET status='started sync' WHERE test_baseline_study_id = match_test_baseline_study_id;


RAISE NOTICE 'Creating master record with user_id %', (etl_user_id::varchar);

INSERT INTO masters
(user_id, created_at, updated_at) VALUES (etl_user_id, now(), now())
RETURNING id
INTO new_master_id;

RAISE NOTICE 'Creating external identifier record %', (match_test_baseline_study_id::varchar);

INSERT INTO tbs.test_baseline_study_assignments
(test_baseline_study_id, master_id, user_id, created_at, updated_at)
VALUES (match_test_baseline_study_id, new_master_id, etl_user_id, now(), now());



IF new_player_info_record.master_id IS NULL THEN
	RAISE NOTICE 'No new_player_info_record found for IPA_ID --> %', (match_test_baseline_study_id);
	UPDATE temp_test_baseline_study_assignments SET status='failed - no player info provided' WHERE test_baseline_study_id = match_test_baseline_study_id;
	RETURN NULL;
ELSE

	RAISE NOTICE 'Syncing player info record %', (new_player_info_record::varchar);

	-- Create the player info record
  INSERT INTO player_infos
  (
    master_id,
    first_name,
    last_name,
    middle_name,
    nick_name,
    birth_date,
    death_date,
    user_id,
    created_at,
    updated_at,
    contact_pref,
    start_year,
    rank,
    notes,
    contact_id,
    college,
    end_year,
    source
  )
  SELECT
    new_master_id,
    new_player_info_record.first_name,
    new_player_info_record.last_name,
    new_player_info_record.middle_name,
    new_player_info_record.nick_name,
    new_player_info_record.birth_date,
    new_player_info_record.death_date,
    etl_user_id,
    new_player_info_record.created_at,
    new_player_info_record.updated_at,
    new_player_info_record.contact_pref,
    new_player_info_record.start_year,
    new_player_info_record.rank,
    new_player_info_record.notes,
    new_player_info_record.contact_id,
    new_player_info_record.college,
    new_player_info_record.end_year,
    new_player_info_record.source

		RETURNING id
	  INTO last_id
	  ;


END IF;



SELECT array_length(new_player_contact_records, 1)
INTO pc_length;


IF pc_length IS NULL THEN
	RAISE NOTICE 'No new_player_contact_records found for IPA_ID --> %', (match_test_baseline_study_id);
ELSE

	RAISE NOTICE 'player contacts length %', (pc_length);

	FOREACH player_contact IN ARRAY new_player_contact_records LOOP

		SELECT * from player_contacts
		INTO found_pc
		WHERE
			master_id = new_master_id AND
			rec_type = player_contact.rec_type AND
			data = player_contact.data
		LIMIT 1;

		IF found_pc.id IS NULL THEN

		  INSERT INTO player_contacts
			(
							master_id,
							rec_type,
							data,
							source,
							rank,
							user_id,
							created_at,
							updated_at
			)
			SELECT
					new_master_id,
					player_contact.rec_type,
					player_contact.data,
					player_contact.source,
					player_contact.rank,
					etl_user_id,
					player_contact.created_at,
					player_contact.updated_at
			;
		END IF;

	END LOOP;

END IF;




SELECT array_length(new_address_records, 1)
INTO a_length;


IF a_length IS NULL THEN
	RAISE NOTICE 'No new_address_records found for IPA_ID --> %', (match_test_baseline_study_id);
ELSE

	RAISE NOTICE 'addresses length %', (a_length);

	FOREACH address IN ARRAY new_address_records LOOP

		SELECT * from addresses
		INTO found_a
		WHERE
			master_id = new_master_id AND
			street = address.street AND
			zip = address.zip
		LIMIT 1;

		IF found_a.id IS NULL THEN

		  INSERT INTO addresses
			(
							master_id,
							street,
							street2,
							street3,
							city,
							state,
							zip,
							source,
							rank,
							rec_type,
							user_id,
							created_at,
							updated_at
			)
			SELECT
					new_master_id,
					address.street,
					address.street2,
					address.street3,
					address.city,
					address.state,
					address.zip,
					address.source,
					address.rank,
					address.rec_type,
					etl_user_id,
					address.created_at,
					address.updated_at
			;
		END IF;

	END LOOP;

END IF;

RAISE NOTICE 'Setting results for master_id %', (new_master_id);

UPDATE temp_test_baseline_study_assignments SET status='completed', to_master_id=new_master_id WHERE test_baseline_study_id = match_test_baseline_study_id;

return new_master_id;

END;
$$;


--
-- Name: current_user_id(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.current_user_id() RETURNS integer
    LANGUAGE plpgsql
    AS $$
      DECLARE
        user_id integer;
      BEGIN
        user_id := (select id from users where email = current_user limit 1);

        return user_id;
      END;
    $$;


--
-- Name: datadic_choice_history_upd(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.datadic_choice_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO ref_data.datadic_choice_history (
    source_name, source_type, form_name, field_name, value, label, redcap_data_dictionary_id,
    disabled,
    admin_id,
    created_at,
    updated_at,
    datadic_choice_id)
  SELECT
    NEW.source_name, NEW.source_type, NEW.form_name, NEW.field_name, NEW.value, NEW.label, NEW.redcap_data_dictionary_id,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: datadic_variable_history_upd(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.datadic_variable_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO datadic_variable_history (
    study, source_name, source_type, domain, form_name, variable_name, variable_type, presentation_type, label, label_note, annotation, is_required, valid_type, valid_min, valid_max, multi_valid_choices, is_identifier, is_derived_var, multi_derived_from_id, doc_url, target_type, owner_email, classification, other_classification, multi_timepoints, equivalent_to_id, storage_type, db_or_fs, schema_or_path, table_or_file, storage_varname, redcap_data_dictionary_id, position, section_id, sub_section_id, title,
    disabled,
    admin_id,
    created_at,
    updated_at,
    datadic_variable_id)
  SELECT
    NEW.study, NEW.source_name, NEW.source_type, NEW.domain, NEW.form_name, NEW.variable_name, NEW.variable_type, NEW.presentation_type, NEW.label, NEW.label_note, NEW.annotation, NEW.is_required, NEW.valid_type, NEW.valid_min, NEW.valid_max, NEW.multi_valid_choices, NEW.is_identifier, NEW.is_derived_var, NEW.multi_derived_from_id, NEW.doc_url, NEW.target_type, NEW.owner_email, NEW.classification, NEW.other_classification, NEW.multi_timepoints, NEW.equivalent_to_id, NEW.storage_type, NEW.db_or_fs, NEW.schema_or_path, NEW.table_or_file, NEW.storage_varname, NEW.redcap_data_dictionary_id, NEW.position, NEW.section_id, NEW.sub_section_id, NEW.title,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: demo_sync_bhs_record(integer, bigint); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.demo_sync_bhs_record(new_master_id integer, new_bhs_id bigint) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	prev_master_id integer;
	found_player_info record;
begin


select * 
into found_player_info
from player_infos pi 
left join bhs_assignments b on b.master_id = pi.master_id 
where pi.bhs_id = new_bhs_id
;

IF NOT FOUND THEN
	RAISE EXCEPTION 'BHS ID not found --> %', (bhs_id);
ELSE
	update player_infos
	set master_id = new_master_id 
	where id = found_player_info.id;
	

	return found_player_info.id;
END IF;
end;

$$;


--
-- Name: nfs_store_archived_files; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_archived_files (
    id integer NOT NULL,
    file_hash character varying,
    file_name character varying NOT NULL,
    content_type character varying NOT NULL,
    archive_file character varying NOT NULL,
    path character varying NOT NULL,
    file_size bigint NOT NULL,
    file_updated_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    nfs_store_container_id integer,
    user_id integer,
    title character varying,
    description character varying,
    nfs_store_stored_file_id integer,
    file_metadata jsonb,
    embed_resource_name character varying,
    embed_resource_id bigint
);


--
-- Name: nfs_store_stored_files; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_stored_files (
    id integer NOT NULL,
    file_hash character varying NOT NULL,
    file_name character varying NOT NULL,
    content_type character varying NOT NULL,
    file_size bigint NOT NULL,
    path character varying,
    file_updated_at timestamp without time zone,
    user_id integer,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    title character varying,
    description character varying,
    last_process_name_run character varying,
    file_metadata jsonb,
    embed_resource_name character varying,
    embed_resource_id bigint
);


--
-- Name: filestore_report_file_path(ml_app.nfs_store_stored_files, ml_app.nfs_store_archived_files); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.filestore_report_file_path(sf ml_app.nfs_store_stored_files, af ml_app.nfs_store_archived_files) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
    BEGIN

      return CASE WHEN af.id IS NOT NULL THEN
        coalesce(sf.path, '') || '/' || sf.file_name || '/' || af.path
        ELSE sf.path
      END;

	END;
$$;


--
-- Name: filestore_report_full_file_path(ml_app.nfs_store_stored_files, ml_app.nfs_store_archived_files); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.filestore_report_full_file_path(sf ml_app.nfs_store_stored_files, af ml_app.nfs_store_archived_files) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
          BEGIN

            return CASE WHEN af.id IS NOT NULL THEN
              coalesce(sf.path, '') || '/' || sf.file_name || '/' || af.path || '/' || af.file_name
              ELSE coalesce(sf.path, '') || '/' || sf.file_name
            END;

       END;
      $$;


--
-- Name: filestore_report_perform_action(integer, character varying, integer, ml_app.nfs_store_stored_files, ml_app.nfs_store_archived_files); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.filestore_report_perform_action(cid integer, altype character varying, alid integer, sf ml_app.nfs_store_stored_files, af ml_app.nfs_store_archived_files) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
	DECLARE
        jo jsonb;
        rt varchar;
        fn varchar;
        alt varchar;
    BEGIN

        rt := '"' || (CASE WHEN af.id IS NOT NULL THEN 'archived_file' ELSE 'stored_file' END) || '"';
        fn := '"' || (CASE WHEN af.id IS NOT NULL THEN af.file_name ELSE sf.file_name END) || '"';
		alt := '"' || altype || '"';
        jo := '{}';

        jo := jsonb_set(jo, '{perform_action}', '"/nfs_store/downloads/!container_id"');
        jo := jsonb_set(jo, '{container_id}', cid::varchar::jsonb);
        jo := jsonb_set(jo, '{download_id}', coalesce(af.id, sf.id)::varchar::jsonb);
        jo := jsonb_set(jo, '{activity_log_type}', alt::jsonb);
        jo := jsonb_set(jo, '{activity_log_id}', alid::varchar::jsonb);
        jo := jsonb_set(jo, '{retrieval_type}', rt::jsonb );
        jo := jsonb_set(jo, '{label}', fn::jsonb);

        return jo;

	END;
$$;


--
-- Name: filestore_report_select_fields(integer, character varying, integer, integer, integer); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.filestore_report_select_fields(cid integer, altype character varying, alid integer, sfid integer, afid integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
	DECLARE
        jo jsonb;
        joid jsonb;
        rt varchar;
        alt varchar;
    BEGIN

    	rt := '"' || CASE WHEN afid IS NOT NULL THEN 'archived_file' ELSE 'stored_file' END || '"';
    	alt := '"' || altype || '"';

        joid := '{}'::jsonb;
        joid := jsonb_set(joid, '{id}', coalesce(afid, sfid)::varchar::jsonb);
        joid := jsonb_set(joid, '{retrieval_type}', rt::jsonb );
        joid := jsonb_set(joid, '{container_id}', cid::varchar::jsonb);
        joid := jsonb_set(joid, '{activity_log_type}', alt::jsonb);
        joid := jsonb_set(joid, '{activity_log_id}', alid::varchar::jsonb);


    	jo := '{}'::jsonb;
  		jo := jsonb_set(jo, '{field_name}', '"nfs_store_download[selected_items][]"');
    	jo := jsonb_set(jo, '{value}', joid);
    	return jo;

	END;
$$;


--
-- Name: find_new_remote_bhs_records(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.find_new_remote_bhs_records() RETURNS TABLE(master_id integer, bhs_id bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
RETURN QUERY
SELECT distinct bhs.master_id, bhs.bhs_id
FROM masters m
LEFT JOIN player_infos pi
ON pi.master_id = m.id
INNER JOIN bhs_assignments bhs
ON m.id = bhs.master_id
INNER JOIN activity_log_bhs_assignments al
ON m.id = al.master_id AND al.extra_log_type = 'primary'
WHERE
  pi.id IS NULL
AND bhs.bhs_id is not null
AND bhs.bhs_id <> 100000000
;
END;
$$;


--
-- Name: format_update_notes(character varying, character varying, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.format_update_notes(field_name character varying, old_val character varying, new_val character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
        DECLARE
          res VARCHAR;
        BEGIN
          res := '';
          old_val := lower(coalesce(old_val, '-')::varchar);
          new_val := lower(coalesce(new_val, '')::varchar);
          IF old_val <> new_val THEN 
            res := field_name;
            IF old_val <> '-' THEN
              res := res || ' from ' || old_val ;
            END IF;
            res := res || ' to ' || new_val || '; ';
          END IF;
          RETURN res;
        END;
      $$;


--
-- Name: get_app_type_id_by_name(character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.get_app_type_id_by_name(app_type_name character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    app_type_id INTEGER;
  BEGIN

    select id from app_types
    into app_type_id
    where name = app_type_name and (disabled is null or disabled = false)
    order by id asc
    limit 1;

    RETURN app_type_id;

  END;
$$;


--
-- Name: users; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.users (
    id integer NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp without time zone,
    remember_created_at timestamp without time zone,
    sign_in_count integer DEFAULT 0 NOT NULL,
    current_sign_in_at timestamp without time zone,
    last_sign_in_at timestamp without time zone,
    current_sign_in_ip inet,
    last_sign_in_ip inet,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    failed_attempts integer DEFAULT 0 NOT NULL,
    unlock_token character varying,
    locked_at timestamp without time zone,
    disabled boolean,
    admin_id integer,
    app_type_id integer,
    authentication_token character varying(30),
    encrypted_otp_secret character varying,
    encrypted_otp_secret_iv character varying,
    encrypted_otp_secret_salt character varying,
    consumed_timestep integer,
    otp_required_for_login boolean,
    password_updated_at timestamp without time zone,
    first_name character varying,
    last_name character varying,
    do_not_email boolean DEFAULT false,
    confirmation_token character varying,
    confirmed_at timestamp without time zone,
    confirmation_sent_at timestamp without time zone,
    country_code character varying,
    terms_of_use_accepted character varying
);


--
-- Name: get_etl_user(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.get_etl_user() RETURNS ml_app.users
    LANGUAGE plpgsql
    AS $$
DECLARE
	etl_user RECORD;
BEGIN
-- We create new records setting user_id for the user with email fphsetl@hms.harvard.edu, rather than the original
-- value from the source database, which probably would not match the user IDs in the remote database.
SELECT *
INTO etl_user
FROM users u
WHERE u.email = 'fphsetl@hms.harvard.edu'
LIMIT 1;

IF NOT FOUND THEN
  RAISE EXCEPTION 'No user with email fphsetl@hms.harvard.edu was found. Can not continue.';
END IF;


RETURN etl_user;

END;
$$;


--
-- Name: get_user_ids_for_app_type_role(integer, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.get_user_ids_for_app_type_role(for_app_type_id integer, with_role_name character varying) RETURNS integer[]
    LANGUAGE plpgsql
    AS $$
  DECLARE
    user_ids INTEGER[];
  BEGIN

    select array_agg(ur.user_id)
    from user_roles ur
    inner join users u on ur.user_id = u.id
    into user_ids
    where
      role_name = with_role_name AND
      ur.app_type_id = for_app_type_id AND
      (ur.disabled is null or ur.disabled = false) AND
      (ur.disabled is null or u.disabled = false)
    ;

    RETURN user_ids;

  END;
$$;


--
-- Name: handle_address_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.handle_address_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          
          NEW.street := lower(NEW.street);
          NEW.street2 := lower(NEW.street2);
          NEW.street3 := lower(NEW.street3);
          NEW.city := lower(NEW.city);
          NEW.state := lower(NEW.state);
          NEW.zip := lower(NEW.zip);
          NEW.country := lower(NEW.country);
          NEW.postal_code := lower(NEW.postal_code);
          NEW.region := lower(NEW.region);
          NEW.source := lower(NEW.source);
          RETURN NEW;
            
        END;   
    $$;


--
-- Name: handle_delete(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.handle_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      DECLARE
        latest_tracker tracker_history%ROWTYPE;
      BEGIN

        -- Find the most recent remaining item in tracker_history for the master/protocol pair,
        -- now that the target record has been deleted.
        -- tracker_id is the foreign key onto the trackers table master/protocol record.

        SELECT * INTO latest_tracker
          FROM tracker_history 
          WHERE tracker_id = OLD.tracker_id 
          ORDER BY event_date DESC NULLS last, updated_at DESC NULLS last LIMIT 1;

        IF NOT FOUND THEN
          -- No record was found in tracker_history for the master/protocol pair.
          -- Therefore there should be no corresponding trackers record either. Delete it.
          DELETE FROM trackers WHERE trackers.id = OLD.tracker_id;

        ELSE
          -- A record was found in tracker_history. Since it is the latest one for the master/protocol pair,
          -- just go ahead and update the corresponding record in trackers.
          UPDATE trackers 
            SET 
              event_date = latest_tracker.event_date, 
              sub_process_id = latest_tracker.sub_process_id, 
              protocol_event_id = latest_tracker.protocol_event_id, 
              item_id = latest_tracker.item_id, 
              item_type = latest_tracker.item_type, 
              updated_at = latest_tracker.updated_at, 
              notes = latest_tracker.notes, 
              user_id = latest_tracker.user_id
            WHERE trackers.id = OLD.tracker_id;

        END IF;


        RETURN OLD;

      END
    $$;


--
-- Name: handle_player_contact_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.handle_player_contact_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
         

          NEW.rec_type := lower(NEW.rec_type);
          NEW.data := lower(NEW.data);
          NEW.source := lower(NEW.source);


          RETURN NEW;
            
        END;   
    $$;


--
-- Name: handle_player_info_before_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.handle_player_info_before_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          NEW.first_name := lower(NEW.first_name);          
          NEW.last_name := lower(NEW.last_name);          
          NEW.middle_name := lower(NEW.middle_name);          
          NEW.nick_name := lower(NEW.nick_name);          
          NEW.college := lower(NEW.college);                    
          NEW.source := lower(NEW.source);
          RETURN NEW;
            
        END;   
    $$;


--
-- Name: handle_rc_cis_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.handle_rc_cis_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        DECLARE
          new_master_id integer;
          new_msid integer;
          updated_item_id integer;
          register_tracker boolean;
          update_notes VARCHAR;
          event_date DATE;
          track_p varchar;
          track_sp varchar;
          track_pe varchar;
          res_status varchar;
          
        BEGIN


          track_p := 'study';
          track_sp := 'CIS-received';
          track_pe := 'REDCap';

          register_tracker := FALSE;
          update_notes := '';
          res_status := NEW.status;

          event_date :=  NEW.time_stamp::date;

          IF coalesce(NEW.status,'') <> '' THEN

            IF NEW.status = 'create master' THEN

                IF NEW.master_id IS NOT NULL THEN
                  RAISE EXCEPTION 'Can not create a master when the master ID is already set. Review the linked Master record, or to create a new Master record clear the master_id first and try again.';
                END IF;


                SELECT MAX(msid) + 1 INTO new_msid FROM masters;
                
                INSERT INTO masters
                  (msid, created_at, updated_at, user_id)
                  VALUES 
                  (new_msid, now(), now(), NEW.user_id)
                  RETURNING id INTO new_master_id;

                INSERT INTO player_infos
                  (master_id, first_name, last_name, source, created_at, updated_at, user_id)
                  VALUES
                  (new_master_id, NEW.first_name, NEW.last_name, 'cis-redcap', now(), now(), NEW.user_id);
                
                register_tracker := TRUE;
                
            ELSE              
                SELECT id INTO new_master_id FROM masters WHERE id = NEW.master_id;
            END IF;
  
            IF NEW.status = 'update name' OR NEW.status = 'update all' OR NEW.status = 'create master' THEN  
                IF new_master_id IS NULL THEN
                  RAISE EXCEPTION 'Must set a master ID to %', NEW.status;
                END IF;


                SELECT format_update_notes('first name', first_name, NEW.first_name) ||
                  format_update_notes('last name', last_name, NEW.last_name) ||
                  format_update_notes('middle name', middle_name, NEW.middle_name) ||
                  format_update_notes('nick name', nick_name, NEW.nick_name)
                INTO update_notes
                FROM player_infos
                WHERE master_id = new_master_id order by rank desc limit 1;

                UPDATE player_infos SET
                  master_id = new_master_id, first_name = NEW.first_name, last_name = NEW.last_name, 
                  middle_name = NEW.middle_name, nick_name = NEW.nick_name, 
                  source = 'cis-redcap', created_at = now(), updated_at = now(), user_id = NEW.user_id
                  WHERE master_id = new_master_id
                  RETURNING id INTO updated_item_id;
                

                PERFORM add_study_update_entry(new_master_id, 'updated', 'player info', event_date, update_notes, NEW.user_id, updated_item_id, 'PlayerInfo');

                register_tracker := TRUE;                
                res_status := 'updated name';
            END IF;

            IF NEW.status = 'update address' OR NEW.status = 'update all' OR NEW.status = 'create master' THEN  
                IF new_master_id IS NULL THEN
                  RAISE EXCEPTION 'Must set a master ID to %', NEW.status;
                END IF;

                IF NEW.street IS NOT NULL AND trim(NEW.street) <> '' OR
                    NEW.state IS NOT NULL AND trim(NEW.state) <> '' OR
                    NEW.zipcode IS NOT NULL AND trim(NEW.zipcode) <> '' THEN   

                  SELECT format_update_notes('street', NULL, NEW.street) ||
                    format_update_notes('street2', NULL, NEW.street2) ||
                    format_update_notes('city', NULL, NEW.city) ||
                    format_update_notes('state', NULL, NEW.state) ||
                    format_update_notes('zip', NULL, NEW.zipcode)                  
                  INTO update_notes;
                  -- FROM addresses
                  -- WHERE master_id = new_master_id;


                  
                  INSERT INTO addresses
                    (master_id, street, street2, city, state, zip, source, rank, created_at, updated_at, user_id)
                    VALUES
                    (new_master_id, NEW.street, NEW.street2, NEW.city, NEW.state, NEW.zipcode, 'cis-redcap', 10, now(), now(), NEW.user_id)
                    RETURNING id INTO updated_item_id;
                  
                  PERFORM update_address_ranks(new_master_id);
                  PERFORM add_study_update_entry(new_master_id, 'updated', 'address', event_date, update_notes, NEW.user_id, updated_item_id, 'Address');

                  register_tracker := TRUE;
                  res_status := 'updated address';
                ELSE
                  res_status := 'address not updated - details blank';
                END IF;

                
            END IF;

            IF NEW.status = 'update email' OR NEW.status = 'update all' OR NEW.status = 'create master' THEN  

                IF new_master_id IS NULL THEN
                  RAISE EXCEPTION 'Must set a master ID to %', NEW.status;
                END IF;

                IF NEW.email IS NOT NULL AND trim(NEW.email) <> '' THEN   

                  SELECT format_update_notes('data', NULL, NEW.email)           
                  INTO update_notes;                  


                  INSERT INTO player_contacts
                    (master_id, data, rec_type, source, rank, created_at, updated_at, user_id)
                    VALUES
                    (new_master_id, NEW.email, 'email', 'cis-redcap', 10, now(), now(), NEW.user_id)
                    RETURNING id INTO updated_item_id;


                  PERFORM update_player_contact_ranks(new_master_id, 'email');
                  PERFORM add_study_update_entry(new_master_id, 'updated', 'player contact', event_date, update_notes, NEW.user_id, updated_item_id, 'PlayerContact');

                  register_tracker := TRUE;
                  res_status := 'updated email';
                ELSE
                  res_status := 'email not updated - details blank';
                END IF;                
            END IF;

            IF NEW.status = 'update phone' OR NEW.status = 'update all' OR NEW.status = 'create master' THEN  
                IF new_master_id IS NULL THEN
                  RAISE EXCEPTION 'Must set a master ID to %', NEW.status;
                END IF;

                IF NEW.phone IS NOT NULL AND trim(NEW.phone) <> '' THEN   

                  SELECT format_update_notes('data', NULL, NEW.phone)           
                  INTO update_notes;                  

                  INSERT INTO player_contacts
                    (master_id, data, rec_type, source, rank, created_at, updated_at, user_id)
                    VALUES
                    (new_master_id, NEW.phone, 'phone', 'cis-redcap', 10, now(), now(), NEW.user_id)
                    RETURNING id INTO updated_item_id;

                  PERFORM update_player_contact_ranks(new_master_id, 'phone');
                  PERFORM add_study_update_entry(new_master_id, 'updated', 'player contact', event_date, update_notes, NEW.user_id, updated_item_id, 'PlayerContact');

                  register_tracker := TRUE;
                  res_status := 'updated phone';
                ELSE
                  res_status := 'phone not updated - details blank';
                END IF;
            END IF;
            

            CASE 
              WHEN NEW.status = 'create master' THEN 
                res_status := 'created master';
              WHEN NEW.status = 'update all' THEN 
                res_status := 'updated all';              
              ELSE
            END CASE;

            -- the master_id was set and an action performed. Register the tracker event
            IF coalesce(NEW.added_tracker, FALSE) = FALSE AND new_master_id IS NOT NULL AND register_tracker THEN
              PERFORM add_tracker_entry_by_name(new_master_id, track_p, track_sp, track_pe, OLD.time_stamp::date, ('Heard about: ' || coalesce(OLD.hearabout, '(not set)') || E'
Submitted by REDCap ID '|| OLD.redcap_survey_identifier), NEW.user_id, NULL, NULL);
              NEW.added_tracker = TRUE;
            END IF;

            NEW.master_id := new_master_id;
            NEW.updated_at := now();
            NEW.status := res_status;

          END IF;

          RETURN NEW;
            
        END;   
    $$;


--
-- Name: handle_tracker_history_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.handle_tracker_history_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      
      DELETE FROM tracker_history WHERE id = OLD.id;
  
      INSERT INTO trackers 
        (master_id, protocol_id, 
         protocol_event_id, event_date, sub_process_id, notes,
         item_id, item_type,
         created_at, updated_at, user_id)

        SELECT NEW.master_id, NEW.protocol_id, 
           NEW.protocol_event_id, NEW.event_date, 
           NEW.sub_process_id, NEW.notes, 
           NEW.item_id, NEW.item_type,
           NEW.created_at, NEW.updated_at, NEW.user_id  ;

      RETURN NULL;
    END;
    $$;


--
-- Name: ipa_ps_tmoca_score_calc(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.ipa_ps_tmoca_score_calc() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
  BEGIN


    NEW.tmoca_score :=
      NEW.attn_digit_span +
      NEW.attn_digit_vigilance +
      NEW.attn_digit_calculation +
      NEW.language_repeat +
      NEW.language_fluency +
      NEW.abstraction +
      NEW.delayed_recall +
      NEW.orientation;

    RETURN NEW;
    
  END;
$$;


--
-- Name: lock_transfer_records_with_external_ids(character varying, character varying, integer[], integer[], character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.lock_transfer_records_with_external_ids(from_db character varying, to_db character varying, master_ids integer[], external_ids integer[], external_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT into sync_statuses
  ( from_master_id, external_id, external_type, from_db, to_db, select_status, created_at, updated_at )
  (
    SELECT unnest(master_ids), unnest(external_ids), external_type, from_db, to_db, 'new', now(), now()
  );

  RETURN 1;

END;
$$;


--
-- Name: lock_transfer_records_with_external_ids(character varying, character varying, integer[], integer[], character varying, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.lock_transfer_records_with_external_ids(from_db character varying, to_db character varying, master_ids integer[], external_ids integer[], external_type character varying, event character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT into sync_statuses
  ( from_master_id, external_id, external_type, from_db, to_db, event, select_status, created_at, updated_at )
  (
    SELECT unnest(master_ids), unnest(external_ids), external_type, from_db, to_db, event, 'new', now(), now()
  );

  RETURN 1;

END;
$$;


--
-- Name: lock_transfer_records_with_external_ids_and_events(character varying, character varying, integer[], integer[], character varying, character varying[]); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.lock_transfer_records_with_external_ids_and_events(from_db character varying, to_db character varying, master_ids integer[], external_ids integer[], external_type character varying, events character varying[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT into ml_app.sync_statuses
  ( from_master_id, external_id, external_type, from_db, to_db, event, select_status, created_at, updated_at )
  (
    SELECT unnest(master_ids), unnest(external_ids), external_type, from_db, to_db, unnest(events), 'new', now(), now()
  );

  RETURN 1;

END;
$$;


--
-- Name: log_accuracy_score_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_accuracy_score_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO accuracy_score_history
            (
                    accuracy_score_id,
                    name ,
                    value ,                    
                    created_at ,
                    updated_at ,
                    disabled ,
                    admin_id                      
                )                 
            SELECT                 
                NEW.id,
                NEW.name ,
                    NEW.value ,                    
                    NEW.created_at ,
                    NEW.updated_at ,
                    NEW.disabled ,
                    NEW.admin_id                      
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_activity_log_bhs_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_bhs_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_bhs_assignment_history
                  (
                      master_id,
                      bhs_assignment_id,
                      select_record_from_player_contact_phones,
                      return_call_availability_notes,
                      questions_from_call_notes,
                      results_link,
                      select_result,
                      pi_return_call_notes,
                      completed_q1_no_yes,
                      completed_teamstudy_no_yes,
                      previous_contact_with_team_no_yes,
                      previous_contact_with_team_notes,
                      notes,
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_bhs_assignment_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.bhs_assignment_id,
                      NEW.select_record_from_player_contact_phones,
                      NEW.return_call_availability_notes,
                      NEW.questions_from_call_notes,
                      NEW.results_link,
                      NEW.select_result,
                      NEW.pi_return_call_notes,
                      NEW.completed_q1_no_yes,
                      NEW.completed_teamstudy_no_yes,
                      NEW.previous_contact_with_team_no_yes,
                      NEW.previous_contact_with_team_notes,
                      NEW.notes,
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_bhs_assignments_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_bhs_assignments_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO activity_log_bhs_assignment_history (
    master_id,
    bhs_assignment_id,
    select_record_from_player_contact_phones, return_call_availability_notes, questions_from_call_notes, results_link, select_result, pi_notes_from_return_call, pi_return_call_notes,
    extra_log_type,
    user_id,
    created_at,
    updated_at,
    activity_log_bhs_assignment_id)
  SELECT
    NEW.master_id,
    NEW.bhs_assignment_id,
    NEW.select_record_from_player_contact_phones, NEW.return_call_availability_notes, NEW.questions_from_call_notes, NEW.results_link, NEW.select_result, NEW.pi_notes_from_return_call, NEW.pi_return_call_notes,
    NEW.extra_log_type,
    NEW.user_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: log_activity_log_ext_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ext_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ext_assignment_history
                  (
                      master_id,
                      ext_assignment_id,
                      do_when,
notes,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ext_assignment_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ext_assignment_id,
                      NEW.do_when,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_ipa_assignment_adverse_event_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_assignment_adverse_event_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ipa_assignment_adverse_event_history
                  (
                      master_id,
                      ipa_assignment_id,
                      
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ipa_assignment_adverse_event_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_assignment_id,
                      
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_ipa_assignment_minor_deviation_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_assignment_minor_deviation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ipa_assignment_minor_deviation_history
                  (
                      master_id,
                      ipa_assignment_id,
                      activity_date,
                      deviation_discovered_when,
                      deviation_occurred_when,
                      deviation_description,
                      corrective_action_description,
                      select_status,
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ipa_assignment_minor_deviation_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_assignment_id,
                      NEW.activity_date,
                      NEW.deviation_discovered_when,
                      NEW.deviation_occurred_when,
                      NEW.deviation_description,
                      NEW.corrective_action_description,
                      NEW.select_status,
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_ipa_assignment_navigation_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_assignment_navigation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO activity_log_ipa_assignment_navigation_history
            (
                master_id,
                ipa_assignment_id,
                event_date,
                select_station,
                arrival_time,
                start_time,
                event_notes,
                completion_time,
                participant_feedback_notes,
                other_navigator_notes,
                add_protocol_deviation_record_no_yes,
                add_adverse_event_record_no_yes,
                select_event_type,
                other_event_type,
                select_status,
                extra_log_type,
                user_id,
                created_at,
                updated_at,
                activity_log_ipa_assignment_navigation_id
                )
            SELECT
                NEW.master_id,
                NEW.ipa_assignment_id,
                NEW.event_date,
                NEW.select_station,
                NEW.arrival_time,
                NEW.start_time,
                NEW.event_notes,
                NEW.completion_time,
                NEW.participant_feedback_notes,
                NEW.other_navigator_notes,
                NEW.add_protocol_deviation_record_no_yes,
                NEW.add_adverse_event_record_no_yes,
                NEW.select_event_type,
                NEW.other_event_type,
                NEW.select_status,
                NEW.extra_log_type,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_activity_log_ipa_assignment_phone_screen_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_assignment_phone_screen_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ipa_assignment_phone_screen_history
                  (
                      master_id,
                      ipa_assignment_id,
                      callback_required,
                      callback_date,
                      callback_time,
                      notes,
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ipa_assignment_phone_screen_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_assignment_id,
                      NEW.callback_required,
                      NEW.callback_date,
                      NEW.callback_time,
                      NEW.notes,
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_ipa_assignment_post_visit_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_assignment_post_visit_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ipa_assignment_post_visit_history
                  (
                      master_id,
                      ipa_assignment_id,
                      select_activity,
                      activity_date,
                      select_record_from_player_contacts,
                      select_record_from_addresses,
                      select_direction,
                      select_who,
                      select_result,
                      select_next_step,
                      follow_up_when,
                      follow_up_time,
                      notes,
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ipa_assignment_post_visit_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_assignment_id,
                      NEW.select_activity,
                      NEW.activity_date,
                      NEW.select_record_from_player_contacts,
                      NEW.select_record_from_addresses,
                      NEW.select_direction,
                      NEW.select_who,
                      NEW.select_result,
                      NEW.select_next_step,
                      NEW.follow_up_when,
                      NEW.follow_up_time,
                      NEW.notes,
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_ipa_assignment_protocol_deviation_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_assignment_protocol_deviation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ipa_assignment_protocol_deviation_history
                  (
                      master_id,
                      ipa_assignment_id,
                      
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ipa_assignment_protocol_deviation_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_assignment_id,
                      
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_ipa_survey_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_ipa_survey_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_ipa_survey_history
                  (
                      master_id,
                      ipa_survey_id,
                      screened_by_who,
                      screening_date,
                      select_status,
                      extra_log_type,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_ipa_survey_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_survey_id,
                      NEW.screened_by_who,
                      NEW.screening_date,
                      NEW.select_status,
                      NEW.extra_log_type,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_new_test_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_new_test_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_new_test_history
                  (
                      master_id,
                      new_test_id,
                      done_when,
                      select_result,
                      notes,
                      protocol_id,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_new_test_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.new_test_id,
                      NEW.done_when,
                      NEW.select_result,
                      NEW.notes,
                      NEW.protocol_id,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_player_contact_phone_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_player_contact_phone_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
                BEGIN
                    INSERT INTO activity_log_player_contact_phone_history
                    (
                        master_id,
                        player_contact_id,
                        data,
                        select_call_direction,
                        select_who,
                        called_when,
                        select_result,
                        select_next_step,
                        follow_up_when,
                        notes,
                        protocol_id,
                        set_related_player_contact_rank,
                        extra_log_type,
                        user_id,
                        created_at,
                        updated_at,
                        activity_log_player_contact_phone_id
                        )
                    SELECT
                        NEW.master_id,
                        NEW.player_contact_id,
                        NEW.data,
                        NEW.select_call_direction,
                        NEW.select_who,
                        NEW.called_when,
                        NEW.select_result,
                        NEW.select_next_step,
                        NEW.follow_up_when,
                        NEW.notes,
                        NEW.protocol_id,
                        NEW.set_related_player_contact_rank,
                        NEW.extra_log_type,
                        NEW.user_id,
                        NEW.created_at,
                        NEW.updated_at,
                        NEW.id
                    ;
                    RETURN NEW;
                END;
            $$;


--
-- Name: log_activity_log_player_contact_phones_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_player_contact_phones_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO activity_log_player_contact_phone_history (
    master_id,
    player_contact_id,
    data, select_call_direction, select_who, called_when, select_result, select_next_step, follow_up_when, notes, protocol_id, set_related_player_contact_rank,
    extra_log_type,
    user_id,
    created_at,
    updated_at,
    activity_log_player_contact_phone_id)
  SELECT
    NEW.master_id,
    NEW.player_contact_id,
    NEW.data, NEW.select_call_direction, NEW.select_who, NEW.called_when, NEW.select_result, NEW.select_next_step, NEW.follow_up_when, NEW.notes, NEW.protocol_id, NEW.set_related_player_contact_rank,
    NEW.extra_log_type,
    NEW.user_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: log_activity_log_player_info_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_player_info_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO activity_log_player_info_history
                  (
                      master_id,
                      player_info_id,
                      done_when,
                      notes,
                      protocol_id,
                      select_who,
                      user_id,
                      created_at,
                      updated_at,
                      activity_log_player_info_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.player_info_id,
                      NEW.done_when,
                      NEW.notes,
                      NEW.protocol_id,
                      NEW.select_who,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_activity_log_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_activity_log_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO activity_log_history
            (
                name,
                activity_log_id,
                admin_id,
                created_at,
                updated_at,
                item_type,
                rec_type,
                disabled,
                action_when_attribute,
                field_list,
                blank_log_field_list,
                blank_log_name,
                extra_log_types,
                hide_item_list_panel,
                main_log_name,
                process_name,
                table_name,
                category,
                schema_name
                )
            SELECT
                NEW.name,
                NEW.id,
                NEW.admin_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.item_type,
                NEW.rec_type,
                NEW.disabled,
                NEW.action_when_attribute,
                NEW.field_list,
                NEW.blank_log_field_list,
                NEW.blank_log_name,
                NEW.extra_log_types,
                NEW.hide_item_list_panel,
                NEW.main_log_name,
                NEW.process_name,
                NEW.table_name,
                NEW.category,
                NEW.schema_name
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_address_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_address_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO address_history 
                (
                    master_id,
                    street,
                    street2,
                    street3,
                    city,
                    state,
                    zip,
                    source,
                    rank,
                    rec_type,
                    user_id,
                    created_at,
                    updated_at,
                    country,
                    postal_code,
                    region,
                    address_id
                )
                 
            SELECT                 
                NEW.master_id,
                NEW.street,
                NEW.street2,
                NEW.street3,
                NEW.city,
                NEW.state,
                NEW.zip,
                NEW.source,
                NEW.rank,
                NEW.rec_type,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.country,
                NEW.postal_code,
                NEW.region,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_admin_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_admin_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      INSERT INTO admin_history
      (
        admin_id,
        email,
        encrypted_password,
        sign_in_count,
        current_sign_in_at,
        last_sign_in_at,
        current_sign_in_ip ,
        last_sign_in_ip ,
        created_at ,
        updated_at,
        failed_attempts,
        unlock_token,
        locked_at,
        disabled,
        encrypted_otp_secret,
        encrypted_otp_secret_iv,
        encrypted_otp_secret_salt,
        consumed_timestep,
        otp_required_for_login,
        reset_password_sent_at,
        password_updated_at,
        updated_by_admin_id

      )
      SELECT
        NEW.id,
        NEW.email,
        NEW.encrypted_password,
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
        NEW.disabled,
        NEW.encrypted_otp_secret,
        NEW.encrypted_otp_secret_iv,
        NEW.encrypted_otp_secret_salt,
        NEW.consumed_timestep,
        NEW.otp_required_for_login,
        NEW.reset_password_sent_at,
        NEW.password_updated_at,
        NEW.admin_id
        ;
        RETURN NEW;
    END;
    $$;


--
-- Name: log_app_configuration_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_app_configuration_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO app_configuration_history
                  (
                      name,
                      value,
                      app_type_id,
                      user_id,
                      role_name,
                      admin_id,
                      disabled,
                      created_at,
                      updated_at,
                      app_configuration_id
                      )
                  SELECT
                      NEW.name,
                      NEW.value,
                      NEW.app_type_id,
                      NEW.user_id,
                      NEW.role_name,
                      NEW.admin_id,
                      NEW.disabled,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_app_type_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_app_type_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
             BEGIN
                 INSERT INTO app_type_history
                 (
                     name,
                     label,
                     admin_id,
                     disabled,
                     created_at,
                     updated_at,
                     app_type_id
                     )
                 SELECT
                     NEW.name,
                     NEW.label,
                     NEW.admin_id,
                     NEW.disabled,
                     NEW.created_at,
                     NEW.updated_at,
                     NEW.id
                 ;
                 RETURN NEW;
             END;
         $$;


--
-- Name: log_bhs_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_bhs_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO bhs_assignment_history
                  (
                      master_id,
                      bhs_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      bhs_assignment_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.bhs_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_college_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_college_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO college_history
            (
                    college_id,
                    name ,
                    synonym_for_id,
                    created_at ,
                    updated_at ,
                    disabled ,
                    admin_id,
                    user_id            
                )                 
            SELECT                 
                NEW.id,
                NEW.name ,
                    NEW.synonym_for_id ,                    
                    NEW.created_at ,
                    NEW.updated_at ,
                    NEW.disabled ,
                    NEW.admin_id,
                    NEW.user_id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_config_library_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_config_library_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO config_library_history
            (
                    config_library_id,
                    category,
                    name,
                    options,
                    format,
                    disabled,
                    admin_id,
                    updated_at,
                    created_at
                )
            SELECT
                NEW.id,
                NEW.category,
                NEW.name,
                NEW.options,
                NEW.format,
                NEW.disabled,
                NEW.admin_id,
                NEW.updated_at,
                NEW.created_at
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_dynamic_model_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_dynamic_model_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
                      BEGIN
                          INSERT INTO dynamic_model_history
                          (
                              name,
                              table_name,
                              schema_name,
                              primary_key_name,
                              foreign_key_name,
                              description,
                              position,
                              category,
                              table_key_name,
                              field_list,
                              result_order,
                              options,
                              admin_id,
                              disabled,
                              created_at,
                              updated_at,
                              dynamic_model_id
                              )
                          SELECT
                              NEW.name,
                              NEW.table_name,
                              NEW.schema_name,
                              NEW.primary_key_name,
                              NEW.foreign_key_name,
                              NEW.description,
                              NEW.position,
                              NEW.category,
                              NEW.table_key_name,
                              NEW.field_list,
                              NEW.result_order,
                              NEW.options,
                              NEW.admin_id,
                              NEW.disabled,
                              NEW.created_at,
                              NEW.updated_at,
                              NEW.id
                          ;
                          RETURN NEW;
                      END;
                  $$;


--
-- Name: log_ext_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ext_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ext_assignment_history
                  (
                      master_id,
                      ext_id,
                      user_id,
                      created_at,
                      updated_at,
                      ext_assignment_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ext_id,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ext_gen_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ext_gen_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ext_gen_assignment_history
                  (
                      master_id,
                      ext_gen_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      ext_gen_assignment_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ext_gen_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_external_identifier_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_external_identifier_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
          INSERT INTO external_identifier_history
          (
              name,
              label,
              external_id_attribute,
              external_id_view_formatter,
              external_id_edit_pattern,
              prevent_edit,
              pregenerate_ids,
              min_id,
              max_id,
              alphanumeric,
              extra_fields,
              admin_id,
              disabled,
              created_at,
              updated_at,
              external_identifier_id,
              schema_name,
              options
              )
          SELECT
              NEW.name,
              NEW.label,
              NEW.external_id_attribute,
              NEW.external_id_view_formatter,
              NEW.external_id_edit_pattern,
              NEW.prevent_edit,
              NEW.pregenerate_ids,
              NEW.min_id,
              NEW.max_id,
              NEW.alphanumeric,
              NEW.extra_fields,
              NEW.admin_id,
              NEW.disabled,
              NEW.created_at,
              NEW.updated_at,
              NEW.id,
              NEW.schema_name,
              NEW.options
          ;
          RETURN NEW;
      END;
  $$;


--
-- Name: log_external_link_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_external_link_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO external_link_history
            (
                    external_link_id,                    
                    name,                    
                    value,
                    admin_id,
                    disabled,                    
                    created_at,
                    updated_at
                )                 
            SELECT                 
                NEW.id,
                NEW.name,    
                    NEW.value,                     
                    NEW.admin_id,
                    NEW.disabled,
                    NEW.created_at,
                    NEW.updated_at
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_general_selection_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_general_selection_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$        BEGIN
            INSERT INTO ml_app.general_selection_history
            (
                    general_selection_id,
                    name ,
                    value ,
                    item_type ,
                    created_at ,
                    updated_at ,
                    disabled ,
                    admin_id ,
                    create_with ,
                    edit_if_set ,
                    edit_always ,
                    position ,
                    description ,
                    lock 
                )                 
            SELECT                 
                NEW.id,
                NEW.name ,
                NEW.value ,
                NEW.item_type ,
                NEW.created_at ,
                NEW.updated_at ,
                NEW.disabled ,
                NEW.admin_id ,
                NEW.create_with ,
                NEW.edit_if_set ,
                NEW.edit_always ,
                NEW.position "position",
                NEW.description ,
                NEW.lock
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_ipa_adl_informant_screener_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_adl_informant_screener_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_adl_informant_screener_history
                  (
                      master_id,
                      select_regarding_eating,
                      select_regarding_walking,
                      select_regarding_bowel_and_bladder,
                      select_regarding_bathing,
                      select_regarding_grooming,
                      select_regarding_dressing,
                      select_regarding_dressing_performance,
                      select_regarding_getting_dressed,
                      used_telephone_yes_no_dont_know,
                      select_telephone_performance,
                      watched_tv_yes_no_dont_know,
                      selected_programs_yes_no_dont_know,
                      talk_about_content_during_yes_no_dont_know,
                      talk_about_content_after_yes_no_dont_know,
                      pay_attention_to_conversation_yes_no_dont_know,
                      select_degree_of_participation,
                      clear_dishes_yes_no_dont_know,
                      select_clear_dishes_performance,
                      find_personal_belongings_yes_no_dont_know,
                      select_find_personal_belongings_performance,
                      obtain_beverage_yes_no_dont_know,
                      select_obtain_beverage_performance,
                      make_meal_yes_no_dont_know,
                      select_make_meal_performance,
                      dispose_of_garbage_yes_no_dont_know,
                      select_dispose_of_garbage_performance,
                      get_around_outside_yes_no_dont_know,
                      select_get_around_outside_performance,
                      go_shopping_yes_no_dont_know,
                      select_go_shopping_performance,
                      pay_for_items_yes_no_dont_know,
                      keep_appointments_yes_no_dont_know,
                      select_keep_appointments_performance,
                      left_on_own_yes_no_dont_know,
                      away_from_home_yes_no_dont_know,
                      at_home_more_than_hour_yes_no_dont_know,
                      at_home_less_than_hour_yes_no_dont_know,
                      talk_about_current_events_yes_no_dont_know,
                      did_not_take_part_in_yes_no_dont_know,
                      took_part_in_outside_home_yes_no_dont_know,
                      took_part_in_at_home_yes_no_dont_know,
                      read_yes_no_dont_know,
                      talk_about_reading_shortly_after_yes_no_dont_know,
                      talk_about_reading_later_yes_no_dont_know,
                      write_yes_no_dont_know,
                      select_write_performance,
                      pastime_yes_no_dont_know,
                      multi_select_pastimes,
                      pastime_other,
                      pastimes_only_at_daycare_no_yes,
                      select_pastimes_only_at_daycare_performance,
                      use_household_appliance_yes_no_dont_know,
                      multi_select_household_appliances,
                      household_appliance_other,
                      select_household_appliance_performance,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_adl_informant_screener_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_regarding_eating,
                      NEW.select_regarding_walking,
                      NEW.select_regarding_bowel_and_bladder,
                      NEW.select_regarding_bathing,
                      NEW.select_regarding_grooming,
                      NEW.select_regarding_dressing,
                      NEW.select_regarding_dressing_performance,
                      NEW.select_regarding_getting_dressed,
                      NEW.used_telephone_yes_no_dont_know,
                      NEW.select_telephone_performance,
                      NEW.watched_tv_yes_no_dont_know,
                      NEW.selected_programs_yes_no_dont_know,
                      NEW.talk_about_content_during_yes_no_dont_know,
                      NEW.talk_about_content_after_yes_no_dont_know,
                      NEW.pay_attention_to_conversation_yes_no_dont_know,
                      NEW.select_degree_of_participation,
                      NEW.clear_dishes_yes_no_dont_know,
                      NEW.select_clear_dishes_performance,
                      NEW.find_personal_belongings_yes_no_dont_know,
                      NEW.select_find_personal_belongings_performance,
                      NEW.obtain_beverage_yes_no_dont_know,
                      NEW.select_obtain_beverage_performance,
                      NEW.make_meal_yes_no_dont_know,
                      NEW.select_make_meal_performance,
                      NEW.dispose_of_garbage_yes_no_dont_know,
                      NEW.select_dispose_of_garbage_performance,
                      NEW.get_around_outside_yes_no_dont_know,
                      NEW.select_get_around_outside_performance,
                      NEW.go_shopping_yes_no_dont_know,
                      NEW.select_go_shopping_performance,
                      NEW.pay_for_items_yes_no_dont_know,
                      NEW.keep_appointments_yes_no_dont_know,
                      NEW.select_keep_appointments_performance,
                      NEW.left_on_own_yes_no_dont_know,
                      NEW.away_from_home_yes_no_dont_know,
                      NEW.at_home_more_than_hour_yes_no_dont_know,
                      NEW.at_home_less_than_hour_yes_no_dont_know,
                      NEW.talk_about_current_events_yes_no_dont_know,
                      NEW.did_not_take_part_in_yes_no_dont_know,
                      NEW.took_part_in_outside_home_yes_no_dont_know,
                      NEW.took_part_in_at_home_yes_no_dont_know,
                      NEW.read_yes_no_dont_know,
                      NEW.talk_about_reading_shortly_after_yes_no_dont_know,
                      NEW.talk_about_reading_later_yes_no_dont_know,
                      NEW.write_yes_no_dont_know,
                      NEW.select_write_performance,
                      NEW.pastime_yes_no_dont_know,
                      NEW.multi_select_pastimes,
                      NEW.pastime_other,
                      NEW.pastimes_only_at_daycare_no_yes,
                      NEW.select_pastimes_only_at_daycare_performance,
                      NEW.use_household_appliance_yes_no_dont_know,
                      NEW.multi_select_household_appliances,
                      NEW.household_appliance_other,
                      NEW.select_household_appliance_performance,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_adverse_event_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_adverse_event_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_adverse_event_history
                  (
                      master_id,
                      select_problem_type,
                      event_occurred_when,
                      event_discovered_when,
                      select_severity,
                      select_location,
                      select_expectedness,
                      select_relatedness,
                      event_description,
                      corrective_action_description,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_adverse_event_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_problem_type,
                      NEW.event_occurred_when,
                      NEW.event_discovered_when,
                      NEW.select_severity,
                      NEW.select_location,
                      NEW.select_expectedness,
                      NEW.select_relatedness,
                      NEW.event_description,
                      NEW.corrective_action_description,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_assignment_history
                  (
                      master_id,
                      ipa_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      ipa_assignment_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.ipa_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_consent_mailing_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_consent_mailing_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_consent_mailing_history
                  (
                      master_id,
                      select_record_from_player_contact_email,
                      select_record_from_addresses,
                      sent_when,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_consent_mailing_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_record_from_player_contact_email,
                      NEW.select_record_from_addresses,
                      NEW.sent_when,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_hotel_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_hotel_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_hotel_history
                  (
                      master_id,
                      hotel,
                      room_number,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_hotel_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.hotel,
                      NEW.room_number,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_inex_checklist_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_inex_checklist_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_inex_checklist_history
                  (
                      master_id,
                      fixed_checklist_type,
                      ix_consent_blank_yes_no,
                      ix_consent_details,
                      ix_not_pro_blank_yes_no,
                      ix_not_pro_details,
                      ix_age_range_blank_yes_no,
                      ix_age_range_details,
                      ix_weight_ok_blank_yes_no,
                      ix_weight_ok_details,
                      ix_no_seizure_blank_yes_no,
                      ix_no_seizure_details,
                      ix_no_device_impl_blank_yes_no,
                      ix_no_device_impl_details,
                      ix_no_ferromagnetic_impl_blank_yes_no,
                      ix_no_ferromagnetic_impl_details,
                      ix_diagnosed_sleep_apnea_blank_yes_no,
                      ix_diagnosed_sleep_apnea_details,
                      ix_diagnosed_heart_stroke_or_meds_blank_yes_no,
                      ix_diagnosed_heart_stroke_or_meds_details,
                      ix_chronic_pain_and_meds_blank_yes_no,
                      ix_chronic_pain_and_meds_details,
                      ix_tmoca_score_blank_yes_no,
                      ix_tmoca_score_details,
                      ix_no_hemophilia_blank_yes_no,
                      ix_no_hemophilia_details,
                      ix_raynauds_ok_blank_yes_no,
                      ix_raynauds_ok_details,
                      ix_mi_ok_blank_yes_no,
                      ix_mi_ok_details,
                      ix_bicycle_ok_blank_yes_no,
                      ix_bicycle_ok_details,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_inex_checklist_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.fixed_checklist_type,
                      NEW.ix_consent_blank_yes_no,
                      NEW.ix_consent_details,
                      NEW.ix_not_pro_blank_yes_no,
                      NEW.ix_not_pro_details,
                      NEW.ix_age_range_blank_yes_no,
                      NEW.ix_age_range_details,
                      NEW.ix_weight_ok_blank_yes_no,
                      NEW.ix_weight_ok_details,
                      NEW.ix_no_seizure_blank_yes_no,
                      NEW.ix_no_seizure_details,
                      NEW.ix_no_device_impl_blank_yes_no,
                      NEW.ix_no_device_impl_details,
                      NEW.ix_no_ferromagnetic_impl_blank_yes_no,
                      NEW.ix_no_ferromagnetic_impl_details,
                      NEW.ix_diagnosed_sleep_apnea_blank_yes_no,
                      NEW.ix_diagnosed_sleep_apnea_details,
                      NEW.ix_diagnosed_heart_stroke_or_meds_blank_yes_no,
                      NEW.ix_diagnosed_heart_stroke_or_meds_details,
                      NEW.ix_chronic_pain_and_meds_blank_yes_no,
                      NEW.ix_chronic_pain_and_meds_details,
                      NEW.ix_tmoca_score_blank_yes_no,
                      NEW.ix_tmoca_score_details,
                      NEW.ix_no_hemophilia_blank_yes_no,
                      NEW.ix_no_hemophilia_details,
                      NEW.ix_raynauds_ok_blank_yes_no,
                      NEW.ix_raynauds_ok_details,
                      NEW.ix_mi_ok_blank_yes_no,
                      NEW.ix_mi_ok_details,
                      NEW.ix_bicycle_ok_blank_yes_no,
                      NEW.ix_bicycle_ok_details,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_initial_screening_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_initial_screening_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_initial_screening_history
                  (
                      master_id,
                      select_is_good_time_to_speak,
                      select_looked_at_website_yes_no,
                      select_may_i_begin,
                      any_questions_blank_yes_no,
                      select_still_interested,
                      follow_up_date,
                      follow_up_time,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_initial_screening_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_is_good_time_to_speak,
                      NEW.select_looked_at_website_yes_no,
                      NEW.select_may_i_begin,
                      NEW.any_questions_blank_yes_no,
                      NEW.select_still_interested,
                      NEW.follow_up_date,
                      NEW.follow_up_time,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_payment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_payment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_payment_history
                  (
                      master_id,
                      select_type,
                      sent_date,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_payment_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_type,
                      NEW.sent_date,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_protocol_deviation_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_protocol_deviation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_protocol_deviation_history
                  (
                      master_id,
                      deviation_occurred_when,
                      deviation_discovered_when,
                      select_severity,
                      deviation_description,
                      corrective_action_description,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_protocol_deviation_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.deviation_occurred_when,
                      NEW.deviation_discovered_when,
                      NEW.select_severity,
                      NEW.deviation_description,
                      NEW.corrective_action_description,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_football_experience_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_football_experience_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_football_experience_history
                  (
                      master_id,
                      age,
                      played_in_nfl_blank_yes_no,
                      played_before_nfl_blank_yes_no,
                      football_experience_notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_football_experience_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.age,
                      NEW.played_in_nfl_blank_yes_no,
                      NEW.played_before_nfl_blank_yes_no,
                      NEW.football_experience_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_health_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_health_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_health_history
                  (
                      master_id,
                      physical_limitations_blank_yes_no,
                      physical_limitations_details,
                      sit_back_blank_yes_no,
                      sit_back_details,
                      cycle_blank_yes_no,
                      cycle_details,
                      chronic_pain_blank_yes_no,
                      chronic_pain_details,
                      chronic_pain_meds_blank_yes_no_dont_know,
                      chronic_pain_meds_details,
                      hemophilia_blank_yes_no_dont_know,
                      hemophilia_details,
                      raynauds_syndrome_blank_yes_no_dont_know,
                      raynauds_syndrome_severity_selection,
                      raynauds_syndrome_details,

                      hypertension_diagnosis_blank_yes_no_dont_know,
                      hypertension_medications_blank_yes_no,
                      hypertension_diagnosis_details,

                      diabetes_diagnosis_blank_yes_no_dont_know,
                      diabetes_medications_blank_yes_no,
                      diabetes_diagnosis_details,

                      high_cholesterol_diagnosis_blank_yes_no_dont_know,
                      high_cholesterol_medications_blank_yes_no,
                      high_cholesterol_diagnosis_details,

                      other_heart_conditions_blank_yes_no_dont_know,
                      other_heart_conditions_details,

                      heart_surgeries_blank_yes_no_dont_know,
                      heart_surgeries_details,
                      caridiac_pacemaker_blank_yes_no_dont_know,
                      caridiac_pacemaker_details,

                      memory_problems_blank_yes_no_dont_know,
                      memory_problems_details,
                      mental_health_conditions_blank_yes_no_dont_know,
                      mental_health_conditions_details,

                      mental_health_help_blank_yes_no_dont_know,
                      mental_health_help_details,

                      neurological_problems_blank_yes_no_dont_know,
                      neurological_problems_details,

                      neurological_surgeries_blank_yes_no_dont_know,
                      neurological_surgeries_details,

                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_health_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.physical_limitations_blank_yes_no,
                      NEW.physical_limitations_details,
                      NEW.sit_back_blank_yes_no,
                      NEW.sit_back_details,
                      NEW.cycle_blank_yes_no,
                      NEW.cycle_details,
                      NEW.chronic_pain_blank_yes_no,
                      NEW.chronic_pain_details,
                      NEW.chronic_pain_meds_blank_yes_no_dont_know,
                      NEW.chronic_pain_meds_details,
                      NEW.hemophilia_blank_yes_no_dont_know,
                      NEW.hemophilia_details,
                      NEW.raynauds_syndrome_blank_yes_no_dont_know,
                      NEW.raynauds_syndrome_severity_selection,
                      NEW.raynauds_syndrome_details,

                      NEW.hypertension_diagnosis_blank_yes_no_dont_know,
                      NEW.hypertension_medications_blank_yes_no,
                      NEW.hypertension_diagnosis_details,

                      NEW.diabetes_diagnosis_blank_yes_no_dont_know,
                      NEW.diabetes_medications_blank_yes_no,
                      NEW.diabetes_diagnosis_details,

                      NEW.high_cholesterol_diagnosis_blank_yes_no_dont_know,
                      NEW.high_cholesterol_medications_blank_yes_no,
                      NEW.high_cholesterol_diagnosis_details,

                      NEW.other_heart_conditions_blank_yes_no_dont_know,
                      NEW.other_heart_conditions_details,

                      NEW.heart_surgeries_blank_yes_no_dont_know,
                      NEW.heart_surgeries_details,
                      NEW.caridiac_pacemaker_blank_yes_no_dont_know,
                      NEW.caridiac_pacemaker_details,

                      NEW.memory_problems_blank_yes_no_dont_know,
                      NEW.memory_problems_details,
                      NEW.mental_health_conditions_blank_yes_no_dont_know,
                      NEW.mental_health_conditions_details,

                      NEW.mental_health_help_blank_yes_no_dont_know,
                      NEW.mental_health_help_details,

                      NEW.neurological_problems_blank_yes_no_dont_know,
                      NEW.neurological_problems_details,

                      NEW.neurological_surgeries_blank_yes_no_dont_know,
                      NEW.neurological_surgeries_details,

                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_initial_screening_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_initial_screening_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_initial_screening_history
                  (
                      master_id,
                      select_is_good_time_to_speak,
                      looked_at_website_yes_no,
                      select_may_i_begin,
                      any_questions_blank_yes_no,
                      --- Note we retain select_still_interested since it is used in the withdrawal logic
                      select_still_interested,
                      follow_up_date,
                      follow_up_time,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_initial_screening_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_is_good_time_to_speak,
                      NEW.looked_at_website_yes_no,
                      NEW.select_may_i_begin,
                      NEW.any_questions_blank_yes_no,
                      NEW.select_still_interested,
                      NEW.follow_up_date,
                      NEW.follow_up_time,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_mri_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_mri_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_mri_history
                  (
                      master_id,
                      past_mri_yes_no_dont_know,
                      past_mri_details,
                      electrical_implants_blank_yes_no_dont_know,
                      electrical_implants_details,
                      metal_implants_blank_yes_no_dont_know,
                      metal_implants_details,
                      metal_jewelry_blank_yes_no,
                      hearing_aid_blank_yes_no,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_mri_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.past_mri_yes_no_dont_know,
                      NEW.past_mri_details,
                      NEW.electrical_implants_blank_yes_no_dont_know,
                      NEW.electrical_implants_details,
                      NEW.metal_implants_blank_yes_no_dont_know,
                      NEW.metal_implants_details,
                      NEW.metal_jewelry_blank_yes_no,
                      NEW.hearing_aid_blank_yes_no,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_size_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_size_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_size_history
                  (
                      master_id,
                      birth_date,
                      weight,
                      height,
                      hat_size,
                      shirt_size,
                      jacket_size,
                      waist_size,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_size_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.birth_date,
                      NEW.weight,
                      NEW.height,
                      NEW.hat_size,
                      NEW.shirt_size,
                      NEW.jacket_size,
                      NEW.waist_size,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_sleep_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_sleep_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_sleep_history
                  (
                      master_id,
                      sleep_disorder_blank_yes_no_dont_know,
                      sleep_disorder_details,
                      sleep_apnea_device_no_yes,
                      sleep_apnea_device_details,
                      bed_and_wake_time_details,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_sleep_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.sleep_disorder_blank_yes_no_dont_know,
                      NEW.sleep_disorder_details,
                      NEW.sleep_apnea_device_no_yes,
                      NEW.sleep_apnea_device_details,
                      NEW.bed_and_wake_time_details,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_ps_tmoca_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_tmoca_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_tmoca_history
                  (
                      master_id,
                      tmoca_version,
                      attn_digit_span,
                      attn_digit_vigilance,
                      attn_digit_calculation,
                      language_repeat,
                      language_fluency,
                      abstraction,
                      delayed_recall,
                      orientation,
                      tmoca_score,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_tmoca_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.tmoca_version,
                      NEW.attn_digit_span,
                      NEW.attn_digit_vigilance,
                      NEW.attn_digit_calculation,
                      NEW.language_repeat,
                      NEW.language_fluency,
                      NEW.abstraction,
                      NEW.delayed_recall,
                      NEW.orientation,
                      NEW.tmoca_score,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
            END;
          $$;


--
-- Name: log_ipa_ps_tms_test_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_ps_tms_test_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_ps_tms_test_history
                  (
                      master_id,
                      convulsion_or_seizure_blank_yes_no_dont_know,
                      epilepsy_blank_yes_no_dont_know,
                      fainting_blank_yes_no_dont_know,
                      concussion_blank_yes_no_dont_know,
                      loss_of_conciousness_details,
                      hearing_problems_blank_yes_no_dont_know,
                      cochlear_implants_blank_yes_no_dont_know,
                      metal_blank_yes_no_dont_know,
                      metal_details,
                      neurostimulator_blank_yes_no_dont_know,
                      neurostimulator_details,
                      med_infusion_device_blank_yes_no_dont_know,
                      med_infusion_device_details,
                      past_tms_blank_yes_no_dont_know,
                      past_tms_details,
                      current_meds_blank_yes_no_dont_know,
                      current_meds_details,
                      other_chronic_problems_blank_yes_no_dont_know,
                      other_chronic_problems_details,
                      hospital_visits_blank_yes_no_dont_know,
                      hospital_visits_details,
                      dietary_restrictions_blank_yes_no_dont_know,
                      dietary_restrictions_details,
                      anything_else_blank_yes_no,
                      anything_else_details,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_ps_tms_test_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.convulsion_or_seizure_blank_yes_no_dont_know,
                      NEW.epilepsy_blank_yes_no_dont_know,
                      NEW.fainting_blank_yes_no_dont_know,
                      NEW.concussion_blank_yes_no_dont_know,
                      NEW.loss_of_conciousness_details,
                      NEW.hearing_problems_blank_yes_no_dont_know,
                      NEW.cochlear_implants_blank_yes_no_dont_know,
                      NEW.metal_blank_yes_no_dont_know,
                      NEW.metal_details,
                      NEW.neurostimulator_blank_yes_no_dont_know,
                      NEW.neurostimulator_details,
                      NEW.med_infusion_device_blank_yes_no_dont_know,
                      NEW.med_infusion_device_details,
                      NEW.past_tms_blank_yes_no_dont_know,
                      NEW.past_tms_details,
                      NEW.current_meds_blank_yes_no_dont_know,
                      NEW.current_meds_details,
                      NEW.other_chronic_problems_blank_yes_no_dont_know,
                      NEW.other_chronic_problems_details,
                      NEW.hospital_visits_blank_yes_no_dont_know,
                      NEW.hospital_visits_details,
                      NEW.dietary_restrictions_blank_yes_no_dont_know,
                      NEW.dietary_restrictions_details,
                      NEW.anything_else_blank_yes_no,
                      NEW.anything_else_details,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_station_contact_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_station_contact_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_station_contact_history
                  (
                      first_name,
                      last_name,
                      role,
                      select_availability,
                      phone,
                      alt_phone,
                      email,
                      alt_email,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_station_contact_id
                      )
                  SELECT
                      NEW.first_name,
                      NEW.last_name,
                      NEW.role,
                      NEW.phone,
                      NEW.select_availability,
                      NEW.alt_phone,
                      NEW.email,
                      NEW.alt_email,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_survey_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_survey_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_survey_history
                  (
                      master_id,
                      select_survey_type,
                      sent_date,
                      completed_date,
                      send_next_survey_when,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_survey_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_survey_type,
                      NEW.sent_date,
                      NEW.completed_date,
                      NEW.send_next_survey_when,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_transportation_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_transportation_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO ipa_transportation_history
                  (
                      master_id,
                      travel_date,
                      travel_confirmed_no_yes,
                      select_direction,
                      origin_city_and_state,
                      destination_city_and_state,
                      select_mode_of_transport,
                      airline,
                      flight_number,
                      departure_time,
                      arrival_time,
                      notes,
                      user_id,
                      created_at,
                      updated_at,
                      ipa_transportation_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.travel_date,
                      NEW.travel_confirmed_no_yes,
                      NEW.select_direction,
                      NEW.origin_city_and_state,
                      NEW.destination_city_and_state,
                      NEW.select_mode_of_transport,
                      NEW.airline,
                      NEW.flight_number,
                      NEW.departure_time,
                      NEW.arrival_time,
                      NEW.notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_ipa_withdrawal_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_ipa_withdrawal_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO ipa_withdrawal_history
            (
                master_id,
                select_subject_withdrew_reason,
                select_investigator_terminated,
                lost_to_follow_up_no_yes,
                no_longer_participating_no_yes,
                notes,
                user_id,
                created_at,
                updated_at,
                ipa_withdrawal_id
                )
            SELECT
                NEW.master_id,
                NEW.select_subject_withdrew_reason,
                NEW.select_investigator_terminated,
                NEW.lost_to_follow_up_no_yes,
                NEW.no_longer_participating_no_yes,
                NEW.notes,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_item_flag_name_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_item_flag_name_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO item_flag_name_history
            (
                    item_flag_name_id,
                    name ,
                    item_type,
                    created_at ,
                    updated_at ,
                    disabled ,
                    admin_id
                )                 
            SELECT                 
                NEW.id,
                NEW.name ,
                    NEW.item_type ,                    
                    NEW.created_at ,
                    NEW.updated_at ,
                    NEW.disabled ,
                    NEW.admin_id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_item_flag_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_item_flag_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO item_flag_history
            (
                    item_flag_id,
                    item_id ,
                    item_type,
                    item_flag_name_id,
                    created_at ,
                    updated_at ,
                    user_id ,
                    disabled
                )                 
            SELECT                 
                NEW.id,
                NEW.item_id ,
                    NEW.item_type,
                    NEW.item_flag_name_id,
                    NEW.created_at ,
                    NEW.updated_at ,
                    NEW.user_id ,
                    NEW.disabled
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_message_template_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_message_template_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
                  BEGIN
                      INSERT INTO message_template_history
                      (
                          name,
                          template_type,
                          message_type,
                          template,
                          category,
                          admin_id,
                          disabled,
                          created_at,
                          updated_at,
                          message_template_id
                          )
                      SELECT
                          NEW.name,
                          NEW.template_type,
                          NEW.message_type,
                          NEW.template,
                          NEW.category,
                          NEW.admin_id,
                          NEW.disabled,
                          NEW.created_at,
                          NEW.updated_at,
                          NEW.id
                      ;
                      RETURN NEW;
                  END;
              $$;


--
-- Name: log_mrn_number_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_mrn_number_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO mrn_number_history
                  (
                      master_id,
                      mrn_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      mrn_number_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.mrn_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_new_test_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_new_test_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO new_test_history
                  (
                      master_id,
                      new_test_ext_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      new_test_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.new_test_ext_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_nfs_store_archived_file_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_nfs_store_archived_file_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO nfs_store_archived_file_history
            (
                file_hash,
                file_name,
                content_type,
                archive_file,
                path,
                file_size,
                file_updated_at,
                nfs_store_container_id,
                title,
                description,
                file_metadata,
                nfs_store_stored_file_id,
                user_id,
                created_at,
                updated_at,
                nfs_store_archived_file_id,
                embed_resource_name,
                embed_resource_id
                )
            SELECT
                NEW.file_hash,
                NEW.file_name,
                NEW.content_type,
                NEW.archive_file,
                NEW.path,
                NEW.file_size,
                NEW.file_updated_at,
                NEW.nfs_store_container_id,
                NEW.title,
                NEW.description,
                NEW.file_metadata,
                NEW.nfs_store_stored_file_id,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.id,
                NEW.embed_resource_name,
                NEW.embed_resource_id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_nfs_store_container_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_nfs_store_container_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO nfs_store_container_history
            (
                master_id,
                name,
                app_type_id,
                orig_nfs_store_container_id,
                created_by_user_id,
                user_id,
                created_at,
                updated_at,
                nfs_store_container_id
                )
            SELECT
                NEW.master_id,
                NEW.name,
                NEW.app_type_id,
                NEW.nfs_store_container_id,
                NEW.created_by_user_id,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_nfs_store_filter_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_nfs_store_filter_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO nfs_store_filter_history
            (
                app_type_id,
                role_name,
                user_id,
                resource_name,
                filter,
                description,
                admin_id,
                disabled,
                created_at,
                updated_at,
                nfs_store_filter_id
                )
            SELECT
                NEW.app_type_id,
                NEW.role_name,
                NEW.user_id,
                NEW.resource_name,
                NEW.filter,
                NEW.description,
                NEW.admin_id,
                NEW.disabled,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_nfs_store_stored_file_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_nfs_store_stored_file_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO nfs_store_stored_file_history
            (
                file_hash,
                file_name,
                content_type,
                path,
                file_size,
                file_updated_at,
                nfs_store_container_id,
                title,
                description,
                file_metadata,
                last_process_name_run,
                user_id,
                created_at,
                updated_at,
                nfs_store_stored_file_id,
                embed_resource_name,
                embed_resource_id
                )
            SELECT
                NEW.file_hash,
                NEW.file_name,
                NEW.content_type,
                NEW.path,
                NEW.file_size,
                NEW.file_updated_at,
                NEW.nfs_store_container_id,
                NEW.title,
                NEW.description,
                NEW.file_metadata,
                NEW.last_process_name_run,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.id,
                NEW.embed_resource_name,
                NEW.embed_resource_id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_page_layout_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_page_layout_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
          BEGIN
              INSERT INTO page_layout_history
              (
                      page_layout_id,
                      app_type_id,
                      layout_name,
                      panel_name,
                      panel_label,
                      panel_position,
                      options,
                      disabled,
                      admin_id,
                      created_at,
                      updated_at,
                      description
                  )
              SELECT
                  NEW.id,
                  NEW.app_type_id,
                  NEW.layout_name,
                  NEW.panel_name,
                  NEW.panel_label,
                  NEW.panel_position,
                  NEW.options,
                  NEW.disabled,
                  NEW.admin_id,
                  NEW.created_at,
                  NEW.updated_at,
                  NEW.description
              ;
              RETURN NEW;
          END;
      $$;


--
-- Name: log_player_contact_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_player_contact_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO player_contact_history
            (
                    player_contact_id,
                    master_id,
                    rec_type,
                    data,
                    source,
                    rank,
                    user_id,
                    created_at,
                    updated_at
                )                 
            SELECT                 
                NEW.id,
                NEW.master_id,
                NEW.rec_type,
                NEW.data,
                NEW.source,
                NEW.rank,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_player_info_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_player_info_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
 BEGIN
 INSERT INTO player_info_history
 (
 master_id,
 first_name,
 last_name,
 middle_name,
 nick_name,
 birth_date,
 death_date,
 user_id,
 created_at,
 updated_at,
 contact_pref,
 start_year,
 rank,
 notes,
 contact_id,
 college,
 end_year,
 source,
 player_info_id
 ) 
 SELECT
 NEW.master_id,
 NEW.first_name,
 NEW.last_name,
 NEW.middle_name,
 NEW.nick_name,
 NEW.birth_date,
 NEW.death_date,
 NEW.user_id,
 NEW.created_at,
 NEW.updated_at,
 NEW.contact_pref,
 NEW.start_year,
 NEW.rank,
 NEW.notes,
 NEW.contact_id,
 NEW.college,
 NEW.end_year, 
 NEW.source, 
 NEW.id
 ;
 RETURN NEW;
 END;
 $$;


--
-- Name: log_protocol_event_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_protocol_event_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO protocol_event_history
            (
                    protocol_event_id,                    
    name ,
    admin_id,
    created_at,
    updated_at,
    disabled ,
    sub_process_id,
    milestone ,
    description

                )                 
            SELECT                 
                NEW.id,
                NEW.name ,                    
                    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.disabled ,
    NEW.sub_process_id,
    NEW.milestone ,
    NEW.description
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_protocol_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_protocol_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO protocol_history
            (
                    protocol_id,
                    name ,                    
                    created_at ,
                    updated_at ,
                    disabled,
                    admin_id ,
                    "position"
                )                 
            SELECT                 
                NEW.id,
                NEW.name ,                    
                    NEW.created_at ,
                    NEW.updated_at ,
                    NEW.disabled,
                    NEW.admin_id ,
                    NEW.position
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_report_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_report_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO report_history
            (
                    report_id,
                    name,
                    description,
                    sql,
                    search_attrs,
                    admin_id,
                    disabled,
                    report_type,
                    auto,
                    searchable,
                    position,
                    created_at,
                    updated_at,
                    edit_field_names,
                    selection_fields,
                    item_type,
                    short_name,
                    options
                )
            SELECT
                NEW.id,
                NEW.name,
                NEW.description,
                NEW.sql,
                NEW.search_attrs,
                NEW.admin_id,
                NEW.disabled,
                NEW.report_type,
                NEW.auto,
                NEW.searchable,
                NEW.position,
                NEW.created_at,
                NEW.updated_at,
                NEW.edit_field_names,
                NEW.selection_fields,
                NEW.item_type,
                NEW.short_name,
                NEW.options
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_sage_two_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_sage_two_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO sage_two_history
            (
                    sage_two_id,                    
                    external_id,
                    user_id,
                    created_at,
                    updated_at
                )                 
            SELECT                 
                NEW.id,
                NEW.external_id,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at 
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_scantron_q2_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_scantron_q2_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO scantron_q2_history
                  (
                      master_id,
                      q2_scantron_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      scantron_q2_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.q2_scantron_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_scantron_series_two_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_scantron_series_two_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO scantron_series_two_history
            (
                    scantron_series_two_id,                    
                    external_id,
                    user_id,
                    created_at,
                    updated_at
                )                 
            SELECT                 
                NEW.id,
                NEW.external_id,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at 
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_scantron_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_scantron_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO scantron_history
            (
                master_id,
                scantron_id,
                user_id,
                created_at,
                updated_at,
                scantron_table_id
                )                 
            SELECT
                NEW.master_id,
                NEW.scantron_id,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_sleep_assignment_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_sleep_assignment_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO sleep_assignment_history
                  (
                      master_id,
                      sleep_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      sleep_assignment_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.sleep_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_sub_process_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_sub_process_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO sub_process_history
            (
                    sub_process_id,                    
    
    name,
    disabled,
    protocol_id,
    admin_id ,
    created_at,
    updated_at

                )                 
            SELECT                 
                NEW.id,
                NEW.name,
    NEW.disabled,
    NEW.protocol_id,
    NEW.admin_id ,
    NEW.created_at,
    NEW.updated_at
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_test1_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test1_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test1_history
                  (
                      master_id,
                      test1_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      test1_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.test1_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test2_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test2_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test2_history
                  (
                      master_id,
                      test_2ext_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      test2_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.test_2ext_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_2_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_2_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_2_history
                  (
                      master_id,
                      test_2ext_id,
                      user_id,
                      admin_id,
                      created_at,
                      updated_at,
                      test_2_table_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.test_2ext_id,
                      NEW.user_id,
                      NEW.admin_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_exit_interview_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_exit_interview_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_exit_interview_history
                  (
                      master_id,
                      select_all_results_returned,
                      notes,
                      labs_returned_yes_no,
                      labs_notes,
                      dexa_returned_yes_no,
                      dexa_notes,
                      brain_mri_returned_yes_no,
                      brain_mri_notes,
                      neuro_psych_returned_yes_no,
                      neuro_psych_notes,
                      assisted_finding_provider_yes_no,
                      assistance_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_exit_interview_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_all_results_returned,
                      NEW.notes,
                      NEW.labs_returned_yes_no,
                      NEW.labs_notes,
                      NEW.dexa_returned_yes_no,
                      NEW.dexa_notes,
                      NEW.brain_mri_returned_yes_no,
                      NEW.brain_mri_notes,
                      NEW.neuro_psych_returned_yes_no,
                      NEW.neuro_psych_notes,
                      NEW.assisted_finding_provider_yes_no,
                      NEW.assistance_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_four_wk_followup_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_four_wk_followup_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_four_wk_followup_history
                  (
                      master_id,
                      select_all_results_returned,
                      select_sensory_testing_returned,
                      sensory_testing_notes,
                      select_liver_mri_returned,
                      liver_mri_notes,
                      select_physical_function_returned,
                      physical_function_notes,
                      select_eeg_returned,
                      eeg_notes,
                      select_sleep_returned,
                      sleep_notes,
                      select_cardiology_returned,
                      cardiology_notes,
                      select_xray_returned,
                      xray_notes,
                      assisted_finding_provider_yes_no,
                      assistance_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_four_wk_followup_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.select_all_results_returned,
                      NEW.select_sensory_testing_returned,
                      NEW.sensory_testing_notes,
                      NEW.select_liver_mri_returned,
                      NEW.liver_mri_notes,
                      NEW.select_physical_function_returned,
                      NEW.physical_function_notes,
                      NEW.select_eeg_returned,
                      NEW.eeg_notes,
                      NEW.select_sleep_returned,
                      NEW.sleep_notes,
                      NEW.select_cardiology_returned,
                      NEW.cardiology_notes,
                      NEW.select_xray_returned,
                      NEW.xray_notes,
                      NEW.assisted_finding_provider_yes_no,
                      NEW.assistance_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_incidental_finding_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_incidental_finding_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_incidental_finding_history
                  (
                      master_id,
                      anthropometrics_check,
                      anthropometrics_date,
                      anthropometrics_notes,
                      lab_results_check,
                      lab_results_date,
                      lab_results_notes,
                      dexa_check,
                      dexa_date,
                      dexa_notes,
                      brain_mri_check,
                      brain_mri_date,
                      brain_mri_notes,
                      neuro_psych_check,
                      neuro_psych_date,
                      neuro_psych_notes,
                      sensory_testing_check,
                      sensory_testing_date,
                      sensory_testing_notes,
                      liver_mri_check,
                      liver_mri_date,
                      liver_mri_notes,
                      physical_function_check,
                      physical_function_date,
                      physical_function_notes,
                      eeg_check,
                      eeg_date,
                      eeg_notes,
                      sleep_check,
                      sleep_date,
                      sleep_notes,
                      cardiac_check,
                      cardiac_date,
                      cardiac_notes,
                      xray_check,
                      xray_date,
                      xray_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_incidental_finding_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.anthropometrics_check,
                      NEW.anthropometrics_date,
                      NEW.anthropometrics_notes,
                      NEW.lab_results_check,
                      NEW.lab_results_date,
                      NEW.lab_results_notes,
                      NEW.dexa_check,
                      NEW.dexa_date,
                      NEW.dexa_notes,
                      NEW.brain_mri_check,
                      NEW.brain_mri_date,
                      NEW.brain_mri_notes,
                      NEW.neuro_psych_check,
                      NEW.neuro_psych_date,
                      NEW.neuro_psych_notes,
                      NEW.sensory_testing_check,
                      NEW.sensory_testing_date,
                      NEW.sensory_testing_notes,
                      NEW.liver_mri_check,
                      NEW.liver_mri_date,
                      NEW.liver_mri_notes,
                      NEW.physical_function_check,
                      NEW.physical_function_date,
                      NEW.physical_function_notes,
                      NEW.eeg_check,
                      NEW.eeg_date,
                      NEW.eeg_notes,
                      NEW.sleep_check,
                      NEW.sleep_date,
                      NEW.sleep_notes,
                      NEW.cardiac_check,
                      NEW.cardiac_date,
                      NEW.cardiac_notes,
                      NEW.xray_check,
                      NEW.xray_date,
                      NEW.xray_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_mednav_followup_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_mednav_followup_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_mednav_followup_history
                  (
                      master_id,
                      anthropometrics_check,
                      anthropometrics_notes,
                      lab_results_check,
                      lab_results_notes,
                      dexa_check,
                      dexa_notes,
                      brain_mri_check,
                      brain_mri_notes,
                      neuro_psych_check,
                      neuro_psych_notes,
                      sensory_testing_check,
                      sensory_testing_notes,
                      liver_mri_check,
                      liver_mri_notes,
                      physical_function_check,
                      physical_function_notes,
                      eeg_check,
                      eeg_notes,
                      sleep_check,
                      sleep_notes,
                      cardiac_check,
                      cardiac_notes,
                      xray_check,
                      xray_notes,
                      assisted_finding_provider_yes_no,
                      assistance_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_mednav_followup_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.anthropometrics_check,
                      NEW.anthropometrics_notes,
                      NEW.lab_results_check,
                      NEW.lab_results_notes,
                      NEW.dexa_check,
                      NEW.dexa_notes,
                      NEW.brain_mri_check,
                      NEW.brain_mri_notes,
                      NEW.neuro_psych_check,
                      NEW.neuro_psych_notes,
                      NEW.sensory_testing_check,
                      NEW.sensory_testing_notes,
                      NEW.liver_mri_check,
                      NEW.liver_mri_notes,
                      NEW.physical_function_check,
                      NEW.physical_function_notes,
                      NEW.eeg_check,
                      NEW.eeg_notes,
                      NEW.sleep_check,
                      NEW.sleep_notes,
                      NEW.cardiac_check,
                      NEW.cardiac_notes,
                      NEW.xray_check,
                      NEW.xray_notes,
                      NEW.assisted_finding_provider_yes_no,
                      NEW.assistance_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_mednav_provider_comm_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_mednav_provider_comm_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_mednav_provider_comm_history
                  (
                      master_id,
                      anthropometrics_check,
                      anthropometrics_notes,
                      lab_results_check,
                      lab_results_notes,
                      dexa_check,
                      dexa_notes,
                      brain_mri_check,
                      brain_mri_notes,
                      neuro_psych_check,
                      neuro_psych_notes,
                      sensory_testing_check,
                      sensory_testing_notes,
                      liver_mri_check,
                      liver_mri_notes,
                      physical_function_check,
                      physical_function_notes,
                      eeg_check,
                      eeg_notes,
                      sleep_check,
                      sleep_notes,
                      cardiac_check,
                      cardiac_notes,
                      xray_check,
                      xray_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_mednav_provider_comm_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.anthropometrics_check,
                      NEW.anthropometrics_notes,
                      NEW.lab_results_check,
                      NEW.lab_results_notes,
                      NEW.dexa_check,
                      NEW.dexa_notes,
                      NEW.brain_mri_check,
                      NEW.brain_mri_notes,
                      NEW.neuro_psych_check,
                      NEW.neuro_psych_notes,
                      NEW.sensory_testing_check,
                      NEW.sensory_testing_notes,
                      NEW.liver_mri_check,
                      NEW.liver_mri_notes,
                      NEW.physical_function_check,
                      NEW.physical_function_notes,
                      NEW.eeg_check,
                      NEW.eeg_notes,
                      NEW.sleep_check,
                      NEW.sleep_notes,
                      NEW.cardiac_check,
                      NEW.cardiac_notes,
                      NEW.xray_check,
                      NEW.xray_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_mednav_provider_report_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_mednav_provider_report_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_mednav_provider_report_history
                  (
                      master_id,
                      report_delivery_date,
                      anthropometrics_check,
                      anthropometrics_notes,
                      lab_results_check,
                      lab_results_notes,
                      dexa_check,
                      dexa_notes,
                      brain_mri_check,
                      brain_mri_notes,
                      neuro_psych_check,
                      neuro_psych_notes,
                      sensory_testing_check,
                      sensory_testing_notes,
                      liver_mri_check,
                      liver_mri_notes,
                      physical_function_check,
                      physical_function_notes,
                      eeg_check,
                      eeg_notes,
                      sleep_check,
                      sleep_notes,
                      cardiac_check,
                      cardiac_notes,
                      xray_check,
                      xray_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_mednav_provider_report_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.report_delivery_date,
                      NEW.anthropometrics_check,
                      NEW.anthropometrics_notes,
                      NEW.lab_results_check,
                      NEW.lab_results_notes,
                      NEW.dexa_check,
                      NEW.dexa_notes,
                      NEW.brain_mri_check,
                      NEW.brain_mri_notes,
                      NEW.neuro_psych_check,
                      NEW.neuro_psych_notes,
                      NEW.sensory_testing_check,
                      NEW.sensory_testing_notes,
                      NEW.liver_mri_check,
                      NEW.liver_mri_notes,
                      NEW.physical_function_check,
                      NEW.physical_function_notes,
                      NEW.eeg_check,
                      NEW.eeg_notes,
                      NEW.sleep_check,
                      NEW.sleep_notes,
                      NEW.cardiac_check,
                      NEW.cardiac_notes,
                      NEW.xray_check,
                      NEW.xray_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_baseline_study_two_wk_followup_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_baseline_study_two_wk_followup_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
              BEGIN
                  INSERT INTO test_baseline_study_two_wk_followup_history
                  (
                      master_id,
                      participant_had_qs_yes_no,
                      participant_qs_notes,
                      assisted_finding_provider_yes_no,
                      assistance_notes,
                      other_notes,
                      user_id,
                      created_at,
                      updated_at,
                      test_baseline_study_two_wk_followup_id
                      )
                  SELECT
                      NEW.master_id,
                      NEW.participant_had_qs_yes_no,
                      NEW.participant_qs_notes,
                      NEW.assisted_finding_provider_yes_no,
                      NEW.assistance_notes,
                      NEW.other_notes,
                      NEW.user_id,
                      NEW.created_at,
                      NEW.updated_at,
                      NEW.id
                  ;
                  RETURN NEW;
              END;
          $$;


--
-- Name: log_test_ext2_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_ext2_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                INSERT INTO test_ext2_history
                (
                    master_id,
                    test_e2_id,
                    user_id,
                    created_at,
                    updated_at,
                    test_ext2_table_id
                    )
                SELECT
                    NEW.master_id,
                    NEW.test_e2_id,
                    NEW.user_id,
                    NEW.created_at,
                    NEW.updated_at,
                    NEW.id
                ;
                RETURN NEW;
            END;
        $$;


--
-- Name: log_test_ext_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_ext_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                INSERT INTO test_ext_history
                (
                    master_id,
                    test_e_id,
                    user_id,
                    created_at,
                    updated_at,
                    test_ext_table_id
                    )
                SELECT
                    NEW.master_id,
                    NEW.test_e_id,
                    NEW.user_id,
                    NEW.created_at,
                    NEW.updated_at,
                    NEW.id
                ;
                RETURN NEW;
            END;
        $$;


--
-- Name: log_test_item_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_test_item_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO test_item_history
            (
                    test_item_id,                    
                    external_id,
                    user_id,
                    created_at,
                    updated_at
                )                 
            SELECT                 
                NEW.id,
                NEW.external_id,
                NEW.user_id,
                NEW.created_at,
                NEW.updated_at 
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_tracker_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_tracker_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN

          -- Check to see if there is an existing record in tracker_history that matches the 
          -- that inserted or updated in trackers.
          -- If there is, just skip the insert into tracker_history, otherwise make the insert happen.

          PERFORM * from tracker_history 
            WHERE
              master_id = NEW.master_id 
              AND protocol_id = NEW.protocol_id
              AND coalesce(protocol_event_id,-1) = coalesce(NEW.protocol_event_id,-1)
              AND coalesce(event_date, '1900-01-01'::date)::date = coalesce(NEW.event_date, '1900-01-01')::date
              AND sub_process_id = NEW.sub_process_id
              AND coalesce(notes,'') = coalesce(NEW.notes,'')
              AND coalesce(item_id,-1) = coalesce(NEW.item_id,-1)
              AND coalesce(item_type,'') = coalesce(NEW.item_type,'')
              -- do not check created_at --
              AND updated_at::timestamp = NEW.updated_at::timestamp
              AND coalesce(user_id,-1) = coalesce(NEW.user_id,-1);
              
            IF NOT FOUND THEN
              INSERT INTO tracker_history 
                  (tracker_id, master_id, protocol_id, 
                   protocol_event_id, event_date, sub_process_id, notes,
                   item_id, item_type,
                   created_at, updated_at, user_id)

                  SELECT NEW.id, NEW.master_id, NEW.protocol_id, 
                     NEW.protocol_event_id, NEW.event_date, 
                     NEW.sub_process_id, NEW.notes, 
                     NEW.item_id, NEW.item_type,
                     NEW.created_at, NEW.updated_at, NEW.user_id  ;
            END IF;

            RETURN NEW;
            
        END;   
    $$;


--
-- Name: log_user_access_control_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_user_access_control_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO user_access_control_history
            (
                user_id,
                resource_type,
                resource_name,
                options,
                access,
                app_type_id,
                role_name,
                admin_id,
                disabled,
                created_at,
                updated_at,
                user_access_control_id
                )
            SELECT
                NEW.user_id,
                NEW.resource_type,
                NEW.resource_name,
                NEW.options,
                NEW.access,
                NEW.app_type_id,
                NEW.role_name,
                NEW.admin_id,
                NEW.disabled,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_user_authorization_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_user_authorization_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO user_authorization_history
            (
                    user_authorization_id,
                    user_id,                    
                    has_authorization,                    
                    admin_id,
                    disabled,                    
                    created_at,
                    updated_at
                )                 
            SELECT                 
                NEW.id,
                NEW.user_id,                
                NEW.has_authorization,               
                NEW.admin_id,                
                NEW.disabled,
                NEW.created_at,
                NEW.updated_at
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_user_role_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_user_role_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            INSERT INTO user_role_history
            (
                app_type_id,
                role_name,
                user_id,
                admin_id,
                disabled,
                created_at,
                updated_at,
                user_role_id
                )
            SELECT
                NEW.app_type_id,
                NEW.role_name,
                NEW.user_id,
                NEW.admin_id,
                NEW.disabled,
                NEW.created_at,
                NEW.updated_at,
                NEW.id
            ;
            RETURN NEW;
        END;
    $$;


--
-- Name: log_user_update(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.log_user_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
      created_at ,
      updated_at,
      failed_attempts,
      unlock_token,
      locked_at,
      disabled ,
      admin_id,
      app_type_id,
      authentication_token,
      encrypted_otp_secret,
      encrypted_otp_secret_iv,
      encrypted_otp_secret_salt,
      consumed_timestep,
      otp_required_for_login,
      password_updated_at,
      first_name,
      last_name,
      confirmation_token,
      confirmed_at,
      confirmation_sent_at
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
    NEW.encrypted_otp_secret,
    NEW.encrypted_otp_secret_iv,
    NEW.encrypted_otp_secret_salt,
    NEW.consumed_timestep,
    NEW.otp_required_for_login,
    NEW.password_updated_at,
    NEW.first_name,
    NEW.last_name,
    NEW.confirmation_token,
    NEW.confirmed_at,
    NEW.confirmation_sent_at
  ;
  RETURN NEW;
  END;
  $$;


--
-- Name: redcap_data_dictionary_history_upd(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.redcap_data_dictionary_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO redcap_data_dictionary_history (
    redcap_project_admin_id, field_count, captured_metadata,
    disabled,
    admin_id,
    created_at,
    updated_at,
    redcap_data_dictionary_id)
  SELECT
    NEW.redcap_project_admin_id, NEW.field_count, NEW.captured_metadata,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: redcap_project_admin_history_upd(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.redcap_project_admin_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO redcap_project_admin_history (
    name, api_key, server_url, captured_project_info, study, transfer_mode, frequency, status, post_transfer_pipeline, notes, dynamic_model_table,
    disabled,
    admin_id,
    created_at,
    updated_at,
    redcap_project_admin_id)
  SELECT
    NEW.name, NEW.api_key, NEW.server_url, NEW.captured_project_info, NEW.study, NEW.transfer_mode, NEW.frequency, NEW.status, NEW.post_transfer_pipeline, NEW.notes, NEW.dynamic_model_table,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: role_description_history_upd(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.role_description_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO role_description_history (
    app_type_id, role_name, role_template, name, description,
    disabled,
    admin_id,
    created_at,
    updated_at,
    role_description_id)
  SELECT
    NEW.app_type_id, NEW.role_name, NEW.role_template, NEW.name, NEW.description,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: tracker_upsert(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.tracker_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      DECLARE
        latest_tracker trackers%ROWTYPE;
      BEGIN

        

        -- Look for a row in trackers for the inserted master / protocol pair
        SELECT * into latest_tracker 
          FROM trackers 
          WHERE
            master_id = NEW.master_id 
            AND protocol_id = NEW.protocol_id              
          ORDER BY
            event_date DESC NULLS LAST, updated_at DESC NULLS LAST
          LIMIT 1
        ;

        IF NOT FOUND THEN
          -- Nothing was found, so just allow the insert to continue
          
          RETURN NEW;

        ELSE   
          -- A trackers row for the master / protocol pair was found.
          -- Check if it is more recent, by having an event date either later than the insert, or 
          -- has an event_date the same as the insert but with later updated_at time (unlikely)

          IF latest_tracker.event_date > NEW.event_date OR 
              latest_tracker.event_date = NEW.event_date AND latest_tracker.updated_at > NEW.updated_at
              THEN

            -- The retrieved record was more recent, we should not make a change to the trackers table,
            -- but instead we need to ensure an insert into the tracker_history table does happen even though there
            -- is no actual insert or update trigger to fire.
            -- We use the trackers record ID that was retrieved as the tracker_id in tracker_history

            INSERT INTO tracker_history (
                tracker_id, master_id, protocol_id, 
                protocol_event_id, event_date, sub_process_id, notes,
                item_id, item_type,
                created_at, updated_at, user_id
              )                 
              SELECT 
                latest_tracker.id, NEW.master_id, NEW.protocol_id, 
                NEW.protocol_event_id, NEW.event_date, 
                NEW.sub_process_id, NEW.notes, 
                NEW.item_id, NEW.item_type,
                NEW.created_at, NEW.updated_at, NEW.user_id  ;
            
            RETURN NULL;

          ELSE
            -- The tracker record for the master / protocol pair exists and was not more recent, therefore it
            -- needs to be replaced by the intended NEW record. Complete with an update and allow the cascading 
            -- trackers update trigger to handle the insert into tracker_history.

            UPDATE trackers SET
              master_id = NEW.master_id, 
              protocol_id = NEW.protocol_id, 
              protocol_event_id = NEW.protocol_event_id, 
              event_date = NEW.event_date, 
              sub_process_id = NEW.sub_process_id, 
              notes = NEW.notes, 
              item_id = NEW.item_id, 
              item_type = NEW.item_type,
              -- do not update created_at --
              updated_at = NEW.updated_at, 
              user_id = NEW.user_id
            WHERE master_id = NEW.master_id AND 
              protocol_id = NEW.protocol_id
            ;

            -- Prevent the original insert from actually completing.
            RETURN NULL;
          END IF;
        END IF;      
      END;
    $$;


--
-- Name: update_address_ranks(integer); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_address_ranks(set_master_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
        DECLARE
          latest_primary RECORD;
        BEGIN
  
          SELECT * into latest_primary 
          FROM addresses
          WHERE master_id = set_master_id
          AND rank = 10
          ORDER BY updated_at DESC
          LIMIT 1;
        
          IF NOT FOUND THEN
            RETURN NULL;
          END IF;

          
          UPDATE addresses SET rank = 5 
          WHERE 
            master_id = set_master_id 
            AND rank = 10
            AND id <> latest_primary.id;
          

          RETURN 1;
        END;
    $$;


--
-- Name: update_all_primary_sleep_records(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_all_primary_sleep_records() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	sleep_record RECORD;
	primary_count integer;
	event_count integer;
BEGIN

	primary_count := 0;
	event_count := 0;

	FOR sleep_record IN
	  SELECT * from temp_sleep_assignments ORDER BY record_updated_at
	LOOP


		IF sleep_record.event IS NULL THEN

			PERFORM update_primary_sleep_record(
				sleep_record.record_updated_at,
				sleep_record.sleep_id::BIGINT,
				(SELECT (pi::varchar)::player_infos FROM temp_player_infos pi WHERE master_id = sleep_record.master_id LIMIT 1),
				ARRAY(SELECT distinct (pc::varchar)::player_contacts FROM temp_player_contacts pc WHERE master_id = sleep_record.master_id),
				ARRAY(SELECT distinct (a::varchar)::addresses FROM temp_addresses a WHERE master_id = sleep_record.master_id)
			);

			primary_count := primary_count + 1;

		ELSE

			PERFORM updated_sleep_tracker(
				sleep_record.record_updated_at,
				sleep_record.sleep_id::BIGINT,
				sleep_record.event,
				sleep_record.record_updated_at,
				'Activity recorded in Athena: ' || sleep_record.event
			);

			event_count := event_count + 1;

		END IF;

	END LOOP;

	RAISE NOTICE 'Performed updates on primary records (%) and events (%)', primary_count, event_count;

	return 1;

END;
$$;


--
-- Name: update_ipa_transfer_record_results(character varying, character varying, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_ipa_transfer_record_results(new_from_db character varying, new_to_db character varying, for_external_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN

  UPDATE ml_app.sync_statuses sync
  SET
    select_status = t.status,
    to_master_id = t.to_master_id,
    updated_at = now()
  FROM (
    SELECT * FROM temp_ipa_assignments_results
  ) AS t
  WHERE
    from_master_id = t.master_id
    AND from_db = new_from_db
    AND to_db = new_to_db
    AND external_id = t.ipa_id::varchar
    AND external_type = for_external_type
    AND (t.event IS NULL and sync.event IS NULL OR sync.event = t.event)
    AND sync.record_updated_at = t.record_updated_at
    AND coalesce(select_status, '') NOT IN ('completed', 'already transferred');

  RETURN 1;

END;
$$;


--
-- Name: update_master_msid(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_master_msid() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
          UPDATE ml_app.masters
              set msid = (
              case when NEW.msid is null and rank in (11,12)
				  then (select max(msid) from ml_app.masters)+1
                   else new.msid
              end
              )

          WHERE masters.id = NEW.id;

          RETURN NEW;
      END;
      $$;


--
-- Name: update_master_with_player_info(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_master_with_player_info() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
          UPDATE masters 
              set rank = (
              case when NEW.rank is null then null 
                   when (NEW.rank > 12) then NEW.rank * -1 
                   else new.rank
              end
              )

          WHERE masters.id = NEW.master_id;

          RETURN NEW;
      END;
      $$;


--
-- Name: update_master_with_pro_info(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_master_with_pro_info() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        UPDATE masters 
            set pro_info_id = NEW.id, pro_id = NEW.pro_id             
        WHERE masters.id = NEW.master_id;

        RETURN NEW;
    END;
    $$;


--
-- Name: update_player_contact_ranks(integer, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_player_contact_ranks(set_master_id integer, set_rec_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
        DECLARE
          latest_primary RECORD;
        BEGIN
  
          SELECT * into latest_primary 
          FROM player_contacts
          WHERE master_id = set_master_id
          AND rank = 10
          AND rec_type = set_rec_type
          ORDER BY updated_at DESC
          LIMIT 1;
        
          IF NOT FOUND THEN
            RETURN NULL;
          END IF;

          
          UPDATE player_contacts SET rank = 5 
          WHERE 
            master_id = set_master_id 
            AND rank = 10
            AND rec_type = set_rec_type
            AND id <> latest_primary.id;
          

          RETURN 1;
        END;
    $$;


--
-- Name: update_sleep_transfer_record_results(character varying, character varying, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.update_sleep_transfer_record_results(new_from_db character varying, new_to_db character varying, for_external_type character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
BEGIN

  UPDATE ml_app.sync_statuses sync
  SET
    select_status = t.status,
    to_master_id = t.to_master_id,
    updated_at = now()
  FROM (
    SELECT * FROM temp_sleep_assignments_results
  ) AS t
  WHERE
    from_master_id = t.master_id
    AND from_db = new_from_db
    AND to_db = new_to_db
    AND external_id = t.sleep_id::varchar
    AND external_type = for_external_type
    AND (t.event IS NULL and sync.event IS NULL OR sync.event = t.event)
    AND sync.record_updated_at = t.record_updated_at
    AND coalesce(select_status, '') NOT IN ('completed', 'already transferred');

  RETURN 1;

END;
$$;


--
-- Name: updated_sleep_tracker(timestamp without time zone, bigint, character varying, timestamp without time zone, character varying); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.updated_sleep_tracker(rec_updated_at timestamp without time zone, match_sleep_id bigint, for_event character varying, event_date timestamp without time zone, add_notes character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
	rec_id integer;
  etl_user_id integer;
	found_sleep record;
	new_master_id integer;
	this_protocol_id integer;
	opt_out_id integer;
	complete_id integer;
	withdrew_id integer;
	screened_id integer;
	eligible_id integer;
	ineligible_id integer;
	enrolled_id integer;
	contacted_id integer;
	l2fu_id integer;

BEGIN

	-- We create new records setting user_id for the user with email fphsetl@hms.harvard.edu, rather than the original
	-- value from the source database, which probably would not match the user IDs in the remote database.
	SELECT id FROM get_etl_user()
	INTO etl_user_id
	LIMIT 1;


	-- Find the sleep_assignments external identifier record for this master record and
	-- validate that it exists
	SELECT *
	INTO found_sleep
	FROM sleep_assignments sleep
	WHERE sleep.sleep_id = match_sleep_id
	LIMIT 1;

	new_master_id := found_sleep.master_id;

	-- If the Sleep external identifier does not exist then the sync should fail.

	IF NOT FOUND THEN
		RAISE NOTICE 'Attempting to transfer trackers back for an external ID that does not exist: sleep_assigments record found for Sleep_ID %', (match_sleep_id);
		UPDATE temp_sleep_assignments SET status='invalid tracker sync-back', to_master_id=new_master_id WHERE sleep_id = match_sleep_id AND event = for_event and record_updated_at = rec_updated_at;
	  RETURN NULL;
	END IF;

	SELECT id
	FROM protocols
	WHERE
		name = 'Sleep Study Phase 2'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO this_protocol_id;


	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Opt Out'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO opt_out_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Complete'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO complete_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Withdrew'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO withdrew_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Screened'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO screened_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Eligible'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO eligible_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Ineligible'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO ineligible_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Enrolled'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO enrolled_id;

	SELECT id
	FROM sub_processes
	WHERE
		protocol_id = this_protocol_id
		AND name = 'Lost to Follow Up, Not Enrolled'
		AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO l2fu_id;

	SELECT id
	FROM sub_processes
	WHERE
	protocol_id = this_protocol_id
	AND name = 'Contacted'
	AND coalesce(disabled, FALSE) = FALSE
	LIMIT 1
	INTO contacted_id;


	INSERT INTO trackers
	(
		master_id,
		protocol_id,
		sub_process_id,
		protocol_event_id,
		event_date,
		notes,
		created_at,
		updated_at,
		user_id
	)
	VALUES
	(
		found_sleep.master_id,
		this_protocol_id,
		CASE for_event
			WHEN 'exit (opt out)' THEN opt_out_id
			WHEN 'exit during hms phone screen' THEN opt_out_id
			WHEN 'exit during bwh phone screen' THEN opt_out_id
			WHEN 'exit during informed consent review' THEN opt_out_id
			WHEN 'lost to follow up' THEN l2fu_id
			WHEN 'hms screened' THEN screened_id
			WHEN 'bwh eligible' THEN eligible_id
			WHEN 'hms or bwh ineligible' THEN ineligible_id
			WHEN 'enrolled' THEN enrolled_id
			WHEN 'completed' THEN complete_id
			WHEN 'withdrawn' THEN withdrew_id
			WHEN 'pi follow up before enrollment' THEN contacted_id
			WHEN 'general communication' THEN contacted_id
		END,
		NULL,
		event_date,
		add_notes,
		now(),
		now(),
		etl_user_id

	)
	RETURNING id
	INTO rec_id
	;

	UPDATE temp_sleep_assignments SET status='completed', to_master_id=new_master_id WHERE sleep_id = match_sleep_id AND event = for_event and record_updated_at = rec_updated_at;

	RAISE NOTICE 'Inserted Event "%" for Sleep_ID %', for_event, match_sleep_id;

	return new_master_id;

END;
$$;


--
-- Name: user_description_history_upd(); Type: FUNCTION; Schema: ml_app; Owner: -
--

CREATE FUNCTION ml_app.user_description_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO user_description_history (
    app_type_id, role_name, role_template, name, description,
    disabled,
    admin_id,
    created_at,
    updated_at,
    user_description_id)
  SELECT
    NEW.app_type_id, NEW.role_name, NEW.role_template, NEW.name, NEW.description,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: calc_var_stats_for_boolean(bigint); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.calc_var_stats_for_boolean(var_id bigint) RETURNS TABLE(variable_id bigint, variable text, results bigint[], labels character varying[], cat_counts jsonb, distincts bigint, completed bigint, total_recs bigint, "chart:" text)
    LANGUAGE plpgsql
    AS $_$
declare
sql text;
varrec record;
varname varchar;
BEGIN 
	
select * from ref_data.datadic_variables dv where id = var_id
into varrec;

varname := varrec.storage_varname;

raise notice '%1', varrec;
if varname is null then
  raise notice 'No matching storage variable name for variable %', (var_id);
  
  return;
end if;

sql := format($$
with n as (
    select %1$s
    from %3$s.%4$s
), 
c as (
	select %1$s::varchar cat, count(*) num
	from n
	group by %1$s
),
m as (
    select 
      (
        select array_to_json(array_agg(json_build_object(c.cat, c.num))) from c
        where c.cat is not null
      ) cat_counts_m,
      count(distinct %1$s)  distincts_m,
      count(%1$s) count_m,
      count(coalesce(%1$s, false)) recs_m
    from n
)
select
%5$s::bigint variable_id,
'%1$s' "variable",
array_agg(num) "results", 
array_agg(cat) "labels", 
cat_counts_m::jsonb "cat_counts",
distincts_m "distincts", -- distinct values
count_m  "completed",
recs_m "total_recs",
null "chart"
from 
c, m
where c.cat is not null
group by "variable",
 "cat_counts",
 "distincts",
 "completed",
 "total_recs"
 ;
$$
,
varname, varrec.variable_type, varrec.schema_or_path, varrec.table_or_file, var_id
);

return query execute sql;

return query execute sql;
exception when others then
raise notice '%', varrec;
raise notice '%', sqlerrm;
null;


end
$_$;


--
-- Name: calc_var_stats_for_categorical(bigint); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.calc_var_stats_for_categorical(var_id bigint) RETURNS TABLE(variable_id bigint, variable text, results bigint[], labels character varying[], cat_counts jsonb, distincts bigint, completed bigint, total_recs bigint, "chart:" text)
    LANGUAGE plpgsql
    AS $_$
declare
sql text;
varrec record;
varname varchar;
BEGIN 
	
select * from ref_data.datadic_variables dv where id = var_id
into varrec;

varname := varrec.storage_varname;

raise notice '%1', varrec;
if varname is null then
  raise notice 'No matching storage variable name for variable %', (var_id);
  
  return;
end if;

sql := format($$
with n as (
    select nullif(%1$s, '')::numeric  %1$s
    from %3$s.%4$s
), 
c as (
	select %1$s::varchar cat, count(*) num
	from n
	group by %1$s
	order by "cat"
),
m as (
    select 
      (
        select array_to_json(array_agg(json_build_object(c.cat, c.num))) from c
        where c.cat is not null
      ) cat_counts_m,
      count(distinct %1$s)  distincts_m,
      count(%1$s) count_m,
      count(coalesce(%1$s, 0)) recs_m
    from n
)
select
%5$s::bigint variable_id,
'%1$s' "variable",
array_agg(num) "results", 
array_agg(cat) "labels", 
cat_counts_m::jsonb "cat_counts",
distincts_m "distincts", -- distinct values
count_m  "completed",
recs_m "total_recs",
null "chart"
from 
c, m
where c.cat is not null
group by "variable",
 "cat_counts",
 "distincts",
 "completed",
 "total_recs"
 ;
$$
,
varname, varrec.variable_type, varrec.schema_or_path, varrec.table_or_file, var_id
);

return query execute sql;

return query execute sql;
exception when others then
raise notice '%', varrec;
raise notice '%', sqlerrm;
null;


end
$_$;


--
-- Name: calc_var_stats_for_numeric(bigint); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.calc_var_stats_for_numeric(var_id bigint) RETURNS TABLE(variable_id bigint, variable text, results bigint[], labels character varying[], min numeric, med numeric, max numeric, mean numeric, stddev numeric, distincts bigint, completed bigint, total_recs bigint, "chart:" text)
    LANGUAGE plpgsql
    AS $_$
declare
sql text;
varrec record;
varname varchar;
vardt varchar;
BEGIN 
	
select * 
from ref_data.datadic_variables dv 
inner join
information_schema."columns"
on dv.table_or_file = table_name and dv.schema_or_path = table_schema
and dv.storage_varname = column_name
where id = var_id
into varrec;

varname := varrec.storage_varname;
vardt := varrec.data_type;

if varname is null then
  raise notice 'No matching storage variable name for variable %', (var_id);
  
  return;
end if;

--raise notice 'ID: %', varrec.id;

sql := format($$
with n as (
    select 
$$ ||    
  case when vardt in ('varchar','character varying', 'text')
  then 
  $$ nullif(%1$s, '')::numeric $$
  else $$ %1$s::numeric $$
  end
|| $$ 
%1$s
    from %3$s.%4$s
), 
m as (
    select 
      min(%1$s) min_m, 
      max(%1$s) max_m,
      round((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY %1$s))::numeric, 1) med_m,
      round(avg(%1$s)::numeric, 1) mean_m, 
      round(stddev_pop(%1$s)::numeric, 1) stddev_m,
      count(distinct %1$s)  distincts_m,
      count(%1$s) count_m,
      count(coalesce(%1$s, 0)) recs_m,
      12 buckets_m,
      (max(%1$s)-min(%1$s))/12 bin_width_m
    from n
)
select
%5$s::bigint variable_id,
'%1$s' "variable",
array_agg(num) "results", 
array_agg(bucket)::varchar[] "labels", 
min_m "min", 
med_m "med",
max_m "max", 
mean_m "mean", 
stddev_m "stddev",
distincts_m "distincts", -- distinct values
count_m  "completed",
recs_m "total_recs",
null "chart"
from 
(

  select 
  count(val) num, 
  --t.val val, 
  (round(min_m + ((bin-1) * bin_width_m),2))::varchar || ' - ' || (round(min_m + ((bin) * bin_width_m),2))::varchar "bucket"
  from
  (
    select generate_series(1,buckets_m+1) bin from m
  ) bins
  left join (
    select 
      width_bucket(%1$s, min_m, max_m+0.0000001, buckets_m) bucket, 
      %1$s val
    from n, m
    where %1$s is not null
  ) t on bins.bin = t.bucket
  cross join  m
  group by bin, min_m, bin_width_m
  order by bin
  
) vals, m
group by "variable",
 "min", 
 "med",
 "max", 
 "mean", 
 "stddev",
 "distincts",
 "completed",
 "total_recs"
 ;
$$
,
varname, varrec.variable_type, varrec.schema_or_path, varrec.table_or_file, var_id, vardt
);
--raise notice '%', sql;

return query execute sql;
exception when others then
raise notice '%', varrec;
raise notice '%', sqlerrm;
null;

end
$_$;


--
-- Name: log_datadic_variables_update(); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.log_datadic_variables_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO datadic_variable_history (
    
    study, source_name, source_type, domain, form_name, variable_name, variable_type, presentation_type, label, label_note, annotation, is_required, valid_type, valid_min, valid_max, multi_valid_choices, is_identifier, is_derived_var, multi_derived_from_id, doc_url, target_type, owner_email, classification, other_classification, multi_timepoints, equivalent_to_id, storage_type, db_or_fs, schema_or_path, table_or_file, disabled, admin_id, redcap_data_dictionary_id, position, section_id, sub_section_id, title, storage_varname, contributor_type, n_for_timepoints, notes,
    user_id,
    created_at,
    updated_at,
    datadic_variable_id)
  SELECT
    
    NEW.study, NEW.source_name, NEW.source_type, NEW.domain, NEW.form_name, NEW.variable_name, NEW.variable_type, NEW.presentation_type, NEW.label, NEW.label_note, NEW.annotation, NEW.is_required, NEW.valid_type, NEW.valid_min, NEW.valid_max, NEW.multi_valid_choices, NEW.is_identifier, NEW.is_derived_var, NEW.multi_derived_from_id, NEW.doc_url, NEW.target_type, NEW.owner_email, NEW.classification, NEW.other_classification, NEW.multi_timepoints, NEW.equivalent_to_id, NEW.storage_type, NEW.db_or_fs, NEW.schema_or_path, NEW.table_or_file, NEW.disabled, NEW.admin_id, NEW.redcap_data_dictionary_id, NEW.position, NEW.section_id, NEW.sub_section_id, NEW.title, NEW.storage_varname, NEW.contributor_type, NEW.n_for_timepoints, NEW.notes,
    NEW.user_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: log_domain_mappings_update(); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.log_domain_mappings_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO domain_mapping_history (
    
    domain, domain_title, tag_select_health_categories, notes, hide_from_datadic, disabled,
    user_id,
    created_at,
    updated_at,
    domain_mapping_id)
  SELECT
    
    NEW.domain, NEW.domain_title, NEW.tag_select_health_categories, NEW.notes, NEW.hide_from_datadic, NEW.disabled,
    NEW.user_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: log_redcap_user_status_recs_update(); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.log_redcap_user_status_recs_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO redcap_user_status_rec_history (
    
    username, first_name, last_name, email_address, administrator, users_sponsor, institution_id, comments, first_activity, last_activity, last_login, time_of_suspension, expiration_date,
    user_id,
    created_at,
    updated_at,
    redcap_user_status_rec_id)
  SELECT
    
    NEW.username, NEW.first_name, NEW.last_name, NEW.email_address, NEW.administrator, NEW.users_sponsor, NEW.institution_id, NEW.comments, NEW.first_activity, NEW.last_activity, NEW.last_login, NEW.time_of_suspension, NEW.expiration_date,
    NEW.user_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: redcap_data_collection_instrument_history_upd(); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.redcap_data_collection_instrument_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO redcap_data_collection_instrument_history (
    redcap_project_admin_id, name, label,
    disabled,
    admin_id,
    created_at,
    updated_at,
    redcap_data_collection_instrument_id)
  SELECT
    NEW.redcap_project_admin_id, NEW.name, NEW.label,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: redcap_project_user_history_upd(); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.redcap_project_user_history_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO redcap_project_user_history (
    redcap_project_admin_id, username, email, expiration,
    disabled,
    admin_id,
    created_at,
    updated_at,
    redcap_project_user_id)
  SELECT
    NEW.redcap_project_admin_id, NEW.username, NEW.email, NEW.expiration,
    NEW.disabled,
    NEW.admin_id,
    NEW.created_at,
    NEW.updated_at,
    NEW.id;
  RETURN NEW;
END;
$$;


--
-- Name: statsummary_completers(character varying); Type: FUNCTION; Schema: ref_data; Owner: -
--

CREATE FUNCTION ref_data.statsummary_completers(id_field character varying) RETURNS TABLE(participant_id integer, colname character varying, tablename character varying, colval integer)
    LANGUAGE plpgsql
    AS $_$
declare sql varchar;
BEGIN 
	with table_with_participant_id as (
	select table_schema, table_name
	from information_schema."columns" tabcol
	where tabcol.column_name = id_field
	)
	select
	  string_agg(
	    'select ' || id_field || '::int, ''' || col.column_name || '''::varchar colname, ''' || col.table_name || '''::varchar tablename, ' || col.column_name || ' colval  from ' || col.table_schema || '.' || col.table_name,
	    ' union '
	  )
	from information_schema."columns" col
	inner join ref_data.view_redcap_project_details rpd
	on col.table_name = rpd.tablename and col.table_schema = rpd.schemaname
	inner join table_with_participant_id tp
	on col.table_name = tp.table_name and col.table_schema = tp.table_schema 
	where
	col.column_name ~ '_complete$'
	and col.data_type='integer'
  into sql
  ;
  RETURN QUERY execute sql;  
END
$_$;


--
-- Name: accuracy_score_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.accuracy_score_history (
    id integer NOT NULL,
    name character varying,
    value integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    accuracy_score_id integer
);


--
-- Name: accuracy_score_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.accuracy_score_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accuracy_score_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.accuracy_score_history_id_seq OWNED BY ml_app.accuracy_score_history.id;


--
-- Name: accuracy_scores; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.accuracy_scores (
    id integer NOT NULL,
    name character varying,
    value integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean
);


--
-- Name: accuracy_scores_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.accuracy_scores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accuracy_scores_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.accuracy_scores_id_seq OWNED BY ml_app.accuracy_scores.id;


--
-- Name: activity_log_bhs_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_bhs_assignment_history (
    id integer NOT NULL,
    master_id integer,
    bhs_assignment_id integer,
    select_record_from_player_contact_phones character varying,
    return_call_availability_notes character varying,
    questions_from_call_notes character varying,
    results_link character varying,
    select_result character varying,
    completed_q1_no_yes character varying,
    completed_teamstudy_no_yes character varying,
    previous_contact_with_team_no_yes character varying,
    previous_contact_with_team_notes character varying,
    extra_log_type character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    activity_log_bhs_assignment_id integer,
    notes character varying,
    pi_return_call_notes character varying
);


--
-- Name: activity_log_bhs_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_bhs_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_bhs_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_bhs_assignment_history_id_seq OWNED BY ml_app.activity_log_bhs_assignment_history.id;


--
-- Name: activity_log_bhs_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_bhs_assignments (
    id integer NOT NULL,
    master_id integer,
    select_record_from_player_contact_phones character varying,
    return_call_availability_notes character varying,
    questions_from_call_notes character varying,
    results_link character varying,
    select_result character varying,
    extra_log_type character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    pi_notes_from_return_call character varying,
    bhs_assignment_id bigint,
    pi_return_call_notes character varying
);


--
-- Name: activity_log_bhs_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_bhs_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_bhs_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_bhs_assignments_id_seq OWNED BY ml_app.activity_log_bhs_assignments.id;


--
-- Name: activity_log_ext_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_ext_assignment_history (
    id integer NOT NULL,
    master_id integer,
    ext_assignment_id integer,
    do_when date,
    notes character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    activity_log_ext_assignment_id integer
);


--
-- Name: activity_log_ext_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_ext_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_ext_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_ext_assignment_history_id_seq OWNED BY ml_app.activity_log_ext_assignment_history.id;


--
-- Name: activity_log_ext_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_ext_assignments (
    id integer NOT NULL,
    master_id integer,
    ext_assignment_id integer,
    do_when date,
    notes character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    select_call_direction character varying,
    select_who character varying,
    extra_text character varying,
    extra_log_type character varying
);


--
-- Name: activity_log_ext_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_ext_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_ext_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_ext_assignments_id_seq OWNED BY ml_app.activity_log_ext_assignments.id;


--
-- Name: activity_log_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_history (
    id integer NOT NULL,
    activity_log_id integer,
    name character varying,
    item_type character varying,
    rec_type character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    action_when_attribute character varying,
    field_list character varying,
    blank_log_field_list character varying,
    blank_log_name character varying,
    extra_log_types character varying,
    hide_item_list_panel boolean,
    main_log_name character varying,
    process_name character varying,
    table_name character varying,
    category character varying,
    schema_name character varying
);


--
-- Name: activity_log_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_history_id_seq OWNED BY ml_app.activity_log_history.id;


--
-- Name: activity_log_new_test_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_new_test_history (
    id integer NOT NULL,
    master_id integer,
    new_test_id integer,
    done_when date,
    select_result character varying,
    notes character varying,
    protocol_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    activity_log_new_test_id integer
);


--
-- Name: activity_log_new_test_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_new_test_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_new_test_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_new_test_history_id_seq OWNED BY ml_app.activity_log_new_test_history.id;


--
-- Name: activity_log_new_tests; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_new_tests (
    id integer NOT NULL,
    master_id integer,
    new_test_id integer,
    done_when date,
    select_result character varying,
    notes character varying,
    protocol_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    new_test_ext_id bigint
);


--
-- Name: activity_log_new_tests_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_new_tests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_new_tests_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_new_tests_id_seq OWNED BY ml_app.activity_log_new_tests.id;


--
-- Name: activity_log_player_contact_phone_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_player_contact_phone_history (
    id integer NOT NULL,
    master_id integer,
    player_contact_id integer,
    data character varying,
    select_call_direction character varying,
    select_who character varying,
    called_when date,
    select_result character varying,
    select_next_step character varying,
    follow_up_when date,
    notes character varying,
    protocol_id integer,
    set_related_player_contact_rank character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    activity_log_player_contact_phone_id integer,
    extra_log_type character varying,
    disabled boolean
);


--
-- Name: activity_log_player_contact_phone_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_player_contact_phone_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_player_contact_phone_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_player_contact_phone_history_id_seq OWNED BY ml_app.activity_log_player_contact_phone_history.id;


--
-- Name: activity_log_player_contact_phones; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_player_contact_phones (
    id integer NOT NULL,
    data character varying,
    select_call_direction character varying,
    select_who character varying,
    called_when date,
    select_result character varying,
    select_next_step character varying,
    follow_up_when date,
    protocol_id integer,
    notes character varying,
    user_id integer,
    master_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    set_related_player_contact_rank character varying,
    extra_log_type character varying,
    player_contact_id integer,
    disabled boolean
);


--
-- Name: TABLE activity_log_player_contact_phones; Type: COMMENT; Schema: ml_app; Owner: -
--

COMMENT ON TABLE ml_app.activity_log_player_contact_phones IS 'Phone Log process for Zeus';


--
-- Name: COLUMN activity_log_player_contact_phones.data; Type: COMMENT; Schema: ml_app; Owner: -
--

COMMENT ON COLUMN ml_app.activity_log_player_contact_phones.data IS 'Phone number related to this activity';


--
-- Name: COLUMN activity_log_player_contact_phones.select_call_direction; Type: COMMENT; Schema: ml_app; Owner: -
--

COMMENT ON COLUMN ml_app.activity_log_player_contact_phones.select_call_direction IS 'Was this call received by staff or to subject';


--
-- Name: activity_log_player_contact_phones_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_player_contact_phones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_player_contact_phones_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_player_contact_phones_id_seq OWNED BY ml_app.activity_log_player_contact_phones.id;


--
-- Name: activity_log_player_info_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_player_info_history (
    id integer NOT NULL,
    master_id integer,
    player_info_id integer,
    done_when date,
    notes character varying,
    protocol_id integer,
    select_who character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    activity_log_player_info_id integer
);


--
-- Name: activity_log_player_info_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_player_info_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_player_info_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_player_info_history_id_seq OWNED BY ml_app.activity_log_player_info_history.id;


--
-- Name: activity_log_player_infos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_log_player_infos (
    id integer NOT NULL,
    master_id integer,
    player_info_id integer,
    done_when date,
    notes character varying,
    protocol_id integer,
    select_who character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: activity_log_player_infos_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_log_player_infos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_player_infos_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_log_player_infos_id_seq OWNED BY ml_app.activity_log_player_infos.id;


--
-- Name: activity_logs; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.activity_logs (
    id integer NOT NULL,
    name character varying,
    item_type character varying,
    rec_type character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    action_when_attribute character varying,
    field_list character varying,
    blank_log_field_list character varying,
    blank_log_name character varying,
    extra_log_types character varying,
    hide_item_list_panel boolean,
    main_log_name character varying,
    process_name character varying,
    table_name character varying,
    category character varying,
    schema_name character varying
);


--
-- Name: activity_logs_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.activity_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.activity_logs_id_seq OWNED BY ml_app.activity_logs.id;


--
-- Name: address_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.address_history (
    id integer NOT NULL,
    master_id integer,
    street character varying,
    street2 character varying,
    street3 character varying,
    city character varying,
    state character varying,
    zip character varying,
    source character varying,
    rank integer,
    rec_type character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:35.841791'::timestamp without time zone,
    country character varying(3),
    postal_code character varying,
    region character varying,
    address_id integer
);


--
-- Name: address_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.address_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: address_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.address_history_id_seq OWNED BY ml_app.address_history.id;


--
-- Name: addresses_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.addresses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: addresses_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.addresses_id_seq OWNED BY ml_app.addresses.id;


--
-- Name: admin_action_logs; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.admin_action_logs (
    id integer NOT NULL,
    admin_id integer,
    item_type character varying,
    item_id integer,
    action character varying,
    url character varying,
    prev_value json,
    new_value json,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: admin_action_logs_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.admin_action_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admin_action_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.admin_action_logs_id_seq OWNED BY ml_app.admin_action_logs.id;


--
-- Name: admin_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.admin_history (
    id integer NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    sign_in_count integer DEFAULT 0,
    current_sign_in_at timestamp without time zone,
    last_sign_in_at timestamp without time zone,
    current_sign_in_ip character varying,
    last_sign_in_ip character varying,
    failed_attempts integer DEFAULT 0,
    unlock_token character varying,
    locked_at timestamp without time zone,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    disabled boolean,
    admin_id integer,
    encrypted_otp_secret character varying,
    encrypted_otp_secret_iv character varying,
    encrypted_otp_secret_salt character varying,
    consumed_timestep integer,
    otp_required_for_login boolean,
    reset_password_sent_at timestamp without time zone,
    password_updated_at timestamp without time zone,
    updated_by_admin_id integer
);


--
-- Name: admin_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.admin_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admin_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.admin_history_id_seq OWNED BY ml_app.admin_history.id;


--
-- Name: admins; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.admins (
    id integer NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    sign_in_count integer DEFAULT 0,
    current_sign_in_at timestamp without time zone,
    last_sign_in_at timestamp without time zone,
    current_sign_in_ip character varying,
    last_sign_in_ip character varying,
    failed_attempts integer DEFAULT 0,
    unlock_token character varying,
    locked_at timestamp without time zone,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    disabled boolean,
    encrypted_otp_secret character varying,
    encrypted_otp_secret_iv character varying,
    encrypted_otp_secret_salt character varying,
    consumed_timestep integer,
    otp_required_for_login boolean,
    reset_password_sent_at timestamp without time zone,
    password_updated_at timestamp without time zone,
    first_name character varying,
    last_name character varying,
    do_not_email boolean DEFAULT false,
    admin_id bigint,
    capabilities character varying[]
);


--
-- Name: admins_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.admins_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admins_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.admins_id_seq OWNED BY ml_app.admins.id;


--
-- Name: app_configuration_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.app_configuration_history (
    id integer NOT NULL,
    name character varying,
    value character varying,
    app_type_id bigint,
    user_id bigint,
    role_name character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    app_configuration_id integer
);


--
-- Name: app_configuration_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.app_configuration_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_configuration_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.app_configuration_history_id_seq OWNED BY ml_app.app_configuration_history.id;


--
-- Name: app_configurations; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.app_configurations (
    id integer NOT NULL,
    name character varying,
    value character varying,
    disabled boolean,
    admin_id integer,
    user_id integer,
    app_type_id integer,
    role_name character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: app_configurations_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.app_configurations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_configurations_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.app_configurations_id_seq OWNED BY ml_app.app_configurations.id;


--
-- Name: app_type_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.app_type_history (
    id integer NOT NULL,
    name character varying,
    label character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    app_type_id integer
);


--
-- Name: app_type_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.app_type_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_type_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.app_type_history_id_seq OWNED BY ml_app.app_type_history.id;


--
-- Name: app_types; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.app_types (
    id integer NOT NULL,
    name character varying,
    label character varying,
    disabled boolean,
    admin_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    default_schema_name character varying
);


--
-- Name: app_types_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.app_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_types_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.app_types_id_seq OWNED BY ml_app.app_types.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: bhs_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.bhs_assignment_history (
    id integer NOT NULL,
    master_id integer,
    bhs_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    bhs_assignment_table_id integer
);


--
-- Name: bhs_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.bhs_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bhs_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.bhs_assignment_history_id_seq OWNED BY ml_app.bhs_assignment_history.id;


--
-- Name: bhs_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.bhs_assignments (
    id integer NOT NULL,
    master_id integer,
    bhs_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: bhs_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.bhs_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bhs_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.bhs_assignments_id_seq OWNED BY ml_app.bhs_assignments.id;


--
-- Name: college_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.college_history (
    id integer NOT NULL,
    name character varying,
    synonym_for_id integer,
    disabled boolean,
    admin_id integer,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    college_id integer
);


--
-- Name: college_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.college_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: college_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.college_history_id_seq OWNED BY ml_app.college_history.id;


--
-- Name: colleges; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.colleges (
    id integer NOT NULL,
    name character varying,
    synonym_for_id integer,
    disabled boolean,
    admin_id integer,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: colleges_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.colleges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: colleges_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.colleges_id_seq OWNED BY ml_app.colleges.id;


--
-- Name: config_libraries; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.config_libraries (
    id integer NOT NULL,
    category character varying,
    name character varying,
    options character varying,
    format character varying,
    disabled boolean DEFAULT false,
    admin_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: config_libraries_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.config_libraries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: config_libraries_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.config_libraries_id_seq OWNED BY ml_app.config_libraries.id;


--
-- Name: config_library_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.config_library_history (
    id integer NOT NULL,
    category character varying,
    name character varying,
    options character varying,
    format character varying,
    disabled boolean DEFAULT false,
    admin_id integer,
    config_library_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: config_library_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.config_library_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: config_library_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.config_library_history_id_seq OWNED BY ml_app.config_library_history.id;


--
-- Name: copy_player_infos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.copy_player_infos (
    id integer,
    master_id integer,
    first_name character varying,
    last_name character varying,
    middle_name character varying,
    nick_name character varying,
    birth_date date,
    death_date date,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    contact_pref character varying,
    start_year integer,
    rank integer,
    notes character varying,
    contactid integer,
    college character varying,
    end_year integer,
    source character varying
);


--
-- Name: delayed_jobs; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.delayed_jobs (
    id integer NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    handler text NOT NULL,
    last_error text,
    run_at timestamp without time zone,
    locked_at timestamp without time zone,
    failed_at timestamp without time zone,
    locked_by character varying,
    queue character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: delayed_jobs_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.delayed_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: delayed_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.delayed_jobs_id_seq OWNED BY ml_app.delayed_jobs.id;


--
-- Name: dynamic_model_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.dynamic_model_history (
    id integer NOT NULL,
    name character varying,
    table_name character varying,
    schema_name character varying,
    primary_key_name character varying,
    foreign_key_name character varying,
    description character varying,
    admin_id integer,
    disabled boolean,
    "position" integer,
    category character varying,
    table_key_name character varying,
    field_list character varying,
    result_order character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    dynamic_model_id integer,
    options character varying
);


--
-- Name: dynamic_model_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.dynamic_model_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dynamic_model_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.dynamic_model_history_id_seq OWNED BY ml_app.dynamic_model_history.id;


--
-- Name: dynamic_models; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.dynamic_models (
    id integer NOT NULL,
    name character varying,
    table_name character varying,
    schema_name character varying,
    primary_key_name character varying,
    foreign_key_name character varying,
    description character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    "position" integer,
    category character varying,
    table_key_name character varying,
    field_list character varying,
    result_order character varying,
    options character varying
);


--
-- Name: dynamic_models_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.dynamic_models_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dynamic_models_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.dynamic_models_id_seq OWNED BY ml_app.dynamic_models.id;


--
-- Name: exception_logs; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.exception_logs (
    id integer NOT NULL,
    message character varying,
    main character varying,
    backtrace character varying,
    user_id integer,
    admin_id integer,
    notified_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: exception_logs_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.exception_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exception_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.exception_logs_id_seq OWNED BY ml_app.exception_logs.id;


--
-- Name: ext_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.ext_assignment_history (
    id integer NOT NULL,
    master_id integer,
    ext_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    ext_assignment_table_id integer
);


--
-- Name: ext_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.ext_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ext_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.ext_assignment_history_id_seq OWNED BY ml_app.ext_assignment_history.id;


--
-- Name: ext_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.ext_assignments (
    id integer NOT NULL,
    master_id integer,
    ext_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: ext_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.ext_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ext_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.ext_assignments_id_seq OWNED BY ml_app.ext_assignments.id;


--
-- Name: ext_gen_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.ext_gen_assignment_history (
    id integer NOT NULL,
    master_id integer,
    ext_gen_id integer,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    ext_gen_assignment_table_id integer
);


--
-- Name: ext_gen_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.ext_gen_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ext_gen_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.ext_gen_assignment_history_id_seq OWNED BY ml_app.ext_gen_assignment_history.id;


--
-- Name: ext_gen_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.ext_gen_assignments (
    id integer NOT NULL,
    master_id integer,
    ext_gen_id integer,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: ext_gen_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.ext_gen_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ext_gen_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.ext_gen_assignments_id_seq OWNED BY ml_app.ext_gen_assignments.id;


--
-- Name: external_identifier_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.external_identifier_history (
    id integer NOT NULL,
    name character varying,
    label character varying,
    external_id_attribute character varying,
    external_id_view_formatter character varying,
    external_id_edit_pattern character varying,
    prevent_edit boolean,
    pregenerate_ids boolean,
    min_id bigint,
    max_id bigint,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    external_identifier_id integer,
    extra_fields character varying,
    alphanumeric boolean,
    schema_name character varying,
    options character varying
);


--
-- Name: external_identifier_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.external_identifier_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: external_identifier_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.external_identifier_history_id_seq OWNED BY ml_app.external_identifier_history.id;


--
-- Name: external_identifiers; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.external_identifiers (
    id integer NOT NULL,
    name character varying,
    label character varying,
    external_id_attribute character varying,
    external_id_view_formatter character varying,
    external_id_edit_pattern character varying,
    prevent_edit boolean,
    pregenerate_ids boolean,
    min_id bigint,
    max_id bigint,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    alphanumeric boolean,
    extra_fields character varying,
    category character varying,
    schema_name character varying,
    options character varying
);


--
-- Name: external_identifiers_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.external_identifiers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: external_identifiers_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.external_identifiers_id_seq OWNED BY ml_app.external_identifiers.id;


--
-- Name: external_link_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.external_link_history (
    id integer NOT NULL,
    name character varying,
    value character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    external_link_id integer
);


--
-- Name: external_link_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.external_link_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: external_link_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.external_link_history_id_seq OWNED BY ml_app.external_link_history.id;


--
-- Name: external_links; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.external_links (
    id integer NOT NULL,
    name character varying,
    value character varying,
    disabled boolean,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: external_links_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.external_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: external_links_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.external_links_id_seq OWNED BY ml_app.external_links.id;


--
-- Name: general_selection_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.general_selection_history (
    id integer NOT NULL,
    name character varying,
    value character varying,
    item_type character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    admin_id integer,
    create_with boolean,
    edit_if_set boolean,
    edit_always boolean,
    "position" integer,
    description character varying,
    lock boolean,
    general_selection_id integer
);


--
-- Name: general_selection_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.general_selection_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: general_selection_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.general_selection_history_id_seq OWNED BY ml_app.general_selection_history.id;


--
-- Name: general_selections; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.general_selections (
    id integer NOT NULL,
    name character varying,
    value character varying,
    item_type character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    admin_id integer,
    create_with boolean,
    edit_if_set boolean,
    edit_always boolean,
    "position" integer,
    description character varying,
    lock boolean
);


--
-- Name: general_selections_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.general_selections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: general_selections_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.general_selections_id_seq OWNED BY ml_app.general_selections.id;


--
-- Name: grit_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.grit_assignment_history (
    id integer NOT NULL,
    master_id integer,
    grit_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    grit_assignment_table_id integer
);


--
-- Name: grit_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.grit_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: grit_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.grit_assignment_history_id_seq OWNED BY ml_app.grit_assignment_history.id;


--
-- Name: grit_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.grit_assignments (
    id integer NOT NULL,
    master_id integer,
    grit_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: grit_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.grit_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: grit_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.grit_assignments_id_seq OWNED BY ml_app.grit_assignments.id;


--
-- Name: imports; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.imports (
    id integer NOT NULL,
    primary_table character varying,
    item_count integer,
    filename character varying,
    imported_items integer[],
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: imports_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.imports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: imports_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.imports_id_seq OWNED BY ml_app.imports.id;


--
-- Name: imports_model_generators; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.imports_model_generators (
    id bigint NOT NULL,
    name character varying,
    dynamic_model_table character varying,
    options json,
    description character varying,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: imports_model_generators_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.imports_model_generators_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: imports_model_generators_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.imports_model_generators_id_seq OWNED BY ml_app.imports_model_generators.id;


--
-- Name: item_flag_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.item_flag_history (
    id integer NOT NULL,
    item_id integer,
    item_type character varying,
    item_flag_name_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    user_id integer,
    item_flag_id integer,
    disabled boolean
);


--
-- Name: item_flag_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.item_flag_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: item_flag_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.item_flag_history_id_seq OWNED BY ml_app.item_flag_history.id;


--
-- Name: item_flag_name_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.item_flag_name_history (
    id integer NOT NULL,
    name character varying,
    item_type character varying,
    disabled boolean,
    admin_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    item_flag_name_id integer
);


--
-- Name: item_flag_name_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.item_flag_name_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: item_flag_name_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.item_flag_name_history_id_seq OWNED BY ml_app.item_flag_name_history.id;


--
-- Name: item_flag_names; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.item_flag_names (
    id integer NOT NULL,
    name character varying,
    item_type character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    admin_id integer
);


--
-- Name: item_flag_names_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.item_flag_names_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: item_flag_names_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.item_flag_names_id_seq OWNED BY ml_app.item_flag_names.id;


--
-- Name: item_flags; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.item_flags (
    id integer NOT NULL,
    item_id integer,
    item_type character varying,
    item_flag_name_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    user_id integer,
    disabled boolean
);


--
-- Name: item_flags_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.item_flags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: item_flags_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.item_flags_id_seq OWNED BY ml_app.item_flags.id;


--
-- Name: manage_users; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.manage_users (
    id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: manage_users_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.manage_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: manage_users_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.manage_users_id_seq OWNED BY ml_app.manage_users.id;


--
-- Name: marketo_ids; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.marketo_ids (
    id integer NOT NULL,
    email character varying
);


--
-- Name: marketo_ids_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.marketo_ids_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: marketo_ids_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.marketo_ids_id_seq OWNED BY ml_app.marketo_ids.id;


--
-- Name: marketo_master_ids; Type: VIEW; Schema: ml_app; Owner: -
--

CREATE VIEW ml_app.marketo_master_ids AS
 SELECT DISTINCT ON (mi.id) mi.id,
    mi.id AS marketo_id,
    pc.master_id,
    NULL::timestamp without time zone AS created_at,
    NULL::timestamp without time zone AS updated_at,
    NULL::integer AS user_id
   FROM (ml_app.marketo_ids mi
     JOIN ml_app.player_contacts pc ON ((((pc.data)::text = (mi.email)::text) AND ((pc.rec_type)::text = 'email'::text))));


--
-- Name: masters; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.masters (
    id integer NOT NULL,
    msid integer,
    pro_id integer,
    pro_info_id integer,
    rank integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    user_id integer,
    contact_id integer,
    created_by_user_id bigint
);


--
-- Name: masters_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.masters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: masters_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.masters_id_seq OWNED BY ml_app.masters.id;


--
-- Name: message_notifications; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.message_notifications (
    id integer NOT NULL,
    app_type_id integer,
    master_id integer,
    user_id integer,
    item_id integer,
    item_type character varying,
    message_type character varying,
    recipient_user_ids integer[],
    layout_template_name character varying,
    content_template_name character varying,
    generated_content character varying,
    status character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    status_changed character varying,
    subject character varying,
    data json,
    recipient_data character varying[],
    from_user_email character varying,
    role_name character varying,
    content_template_text character varying,
    importance character varying,
    extra_substitutions character varying,
    content_hash character varying
);


--
-- Name: message_notifications_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.message_notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.message_notifications_id_seq OWNED BY ml_app.message_notifications.id;


--
-- Name: message_template_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.message_template_history (
    id integer NOT NULL,
    name character varying,
    template_type character varying,
    template character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    message_template_id integer,
    message_type character varying,
    category character varying
);


--
-- Name: message_template_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.message_template_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_template_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.message_template_history_id_seq OWNED BY ml_app.message_template_history.id;


--
-- Name: message_templates; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.message_templates (
    id integer NOT NULL,
    name character varying,
    message_type character varying,
    template_type character varying,
    template character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    category character varying
);


--
-- Name: message_templates_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.message_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.message_templates_id_seq OWNED BY ml_app.message_templates.id;


--
-- Name: ml_copy; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.ml_copy (
    procontactid integer,
    fill_in_addresses character varying(255),
    in_survey character varying(255),
    verify_survey_participation character varying(255),
    verify_player_and_or_match character varying(255),
    accuracy character varying(255),
    accuracy_score character varying(255),
    contactid integer,
    pro_id integer,
    separator_a text,
    first_name character varying(255),
    middle_name character varying(255),
    last_name character varying(255),
    nick_name character varying(255),
    separator_b text,
    pro_first_name character varying(255),
    pro_middle_name character varying(255),
    pro_last_name character varying(255),
    pro_nick_name character varying(255),
    birthdate character varying(255),
    pro_dob character varying(255),
    pro_dod character varying(255),
    startyear character varying(255),
    pro_start_year character varying(255),
    accruedseasons integer,
    pro_end_year character varying(255),
    first_contract character varying(255),
    second_contract character varying(255),
    third_contract character varying(255),
    pro_career_info character varying(255),
    pro_birthplace character varying(255),
    pro_college character varying(255),
    email character varying(255),
    homecity character varying(255),
    homestate character varying(50),
    homezipcode character varying(10),
    homestreet character varying(255),
    homestreet2 character varying(255),
    homestreet3 character varying(255),
    businesscity character varying(255),
    businessstate character varying(50),
    businesszipcode character varying(10),
    businessstreet character varying(255),
    businessstreet2 character varying(255),
    businessstreet3 character varying(255),
    changed integer,
    changed_column character varying(255),
    verified integer,
    notes text,
    email2 character varying(255),
    email3 character varying(255),
    updatehomestreet character varying(255),
    updatehomestreet2 character varying(255),
    updatehomecity character varying(255),
    updatehomestate character varying(50),
    updatehomezipcode character varying(10),
    lastmod character varying(255),
    sourc character varying(255),
    changed_by character varying(255),
    msid integer,
    mailing character varying(255),
    outreach_vfy character varying(255),
    lastupdate text,
    lastupdateby text,
    cprefs character varying(255),
    scantronid integer,
    insertauditkey text
);


--
-- Name: model_references; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.model_references (
    id integer NOT NULL,
    from_record_type character varying,
    from_record_id integer,
    from_record_master_id integer,
    to_record_type character varying,
    to_record_id integer,
    to_record_master_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean
);


--
-- Name: model_references_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.model_references_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: model_references_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.model_references_id_seq OWNED BY ml_app.model_references.id;


--
-- Name: msid_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.msid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: new_test_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.new_test_history (
    id integer NOT NULL,
    master_id integer,
    new_test_ext_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    new_test_table_id integer
);


--
-- Name: new_test_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.new_test_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: new_test_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.new_test_history_id_seq OWNED BY ml_app.new_test_history.id;


--
-- Name: new_tests; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.new_tests (
    id integer NOT NULL,
    master_id integer,
    new_test_ext_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: new_tests_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.new_tests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: new_tests_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.new_tests_id_seq OWNED BY ml_app.new_tests.id;


--
-- Name: nfs_store_archived_file_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_archived_file_history (
    id integer NOT NULL,
    file_hash character varying,
    file_name character varying,
    content_type character varying,
    archive_file character varying,
    path character varying,
    file_size character varying,
    file_updated_at character varying,
    nfs_store_container_id bigint,
    title character varying,
    description character varying,
    file_metadata character varying,
    nfs_store_stored_file_id bigint,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    nfs_store_archived_file_id integer,
    embed_resource_name character varying,
    embed_resource_id bigint
);


--
-- Name: nfs_store_archived_file_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_archived_file_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_archived_file_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_archived_file_history_id_seq OWNED BY ml_app.nfs_store_archived_file_history.id;


--
-- Name: nfs_store_archived_files_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_archived_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_archived_files_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_archived_files_id_seq OWNED BY ml_app.nfs_store_archived_files.id;


--
-- Name: nfs_store_container_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_container_history (
    id integer NOT NULL,
    master_id integer,
    name character varying,
    app_type_id bigint,
    orig_nfs_store_container_id bigint,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    nfs_store_container_id integer,
    created_by_user_id bigint
);


--
-- Name: nfs_store_container_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_container_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_container_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_container_history_id_seq OWNED BY ml_app.nfs_store_container_history.id;


--
-- Name: nfs_store_containers; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_containers (
    id integer NOT NULL,
    name character varying,
    user_id integer,
    app_type_id integer,
    nfs_store_container_id integer,
    master_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    created_by_user_id bigint
);


--
-- Name: nfs_store_containers_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_containers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_containers_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_containers_id_seq OWNED BY ml_app.nfs_store_containers.id;


--
-- Name: nfs_store_downloads; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_downloads (
    id integer NOT NULL,
    user_groups integer[] DEFAULT '{}'::integer[],
    path character varying,
    retrieval_path character varying,
    retrieved_items character varying,
    user_id integer NOT NULL,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    nfs_store_container_ids integer[]
);


--
-- Name: nfs_store_downloads_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_downloads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_downloads_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_downloads_id_seq OWNED BY ml_app.nfs_store_downloads.id;


--
-- Name: nfs_store_filter_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_filter_history (
    id integer NOT NULL,
    app_type_id bigint,
    role_name character varying,
    user_id bigint,
    resource_name character varying,
    filter character varying,
    description character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    nfs_store_filter_id integer
);


--
-- Name: nfs_store_filter_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_filter_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_filter_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_filter_history_id_seq OWNED BY ml_app.nfs_store_filter_history.id;


--
-- Name: nfs_store_filters; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_filters (
    id integer NOT NULL,
    app_type_id integer,
    role_name character varying,
    user_id integer,
    resource_name character varying,
    filter character varying,
    description character varying,
    disabled boolean,
    admin_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: nfs_store_filters_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_filters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_filters_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_filters_id_seq OWNED BY ml_app.nfs_store_filters.id;


--
-- Name: nfs_store_imports; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_imports (
    id integer NOT NULL,
    file_hash character varying,
    file_name character varying,
    user_id integer,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    path character varying
);


--
-- Name: nfs_store_imports_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_imports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_imports_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_imports_id_seq OWNED BY ml_app.nfs_store_imports.id;


--
-- Name: nfs_store_move_actions; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_move_actions (
    id integer NOT NULL,
    user_groups integer[],
    path character varying,
    new_path character varying,
    retrieval_path character varying,
    moved_items character varying,
    nfs_store_container_ids integer[],
    user_id integer NOT NULL,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: nfs_store_move_actions_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_move_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_move_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_move_actions_id_seq OWNED BY ml_app.nfs_store_move_actions.id;


--
-- Name: nfs_store_stored_file_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_stored_file_history (
    id integer NOT NULL,
    file_hash character varying,
    file_name character varying,
    content_type character varying,
    path character varying,
    file_size character varying,
    file_updated_at character varying,
    nfs_store_container_id bigint,
    title character varying,
    description character varying,
    file_metadata character varying,
    last_process_name_run character varying,
    user_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    nfs_store_stored_file_id integer,
    embed_resource_name character varying,
    embed_resource_id bigint
);


--
-- Name: nfs_store_stored_file_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_stored_file_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_stored_file_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_stored_file_history_id_seq OWNED BY ml_app.nfs_store_stored_file_history.id;


--
-- Name: nfs_store_stored_files_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_stored_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_stored_files_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_stored_files_id_seq OWNED BY ml_app.nfs_store_stored_files.id;


--
-- Name: nfs_store_trash_actions; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_trash_actions (
    id integer NOT NULL,
    user_groups integer[] DEFAULT '{}'::integer[],
    path character varying,
    retrieval_path character varying,
    trashed_items character varying,
    nfs_store_container_ids integer[],
    user_id integer NOT NULL,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: nfs_store_trash_actions_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_trash_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_trash_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_trash_actions_id_seq OWNED BY ml_app.nfs_store_trash_actions.id;


--
-- Name: nfs_store_uploads; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_uploads (
    id integer NOT NULL,
    file_hash character varying NOT NULL,
    file_name character varying NOT NULL,
    content_type character varying NOT NULL,
    file_size bigint NOT NULL,
    chunk_count integer,
    completed boolean,
    file_updated_at timestamp without time zone,
    user_id integer,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    path character varying,
    nfs_store_stored_file_id integer,
    upload_set character varying
);


--
-- Name: nfs_store_uploads_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_uploads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_uploads_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_uploads_id_seq OWNED BY ml_app.nfs_store_uploads.id;


--
-- Name: nfs_store_user_file_actions; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.nfs_store_user_file_actions (
    id integer NOT NULL,
    user_groups integer[],
    path character varying,
    new_path character varying,
    action character varying,
    retrieval_path character varying,
    action_items character varying,
    nfs_store_container_ids integer[],
    user_id integer NOT NULL,
    nfs_store_container_id integer,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: nfs_store_user_file_actions_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.nfs_store_user_file_actions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nfs_store_user_file_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.nfs_store_user_file_actions_id_seq OWNED BY ml_app.nfs_store_user_file_actions.id;


--
-- Name: page_layout_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.page_layout_history (
    id integer NOT NULL,
    layout_name character varying,
    panel_name character varying,
    panel_label character varying,
    panel_position character varying,
    options character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    page_layout_id integer,
    app_type_id character varying,
    description character varying
);


--
-- Name: page_layout_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.page_layout_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: page_layout_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.page_layout_history_id_seq OWNED BY ml_app.page_layout_history.id;


--
-- Name: page_layouts; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.page_layouts (
    id integer NOT NULL,
    app_type_id integer,
    layout_name character varying,
    panel_name character varying,
    panel_label character varying,
    panel_position integer,
    options character varying,
    disabled boolean,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    description character varying
);


--
-- Name: page_layouts_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.page_layouts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: page_layouts_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.page_layouts_id_seq OWNED BY ml_app.page_layouts.id;


--
-- Name: player_contact_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.player_contact_history (
    id integer NOT NULL,
    master_id integer,
    rec_type character varying,
    data character varying,
    source character varying,
    rank integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:36.835851'::timestamp without time zone,
    player_contact_id integer
);


--
-- Name: player_contact_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.player_contact_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: player_contact_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.player_contact_history_id_seq OWNED BY ml_app.player_contact_history.id;


--
-- Name: player_contacts_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.player_contacts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: player_contacts_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.player_contacts_id_seq OWNED BY ml_app.player_contacts.id;


--
-- Name: player_info_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.player_info_history (
    id integer NOT NULL,
    master_id integer,
    first_name character varying,
    last_name character varying,
    middle_name character varying,
    nick_name character varying,
    birth_date date,
    death_date date,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:36.99602'::timestamp without time zone,
    contact_pref character varying,
    start_year integer,
    rank integer,
    notes character varying,
    contact_id integer,
    college character varying,
    end_year integer,
    source character varying,
    player_info_id integer
);


--
-- Name: player_info_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.player_info_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: player_info_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.player_info_history_id_seq OWNED BY ml_app.player_info_history.id;


--
-- Name: player_infos_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.player_infos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: player_infos_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.player_infos_id_seq OWNED BY ml_app.player_infos.id;


--
-- Name: pro_infos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.pro_infos (
    id integer NOT NULL,
    master_id integer,
    pro_id integer,
    first_name character varying,
    middle_name character varying,
    nick_name character varying,
    last_name character varying,
    birth_date date,
    death_date date,
    start_year integer,
    end_year integer,
    college character varying,
    birthplace character varying,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:37.165247'::timestamp without time zone
);


--
-- Name: pro_infos_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.pro_infos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pro_infos_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.pro_infos_id_seq OWNED BY ml_app.pro_infos.id;


--
-- Name: protocol_event_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.protocol_event_history (
    id integer NOT NULL,
    name character varying,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    sub_process_id integer,
    milestone character varying,
    description character varying,
    protocol_event_id integer
);


--
-- Name: protocol_event_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.protocol_event_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: protocol_event_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.protocol_event_history_id_seq OWNED BY ml_app.protocol_event_history.id;


--
-- Name: protocol_events; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.protocol_events (
    id integer NOT NULL,
    name character varying,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    sub_process_id integer,
    milestone character varying,
    description character varying
);


--
-- Name: protocol_events_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.protocol_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: protocol_events_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.protocol_events_id_seq OWNED BY ml_app.protocol_events.id;


--
-- Name: protocol_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.protocol_history (
    id integer NOT NULL,
    name character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    admin_id integer,
    "position" integer,
    protocol_id integer
);


--
-- Name: protocol_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.protocol_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: protocol_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.protocol_history_id_seq OWNED BY ml_app.protocol_history.id;


--
-- Name: protocols; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.protocols (
    id integer NOT NULL,
    name character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    disabled boolean,
    admin_id integer,
    "position" integer,
    app_type_id bigint
);


--
-- Name: protocols_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.protocols_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: protocols_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.protocols_id_seq OWNED BY ml_app.protocols.id;


--
-- Name: rc_cis; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.rc_cis (
    id integer NOT NULL,
    fname character varying,
    lname character varying,
    status character varying,
    created_at timestamp without time zone DEFAULT '2017-09-25 15:43:37.367264'::timestamp without time zone,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:37.367264'::timestamp without time zone,
    user_id integer,
    master_id integer,
    street character varying,
    street2 character varying,
    city character varying,
    state character varying,
    zip character varying,
    phone character varying,
    email character varying,
    form_date timestamp without time zone
);


--
-- Name: rc_cis2; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.rc_cis2 (
    id integer,
    fname character varying,
    lname character varying,
    status character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    user_id integer
);


--
-- Name: rc_cis_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.rc_cis_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rc_cis_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.rc_cis_id_seq OWNED BY ml_app.rc_cis.id;


--
-- Name: rc_stage_cif_copy; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.rc_stage_cif_copy (
    id integer NOT NULL,
    record_id integer,
    redcap_survey_identifier integer,
    time_stamp timestamp without time zone,
    first_name character varying,
    middle_name character varying,
    last_name character varying,
    nick_name character varying,
    street character varying,
    street2 character varying,
    city character varying,
    state character varying,
    zipcode character varying,
    phone character varying,
    email character varying,
    hearabout character varying,
    completed integer,
    status character varying,
    created_at timestamp without time zone DEFAULT '2017-09-25 15:43:37.419709'::timestamp without time zone,
    user_id integer,
    master_id integer,
    updated_at timestamp without time zone DEFAULT '2017-09-25 15:43:37.419709'::timestamp without time zone,
    added_tracker boolean
);


--
-- Name: rc_stage_cif_copy_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.rc_stage_cif_copy_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rc_stage_cif_copy_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.rc_stage_cif_copy_id_seq OWNED BY ml_app.rc_stage_cif_copy.id;


--
-- Name: report_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.report_history (
    id integer NOT NULL,
    name character varying,
    description character varying,
    sql character varying,
    search_attrs character varying,
    admin_id integer,
    disabled boolean,
    report_type character varying,
    auto boolean,
    searchable boolean,
    "position" integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    report_id integer,
    item_type character varying,
    edit_model character varying,
    edit_field_names character varying,
    selection_fields character varying,
    short_name character varying,
    options character varying
);


--
-- Name: report_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.report_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: report_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.report_history_id_seq OWNED BY ml_app.report_history.id;


--
-- Name: reports; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.reports (
    id integer NOT NULL,
    name character varying,
    description character varying,
    sql character varying,
    search_attrs character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    report_type character varying,
    auto boolean,
    searchable boolean,
    "position" integer,
    edit_model character varying,
    edit_field_names character varying,
    selection_fields character varying,
    item_type character varying,
    short_name character varying,
    options character varying
);


--
-- Name: reports_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reports_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.reports_id_seq OWNED BY ml_app.reports.id;


--
-- Name: role_description_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.role_description_history (
    id bigint NOT NULL,
    role_description_id bigint,
    app_type_id bigint,
    role_name character varying,
    role_template character varying,
    name character varying,
    description character varying,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: role_description_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.role_description_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_description_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.role_description_history_id_seq OWNED BY ml_app.role_description_history.id;


--
-- Name: role_descriptions; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.role_descriptions (
    id bigint NOT NULL,
    app_type_id bigint,
    role_name character varying,
    role_template character varying,
    name character varying,
    description character varying,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: role_descriptions_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.role_descriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_descriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.role_descriptions_id_seq OWNED BY ml_app.role_descriptions.id;


--
-- Name: sage_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sage_assignments (
    id integer NOT NULL,
    sage_id character varying(10),
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    master_id integer,
    admin_id integer
);


--
-- Name: sage_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sage_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sage_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sage_assignments_id_seq OWNED BY ml_app.sage_assignments.id;


--
-- Name: sage_two_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sage_two_history (
    id integer NOT NULL,
    sage_two_id integer,
    master_id integer,
    external_id bigint,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: sage_two_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sage_two_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sage_two_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sage_two_history_id_seq OWNED BY ml_app.sage_two_history.id;


--
-- Name: sage_twos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sage_twos (
    id integer NOT NULL,
    master_id integer,
    external_id bigint,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: sage_twos_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sage_twos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sage_twos_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sage_twos_id_seq OWNED BY ml_app.sage_twos.id;


--
-- Name: scantron_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.scantron_history (
    id integer NOT NULL,
    master_id integer,
    scantron_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    scantron_table_id integer
);


--
-- Name: scantron_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.scantron_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scantron_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.scantron_history_id_seq OWNED BY ml_app.scantron_history.id;


--
-- Name: scantron_q2_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.scantron_q2_history (
    id integer NOT NULL,
    master_id integer,
    q2_scantron_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    scantron_q2_table_id integer
);


--
-- Name: scantron_q2_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.scantron_q2_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scantron_q2_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.scantron_q2_history_id_seq OWNED BY ml_app.scantron_q2_history.id;


--
-- Name: scantron_q2s; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.scantron_q2s (
    id integer NOT NULL,
    master_id integer,
    q2_scantron_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: scantron_q2s_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.scantron_q2s_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scantron_q2s_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.scantron_q2s_id_seq OWNED BY ml_app.scantron_q2s.id;


--
-- Name: scantron_series_two_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.scantron_series_two_history (
    id integer NOT NULL,
    scantron_series_two_id integer,
    master_id integer,
    external_id bigint,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: scantron_series_two_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.scantron_series_two_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scantron_series_two_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.scantron_series_two_history_id_seq OWNED BY ml_app.scantron_series_two_history.id;


--
-- Name: scantron_series_twos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.scantron_series_twos (
    id integer NOT NULL,
    master_id integer,
    external_id bigint,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: scantron_series_twos_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.scantron_series_twos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scantron_series_twos_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.scantron_series_twos_id_seq OWNED BY ml_app.scantron_series_twos.id;


--
-- Name: scantrons; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.scantrons (
    id integer NOT NULL,
    master_id integer,
    scantron_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: scantrons_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.scantrons_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scantrons_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.scantrons_id_seq OWNED BY ml_app.scantrons.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sessions (
    id bigint NOT NULL,
    session_id character varying NOT NULL,
    data text,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sessions_id_seq OWNED BY ml_app.sessions.id;


--
-- Name: sleep_assignment_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sleep_assignment_history (
    id integer NOT NULL,
    master_id integer,
    sleep_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    sleep_assignment_table_id integer
);


--
-- Name: sleep_assignment_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sleep_assignment_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sleep_assignment_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sleep_assignment_history_id_seq OWNED BY ml_app.sleep_assignment_history.id;


--
-- Name: sleep_assignments; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sleep_assignments (
    id integer NOT NULL,
    master_id integer,
    sleep_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: sleep_assignments_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sleep_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sleep_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sleep_assignments_id_seq OWNED BY ml_app.sleep_assignments.id;


--
-- Name: smback; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.smback (
    version character varying
);


--
-- Name: sub_process_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sub_process_history (
    id integer NOT NULL,
    name character varying,
    disabled boolean,
    protocol_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    sub_process_id integer
);


--
-- Name: sub_process_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sub_process_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sub_process_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sub_process_history_id_seq OWNED BY ml_app.sub_process_history.id;


--
-- Name: sub_processes; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sub_processes (
    id integer NOT NULL,
    name character varying,
    disabled boolean,
    protocol_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: sub_processes_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sub_processes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sub_processes_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sub_processes_id_seq OWNED BY ml_app.sub_processes.id;


--
-- Name: sync_statuses; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.sync_statuses (
    id integer NOT NULL,
    from_db character varying,
    from_master_id integer,
    to_db character varying,
    to_master_id integer,
    select_status character varying DEFAULT 'new'::character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    external_id character varying,
    external_type character varying,
    event character varying
);


--
-- Name: sync_statuses_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.sync_statuses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sync_statuses_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.sync_statuses_id_seq OWNED BY ml_app.sync_statuses.id;


--
-- Name: test1_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test1_history (
    id integer NOT NULL,
    master_id integer,
    test1_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    test1_table_id integer
);


--
-- Name: test1_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test1_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test1_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test1_history_id_seq OWNED BY ml_app.test1_history.id;


--
-- Name: test1s; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test1s (
    id integer NOT NULL,
    master_id integer,
    test1_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test1s_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test1s_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test1s_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test1s_id_seq OWNED BY ml_app.test1s.id;


--
-- Name: test2_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test2_history (
    id integer NOT NULL,
    master_id integer,
    test_2ext_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    test2_table_id integer
);


--
-- Name: test2_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test2_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test2_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test2_history_id_seq OWNED BY ml_app.test2_history.id;


--
-- Name: test2s; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test2s (
    id integer NOT NULL,
    master_id integer,
    test_2ext_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test2s_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test2s_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test2s_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test2s_id_seq OWNED BY ml_app.test2s.id;


--
-- Name: test_2_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_2_history (
    id integer NOT NULL,
    master_id integer,
    test_2ext_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    test_2_table_id integer
);


--
-- Name: test_2_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_2_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_2_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_2_history_id_seq OWNED BY ml_app.test_2_history.id;


--
-- Name: test_2s; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_2s (
    id integer NOT NULL,
    master_id integer,
    test_2ext_id bigint,
    user_id integer,
    admin_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test_2s_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_2s_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_2s_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_2s_id_seq OWNED BY ml_app.test_2s.id;


--
-- Name: test_ext2_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_ext2_history (
    id integer NOT NULL,
    master_id integer,
    test_e2_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    test_ext2_table_id integer
);


--
-- Name: test_ext2_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_ext2_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_ext2_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_ext2_history_id_seq OWNED BY ml_app.test_ext2_history.id;


--
-- Name: test_ext2s; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_ext2s (
    id integer NOT NULL,
    master_id integer,
    test_e2_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test_ext2s_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_ext2s_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_ext2s_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_ext2s_id_seq OWNED BY ml_app.test_ext2s.id;


--
-- Name: test_ext_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_ext_history (
    id integer NOT NULL,
    master_id integer,
    test_e_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    test_ext_table_id integer
);


--
-- Name: test_ext_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_ext_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_ext_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_ext_history_id_seq OWNED BY ml_app.test_ext_history.id;


--
-- Name: test_exts; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_exts (
    id integer NOT NULL,
    master_id integer,
    test_e_id integer,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test_exts_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_exts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_exts_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_exts_id_seq OWNED BY ml_app.test_exts.id;


--
-- Name: test_item_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_item_history (
    id integer NOT NULL,
    test_item_id integer,
    master_id integer,
    external_id bigint,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test_item_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_item_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_item_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_item_history_id_seq OWNED BY ml_app.test_item_history.id;


--
-- Name: test_items; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.test_items (
    id integer NOT NULL,
    master_id integer,
    external_id bigint,
    user_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: test_items_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.test_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: test_items_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.test_items_id_seq OWNED BY ml_app.test_items.id;


--
-- Name: tracker_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.tracker_history (
    id integer NOT NULL,
    master_id integer,
    protocol_id integer,
    tracker_id integer,
    event_date timestamp without time zone,
    user_id integer,
    notes character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    sub_process_id integer,
    protocol_event_id integer,
    item_id integer,
    item_type character varying
);


--
-- Name: tracker_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.tracker_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tracker_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.tracker_history_id_seq OWNED BY ml_app.tracker_history.id;


--
-- Name: trackers; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.trackers (
    id integer NOT NULL,
    master_id integer,
    protocol_id integer NOT NULL,
    event_date timestamp without time zone,
    user_id integer DEFAULT 0,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    notes character varying,
    sub_process_id integer NOT NULL,
    protocol_event_id integer,
    item_id integer,
    item_type character varying
);


--
-- Name: trackers_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.trackers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: trackers_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.trackers_id_seq OWNED BY ml_app.trackers.id;


--
-- Name: user_access_control_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_access_control_history (
    id integer NOT NULL,
    user_id bigint,
    resource_type character varying,
    resource_name character varying,
    options character varying,
    access character varying,
    app_type_id bigint,
    role_name character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    user_access_control_id integer
);


--
-- Name: user_access_control_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_access_control_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_access_control_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_access_control_history_id_seq OWNED BY ml_app.user_access_control_history.id;


--
-- Name: user_access_controls; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_access_controls (
    id integer NOT NULL,
    user_id integer,
    resource_type character varying,
    resource_name character varying,
    options character varying,
    access character varying,
    disabled boolean,
    admin_id integer,
    app_type_id integer,
    role_name character varying,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: user_access_controls_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_access_controls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_access_controls_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_access_controls_id_seq OWNED BY ml_app.user_access_controls.id;


--
-- Name: user_action_logs; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_action_logs (
    id integer NOT NULL,
    user_id integer,
    app_type_id integer,
    master_id integer,
    item_type character varying,
    item_id integer,
    index_action_ids integer[],
    action character varying,
    url character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: user_action_logs_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_action_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_action_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_action_logs_id_seq OWNED BY ml_app.user_action_logs.id;


--
-- Name: user_roles; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_roles (
    id integer NOT NULL,
    app_type_id integer,
    role_name character varying,
    user_id integer,
    admin_id integer,
    disabled boolean DEFAULT false NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: user_app_functional_groups; Type: VIEW; Schema: ml_app; Owner: -
--

CREATE VIEW ml_app.user_app_functional_groups AS
 WITH templates AS (
         SELECT users.id AS user_id,
            users.email AS template_name
           FROM ml_app.users
          WHERE (((users.email)::text ~~ '%@template'::text) AND (NOT COALESCE(users.disabled, false)))
        ), roles AS (
         SELECT ur.app_type_id,
            t.template_name,
            ur.role_name
           FROM (ml_app.user_roles ur
             JOIN templates t ON (((ur.user_id = t.user_id) AND (NOT COALESCE(ur.disabled, false)) AND ((ur.role_name)::text !~~ 'email %'::text) AND ((ur.role_name)::text !~~ 'sms %'::text))))
        ), template_roles AS (
         SELECT roles.app_type_id,
            roles.template_name,
            array_agg(roles.role_name) AS role_set
           FROM roles
          GROUP BY roles.app_type_id, roles.template_name
        ), user_role_sets AS (
         SELECT ur.app_type_id,
            ur.user_id,
            array_agg(ur.role_name) AS role_set
           FROM (ml_app.user_roles ur
             JOIN ml_app.users u ON ((ur.user_id = u.id)))
          WHERE (((u.email)::text !~~ '%template'::text) AND (NOT COALESCE(u.disabled, false)) AND (NOT COALESCE(ur.disabled, false)))
          GROUP BY ur.app_type_id, ur.user_id
        )
 SELECT DISTINCT urs.app_type_id,
    urs.user_id,
    a.label AS app_name,
    u.email AS user_email,
    COALESCE(rd.name, tr.template_name, '(default user)'::character varying) AS group_name
   FROM ((((user_role_sets urs
     LEFT JOIN template_roles tr ON (((tr.app_type_id = urs.app_type_id) AND (tr.role_set <@ urs.role_set))))
     JOIN ml_app.users u ON (((urs.user_id = u.id) AND (NOT COALESCE(u.disabled, false)))))
     JOIN ml_app.app_types a ON ((a.id = urs.app_type_id)))
     LEFT JOIN ml_app.role_descriptions rd ON ((((rd.role_template)::text = (tr.template_name)::text) AND (rd.app_type_id = urs.app_type_id) AND (NOT COALESCE(rd.disabled, false)))))
UNION
 SELECT ur.app_type_id,
    ur.user_id,
    a.label AS app_name,
    u.email AS user_email,
    rd.name AS group_name
   FROM (((ml_app.user_roles ur
     JOIN ml_app.users u ON (((ur.user_id = u.id) AND (NOT COALESCE(u.disabled, false)))))
     JOIN ml_app.role_descriptions rd ON ((((rd.role_name)::text = (ur.role_name)::text) AND (rd.app_type_id = ur.app_type_id) AND (NOT COALESCE(rd.disabled, false)))))
     JOIN ml_app.app_types a ON ((a.id = ur.app_type_id)))
  WHERE (((u.email)::text !~~ '%template'::text) AND (NOT COALESCE(ur.disabled, false)))
  ORDER BY 1, 2, 5;


--
-- Name: user_authorization_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_authorization_history (
    id integer NOT NULL,
    user_id character varying,
    has_authorization character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    user_authorization_id integer
);


--
-- Name: user_authorization_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_authorization_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_authorization_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_authorization_history_id_seq OWNED BY ml_app.user_authorization_history.id;


--
-- Name: user_authorizations; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_authorizations (
    id integer NOT NULL,
    user_id integer,
    has_authorization character varying,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: user_authorizations_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_authorizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_authorizations_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_authorizations_id_seq OWNED BY ml_app.user_authorizations.id;


--
-- Name: user_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_history (
    id integer NOT NULL,
    email character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp without time zone,
    remember_created_at timestamp without time zone,
    sign_in_count integer DEFAULT 0 NOT NULL,
    current_sign_in_at timestamp without time zone,
    last_sign_in_at timestamp without time zone,
    current_sign_in_ip inet,
    last_sign_in_ip inet,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    failed_attempts integer DEFAULT 0 NOT NULL,
    unlock_token character varying,
    locked_at timestamp without time zone,
    disabled boolean,
    admin_id integer,
    user_id integer,
    app_type_id integer,
    authentication_token character varying,
    encrypted_otp_secret character varying,
    encrypted_otp_secret_iv character varying,
    encrypted_otp_secret_salt character varying,
    consumed_timestep integer,
    otp_required_for_login boolean,
    password_updated_at timestamp without time zone,
    first_name character varying,
    last_name character varying,
    confirmation_token character varying,
    confirmed_at timestamp without time zone,
    confirmation_sent_at timestamp without time zone
);


--
-- Name: user_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_history_id_seq OWNED BY ml_app.user_history.id;


--
-- Name: user_preferences; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_preferences (
    id bigint NOT NULL,
    user_id bigint,
    date_format character varying,
    date_time_format character varying,
    time_format character varying,
    timezone character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: user_preferences_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_preferences_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_preferences_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_preferences_id_seq OWNED BY ml_app.user_preferences.id;


--
-- Name: user_role_history; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.user_role_history (
    id integer NOT NULL,
    app_type_id bigint,
    role_name character varying,
    user_id bigint,
    admin_id integer,
    disabled boolean,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    user_role_id integer
);


--
-- Name: user_role_history_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_role_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_role_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_role_history_id_seq OWNED BY ml_app.user_role_history.id;


--
-- Name: user_roles_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.user_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.user_roles_id_seq OWNED BY ml_app.user_roles.id;


--
-- Name: users_contact_infos; Type: TABLE; Schema: ml_app; Owner: -
--

CREATE TABLE ml_app.users_contact_infos (
    id integer NOT NULL,
    user_id integer,
    sms_number character varying,
    phone_number character varying,
    alt_email character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    admin_id integer,
    disabled boolean
);


--
-- Name: users_contact_infos_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.users_contact_infos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_contact_infos_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.users_contact_infos_id_seq OWNED BY ml_app.users_contact_infos.id;


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: ml_app; Owner: -
--

CREATE SEQUENCE ml_app.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: ml_app; Owner: -
--

ALTER SEQUENCE ml_app.users_id_seq OWNED BY ml_app.users.id;


--
-- Name: data_variable_package_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.data_variable_package_history (
    id bigint NOT NULL,
    name character varying,
    description character varying,
    disabled boolean DEFAULT false,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    data_variable_package_id bigint,
    package_type character varying,
    storage_type character varying,
    db_or_fs character varying,
    schema_or_path character varying,
    table_or_file character varying,
    is_static boolean,
    sourced_from_packages character varying,
    n_for_timepoints jsonb,
    tag_select_health_categories character varying[],
    contact_email character varying,
    key_fields character varying[],
    info_url character varying
);


--
-- Name: COLUMN data_variable_package_history.name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.name IS 'Name';


--
-- Name: COLUMN data_variable_package_history.description; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.description IS 'Description';


--
-- Name: COLUMN data_variable_package_history.disabled; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.disabled IS 'Disabled';


--
-- Name: COLUMN data_variable_package_history.package_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.package_type IS 'Package type';


--
-- Name: COLUMN data_variable_package_history.storage_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.storage_type IS 'Type of storage for dataset';


--
-- Name: COLUMN data_variable_package_history.db_or_fs; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.db_or_fs IS 'Database or Filesystem name';


--
-- Name: COLUMN data_variable_package_history.schema_or_path; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.schema_or_path IS 'Database schema or Filesystem directory path';


--
-- Name: COLUMN data_variable_package_history.table_or_file; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.table_or_file IS 'Database table / view name, or filename in directory';


--
-- Name: COLUMN data_variable_package_history.is_static; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.is_static IS 'Static, unchanging dataset';


--
-- Name: COLUMN data_variable_package_history.sourced_from_packages; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.sourced_from_packages IS 'List of packages dataset is sourced from (empty if it is the primary source)';


--
-- Name: COLUMN data_variable_package_history.n_for_timepoints; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.n_for_timepoints IS 'For each named timepoint (name:), the population or count of
responses (n:), with notes (notes:)';


--
-- Name: COLUMN data_variable_package_history.tag_select_health_categories; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.tag_select_health_categories IS 'Health Categories';


--
-- Name: COLUMN data_variable_package_history.contact_email; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.contact_email IS 'Contact or custodian for this package';


--
-- Name: COLUMN data_variable_package_history.key_fields; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.key_fields IS 'Participant identifier/key types';


--
-- Name: COLUMN data_variable_package_history.info_url; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_history.info_url IS 'Documentation';


--
-- Name: data_variable_package_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.data_variable_package_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_variable_package_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.data_variable_package_history_id_seq OWNED BY ref_data.data_variable_package_history.id;


--
-- Name: data_variable_package_var_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.data_variable_package_var_history (
    id bigint NOT NULL,
    record_id bigint,
    record_type character varying,
    disabled boolean DEFAULT false,
    variable_name character varying,
    domain character varying,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    data_variable_package_var_id bigint,
    data_variable_package_id bigint
);


--
-- Name: COLUMN data_variable_package_var_history.record_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_var_history.record_id IS 'Link to Variable';


--
-- Name: COLUMN data_variable_package_var_history.domain; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_var_history.domain IS 'Domain';


--
-- Name: data_variable_package_var_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.data_variable_package_var_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_variable_package_var_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.data_variable_package_var_history_id_seq OWNED BY ref_data.data_variable_package_var_history.id;


--
-- Name: data_variable_package_vars; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.data_variable_package_vars (
    id bigint NOT NULL,
    record_id bigint,
    record_type character varying,
    disabled boolean DEFAULT false,
    variable_name character varying,
    domain character varying,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    data_variable_package_id bigint
);


--
-- Name: TABLE data_variable_package_vars; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.data_variable_package_vars IS 'Dynamicmodel: Data Variable Packages';


--
-- Name: COLUMN data_variable_package_vars.record_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_vars.record_id IS 'Link to Variable';


--
-- Name: COLUMN data_variable_package_vars.domain; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_package_vars.domain IS 'Domain';


--
-- Name: data_variable_package_vars_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.data_variable_package_vars_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_variable_package_vars_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.data_variable_package_vars_id_seq OWNED BY ref_data.data_variable_package_vars.id;


--
-- Name: data_variable_packages; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.data_variable_packages (
    id bigint NOT NULL,
    name character varying,
    description character varying,
    disabled boolean DEFAULT false,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    package_type character varying,
    storage_type character varying,
    db_or_fs character varying,
    schema_or_path character varying,
    table_or_file character varying,
    is_static boolean,
    sourced_from_packages character varying,
    n_for_timepoints jsonb,
    tag_select_health_categories character varying[],
    contact_email character varying,
    key_fields character varying[],
    info_url character varying
);


--
-- Name: TABLE data_variable_packages; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.data_variable_packages IS 'Dynamicmodel: Data Variable Packages';


--
-- Name: COLUMN data_variable_packages.name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.name IS 'Name';


--
-- Name: COLUMN data_variable_packages.description; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.description IS 'Description';


--
-- Name: COLUMN data_variable_packages.disabled; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.disabled IS 'Disabled';


--
-- Name: COLUMN data_variable_packages.package_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.package_type IS 'Package type';


--
-- Name: COLUMN data_variable_packages.storage_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.storage_type IS 'Type of storage for dataset';


--
-- Name: COLUMN data_variable_packages.db_or_fs; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.db_or_fs IS 'Database or Filesystem name';


--
-- Name: COLUMN data_variable_packages.schema_or_path; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.schema_or_path IS 'Database schema or Filesystem directory path';


--
-- Name: COLUMN data_variable_packages.table_or_file; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.table_or_file IS 'Database table / view name, or filename in directory';


--
-- Name: COLUMN data_variable_packages.is_static; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.is_static IS 'Static, unchanging dataset';


--
-- Name: COLUMN data_variable_packages.sourced_from_packages; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.sourced_from_packages IS 'List of packages dataset is sourced from (empty if it is the primary source)';


--
-- Name: COLUMN data_variable_packages.n_for_timepoints; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.n_for_timepoints IS 'For each named timepoint (name:), the population or count of
responses (n:), with notes (notes:)';


--
-- Name: COLUMN data_variable_packages.tag_select_health_categories; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.tag_select_health_categories IS 'Health Categories';


--
-- Name: COLUMN data_variable_packages.contact_email; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.contact_email IS 'Contact or custodian for this package';


--
-- Name: COLUMN data_variable_packages.key_fields; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.key_fields IS 'Participant identifier/key types';


--
-- Name: COLUMN data_variable_packages.info_url; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.data_variable_packages.info_url IS 'Documentation';


--
-- Name: data_variable_packages_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.data_variable_packages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_variable_packages_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.data_variable_packages_id_seq OWNED BY ref_data.data_variable_packages.id;


--
-- Name: datadic_choice_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.datadic_choice_history (
    id bigint NOT NULL,
    datadic_choice_id bigint,
    source_name character varying,
    source_type character varying,
    form_name character varying,
    field_name character varying,
    value character varying,
    label character varying,
    disabled boolean,
    admin_id bigint,
    redcap_data_dictionary_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: datadic_choice_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.datadic_choice_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: datadic_choice_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.datadic_choice_history_id_seq OWNED BY ref_data.datadic_choice_history.id;


--
-- Name: datadic_choices; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.datadic_choices (
    id bigint NOT NULL,
    source_name character varying,
    source_type character varying,
    form_name character varying,
    field_name character varying,
    value character varying,
    label character varying,
    disabled boolean,
    admin_id bigint,
    redcap_data_dictionary_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: datadic_choices_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.datadic_choices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: datadic_choices_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.datadic_choices_id_seq OWNED BY ref_data.datadic_choices.id;


--
-- Name: datadic_variables; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.datadic_variables (
    id bigint NOT NULL,
    study character varying,
    source_name character varying,
    source_type character varying,
    domain character varying,
    form_name character varying,
    variable_name character varying,
    variable_type character varying,
    presentation_type character varying,
    label character varying,
    label_note character varying,
    annotation character varying,
    is_required boolean,
    valid_type character varying,
    valid_min character varying,
    valid_max character varying,
    multi_valid_choices character varying[],
    is_identifier boolean,
    is_derived_var boolean,
    multi_derived_from_id bigint[],
    doc_url character varying,
    target_type character varying,
    owner_email character varying,
    classification character varying,
    other_classification character varying,
    multi_timepoints character varying[],
    equivalent_to_id bigint,
    storage_type character varying,
    db_or_fs character varying,
    schema_or_path character varying,
    table_or_file character varying,
    disabled boolean,
    admin_id bigint,
    redcap_data_dictionary_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    "position" integer,
    section_id integer,
    sub_section_id integer,
    title character varying,
    storage_varname character varying,
    user_id bigint,
    contributor_type character varying,
    n_for_timepoints jsonb,
    notes character varying
);


--
-- Name: TABLE datadic_variables; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.datadic_variables IS 'Dynamicmodel: User Variables';


--
-- Name: COLUMN datadic_variables.study; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.study IS 'Study name';


--
-- Name: COLUMN datadic_variables.source_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.source_name IS 'Source of variable';


--
-- Name: COLUMN datadic_variables.source_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.source_type IS 'Source type';


--
-- Name: COLUMN datadic_variables.domain; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.domain IS 'Domain';


--
-- Name: COLUMN datadic_variables.form_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.form_name IS 'Form name (if the source was a type of form)';


--
-- Name: COLUMN datadic_variables.variable_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.variable_name IS 'Variable name';


--
-- Name: COLUMN datadic_variables.variable_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.variable_type IS 'Variable type';


--
-- Name: COLUMN datadic_variables.presentation_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.presentation_type IS 'Data type for presentation purposes';


--
-- Name: COLUMN datadic_variables.label; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.label IS 'Primary label or title (if source was a form, the label presented for the field)';


--
-- Name: COLUMN datadic_variables.label_note; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.label_note IS 'Description (if source was a form, a note presented for the field)';


--
-- Name: COLUMN datadic_variables.annotation; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.annotation IS 'Annotations (if source was a form, annotations not presented to the user)';


--
-- Name: COLUMN datadic_variables.is_required; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.is_required IS 'Was required in source';


--
-- Name: COLUMN datadic_variables.valid_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.valid_type IS 'Source data type';


--
-- Name: COLUMN datadic_variables.valid_min; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.valid_min IS 'Minimum value';


--
-- Name: COLUMN datadic_variables.valid_max; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.valid_max IS 'Maximum value';


--
-- Name: COLUMN datadic_variables.multi_valid_choices; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.multi_valid_choices IS 'List of valid choices for categorical variables';


--
-- Name: COLUMN datadic_variables.is_identifier; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.is_identifier IS 'Represents identifiable information';


--
-- Name: COLUMN datadic_variables.is_derived_var; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.is_derived_var IS 'Is a derived variable';


--
-- Name: COLUMN datadic_variables.multi_derived_from_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.multi_derived_from_id IS 'If a derived variable, ids of variables used to calculate it';


--
-- Name: COLUMN datadic_variables.doc_url; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.doc_url IS 'URL to additional documentation';


--
-- Name: COLUMN datadic_variables.target_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.target_type IS 'Type of participant this variable relates to';


--
-- Name: COLUMN datadic_variables.owner_email; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.owner_email IS 'Owner, especially for derived variables';


--
-- Name: COLUMN datadic_variables.classification; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.classification IS 'Category of sensitivity from a privacy perspective';


--
-- Name: COLUMN datadic_variables.other_classification; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.other_classification IS 'Additional information regarding classification';


--
-- Name: COLUMN datadic_variables.multi_timepoints; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.multi_timepoints IS 'Timepoints this data is collected (in longitudinal studies)';


--
-- Name: COLUMN datadic_variables.equivalent_to_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.equivalent_to_id IS 'Primary variable id this is equivalent to';


--
-- Name: COLUMN datadic_variables.storage_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.storage_type IS 'Type of storage for dataset';


--
-- Name: COLUMN datadic_variables.db_or_fs; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.db_or_fs IS 'Database or Filesystem name';


--
-- Name: COLUMN datadic_variables.schema_or_path; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.schema_or_path IS 'Database schema or Filesystem directory path';


--
-- Name: COLUMN datadic_variables.table_or_file; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.table_or_file IS 'Database table (or view, if derived or equivalent to another variable), or filename in directory';


--
-- Name: COLUMN datadic_variables.redcap_data_dictionary_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.redcap_data_dictionary_id IS 'Reference to REDCap data dictionary representation';


--
-- Name: COLUMN datadic_variables."position"; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables."position" IS 'Relative position (for source forms or other variables where order of collection matters)';


--
-- Name: COLUMN datadic_variables.section_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.section_id IS 'Section this belongs to';


--
-- Name: COLUMN datadic_variables.sub_section_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.sub_section_id IS 'Sub-section this belongs to';


--
-- Name: COLUMN datadic_variables.title; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.title IS 'Section caption';


--
-- Name: COLUMN datadic_variables.storage_varname; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.storage_varname IS 'Database field name, or variable name in data file';


--
-- Name: COLUMN datadic_variables.contributor_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.contributor_type IS 'Type of contributor this variable was provided by';


--
-- Name: COLUMN datadic_variables.n_for_timepoints; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.n_for_timepoints IS 'For each named timepoint (name:), the population or count of responses (n:), with notes (notes:)';


--
-- Name: COLUMN datadic_variables.notes; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variables.notes IS 'Notes';


--
-- Name: datadic_stats; Type: MATERIALIZED VIEW; Schema: ref_data; Owner: -
--

CREATE MATERIALIZED VIEW ref_data.datadic_stats AS
 WITH vars AS (
         SELECT var.id,
            var.study,
            var.source_name,
            var.source_type,
            var.domain,
            var.form_name,
            var.variable_name,
            var.variable_type,
            var.presentation_type,
            var.label,
            var.label_note,
            var.annotation,
            var.is_required,
            var.valid_type,
            var.valid_min,
            var.valid_max,
            var.multi_valid_choices,
            var.is_identifier,
            var.is_derived_var,
            var.multi_derived_from_id,
            var.doc_url,
            var.target_type,
            var.owner_email,
            var.classification,
            var.other_classification,
            var.multi_timepoints,
            var.equivalent_to_id,
            var.storage_type,
            var.db_or_fs,
            var.schema_or_path,
            var.table_or_file,
            var.disabled,
            var.admin_id,
            var.redcap_data_dictionary_id,
            var.created_at,
            var.updated_at,
            var."position",
            var.section_id,
            var.sub_section_id,
            var.title,
            var.storage_varname,
            var.user_id
           FROM ref_data.datadic_variables var
          WHERE ((NOT COALESCE(var.disabled, false)) AND ((var.variable_name)::text <> 'participant_id'::text) AND (NULLIF((var.storage_varname)::text, ''::text) IS NOT NULL))
        )
 SELECT var.id AS variable_id,
    stats.variable AS variable_name,
    var.label AS variable_label,
    stats.results,
    stats.labels,
    stats.mean,
    stats.stddev,
    stats.min,
    stats.med,
    stats.max,
    NULL::character varying AS choices,
    stats.distincts,
    stats.completed,
    stats.total_recs
   FROM (vars var
     JOIN LATERAL ref_data.calc_var_stats_for_numeric(var.id) stats(variable_id, variable, results, labels, min, med, max, mean, stddev, distincts, completed, total_recs, "chart:") ON ((stats.variable IS NOT NULL)))
  WHERE ((var.table_or_file IS NOT NULL) AND ((var.variable_type)::text = ANY (ARRAY[('numeric'::character varying)::text, ('calculated'::character varying)::text])))
UNION
 SELECT var.id AS variable_id,
    stats.variable AS variable_name,
    var.label AS variable_label,
    stats.results,
    stats.labels,
    NULL::numeric AS mean,
    NULL::numeric AS stddev,
    NULL::numeric AS min,
    NULL::numeric AS med,
    NULL::numeric AS max,
    (to_json(var.multi_valid_choices))::character varying AS choices,
    stats.distincts,
    stats.completed,
    stats.total_recs
   FROM (vars var
     JOIN LATERAL ref_data.calc_var_stats_for_categorical(var.id) stats(variable_id, variable, results, labels, cat_counts, distincts, completed, total_recs, "chart:") ON ((stats.variable IS NOT NULL)))
  WHERE ((var.table_or_file IS NOT NULL) AND ((var.variable_type)::text = 'categorical'::text))
UNION
 SELECT var.id AS variable_id,
    stats.variable AS variable_name,
    var.label AS variable_label,
    stats.results,
    stats.labels,
    NULL::numeric AS mean,
    NULL::numeric AS stddev,
    NULL::numeric AS min,
    NULL::numeric AS med,
    NULL::numeric AS max,
    NULL::character varying AS choices,
    stats.distincts,
    stats.completed,
    stats.total_recs
   FROM (vars var
     JOIN LATERAL ref_data.calc_var_stats_for_boolean(var.id) stats(variable_id, variable, results, labels, cat_counts, distincts, completed, total_recs, "chart:") ON ((stats.variable IS NOT NULL)))
  WHERE ((var.table_or_file IS NOT NULL) AND ((var.variable_type)::text = 'dichotomous'::text))
  WITH NO DATA;


--
-- Name: datadic_variable_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.datadic_variable_history (
    id bigint NOT NULL,
    datadic_variable_id bigint,
    study character varying,
    source_name character varying,
    source_type character varying,
    domain character varying,
    form_name character varying,
    variable_name character varying,
    variable_type character varying,
    presentation_type character varying,
    label character varying,
    label_note character varying,
    annotation character varying,
    is_required boolean,
    valid_type character varying,
    valid_min character varying,
    valid_max character varying,
    multi_valid_choices character varying[],
    is_identifier boolean,
    is_derived_var boolean,
    multi_derived_from_id bigint[],
    doc_url character varying,
    target_type character varying,
    owner_email character varying,
    classification character varying,
    other_classification character varying,
    multi_timepoints character varying[],
    equivalent_to_id bigint,
    storage_type character varying,
    db_or_fs character varying,
    schema_or_path character varying,
    table_or_file character varying,
    disabled boolean,
    admin_id bigint,
    redcap_data_dictionary_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    "position" integer,
    section_id integer,
    sub_section_id integer,
    title character varying,
    storage_varname character varying,
    user_id bigint,
    contributor_type character varying,
    n_for_timepoints jsonb,
    notes character varying
);


--
-- Name: COLUMN datadic_variable_history.study; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.study IS 'Study name';


--
-- Name: COLUMN datadic_variable_history.source_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.source_name IS 'Source of variable';


--
-- Name: COLUMN datadic_variable_history.source_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.source_type IS 'Source type';


--
-- Name: COLUMN datadic_variable_history.domain; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.domain IS 'Domain';


--
-- Name: COLUMN datadic_variable_history.form_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.form_name IS 'Form name (if the source was a type of form)';


--
-- Name: COLUMN datadic_variable_history.variable_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.variable_name IS 'Variable name';


--
-- Name: COLUMN datadic_variable_history.variable_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.variable_type IS 'Variable type';


--
-- Name: COLUMN datadic_variable_history.presentation_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.presentation_type IS 'Data type for presentation purposes';


--
-- Name: COLUMN datadic_variable_history.label; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.label IS 'Primary label or title (if source was a form, the label presented for the field)';


--
-- Name: COLUMN datadic_variable_history.label_note; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.label_note IS 'Description (if source was a form, a note presented for the field)';


--
-- Name: COLUMN datadic_variable_history.annotation; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.annotation IS 'Annotations (if source was a form, annotations not presented to the user)';


--
-- Name: COLUMN datadic_variable_history.is_required; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.is_required IS 'Was required in source';


--
-- Name: COLUMN datadic_variable_history.valid_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.valid_type IS 'Source data type';


--
-- Name: COLUMN datadic_variable_history.valid_min; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.valid_min IS 'Minimum value';


--
-- Name: COLUMN datadic_variable_history.valid_max; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.valid_max IS 'Maximum value';


--
-- Name: COLUMN datadic_variable_history.multi_valid_choices; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.multi_valid_choices IS 'List of valid choices for categorical variables';


--
-- Name: COLUMN datadic_variable_history.is_identifier; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.is_identifier IS 'Represents identifiable information';


--
-- Name: COLUMN datadic_variable_history.is_derived_var; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.is_derived_var IS 'Is a derived variable';


--
-- Name: COLUMN datadic_variable_history.multi_derived_from_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.multi_derived_from_id IS 'If a derived variable, ids of variables used to calculate it';


--
-- Name: COLUMN datadic_variable_history.doc_url; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.doc_url IS 'URL to additional documentation';


--
-- Name: COLUMN datadic_variable_history.target_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.target_type IS 'Type of participant this variable relates to';


--
-- Name: COLUMN datadic_variable_history.owner_email; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.owner_email IS 'Owner, especially for derived variables';


--
-- Name: COLUMN datadic_variable_history.classification; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.classification IS 'Category of sensitivity from a privacy perspective';


--
-- Name: COLUMN datadic_variable_history.other_classification; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.other_classification IS 'Additional information regarding classification';


--
-- Name: COLUMN datadic_variable_history.multi_timepoints; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.multi_timepoints IS 'Timepoints this data is collected (in longitudinal studies)';


--
-- Name: COLUMN datadic_variable_history.equivalent_to_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.equivalent_to_id IS 'Primary variable id this is equivalent to';


--
-- Name: COLUMN datadic_variable_history.storage_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.storage_type IS 'Type of storage for dataset';


--
-- Name: COLUMN datadic_variable_history.db_or_fs; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.db_or_fs IS 'Database or Filesystem name';


--
-- Name: COLUMN datadic_variable_history.schema_or_path; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.schema_or_path IS 'Database schema or Filesystem directory path';


--
-- Name: COLUMN datadic_variable_history.table_or_file; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.table_or_file IS 'Database table (or view, if derived or equivalent to another variable), or filename in directory';


--
-- Name: COLUMN datadic_variable_history.redcap_data_dictionary_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.redcap_data_dictionary_id IS 'Reference to REDCap data dictionary representation';


--
-- Name: COLUMN datadic_variable_history."position"; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history."position" IS 'Relative position (for source forms or other variables where order of collection matters)';


--
-- Name: COLUMN datadic_variable_history.section_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.section_id IS 'Section this belongs to';


--
-- Name: COLUMN datadic_variable_history.sub_section_id; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.sub_section_id IS 'Sub-section this belongs to';


--
-- Name: COLUMN datadic_variable_history.title; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.title IS 'Section caption';


--
-- Name: COLUMN datadic_variable_history.storage_varname; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.storage_varname IS 'Database field name, or variable name in data file';


--
-- Name: COLUMN datadic_variable_history.contributor_type; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.contributor_type IS 'Type of contributor this variable was provided by';


--
-- Name: COLUMN datadic_variable_history.n_for_timepoints; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.n_for_timepoints IS 'For each named timepoint (name:), the population or count of responses (n:), with notes (notes:)';


--
-- Name: COLUMN datadic_variable_history.notes; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.datadic_variable_history.notes IS 'Notes';


--
-- Name: datadic_variable_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.datadic_variable_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: datadic_variable_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.datadic_variable_history_id_seq OWNED BY ref_data.datadic_variable_history.id;


--
-- Name: datadic_variables_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.datadic_variables_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: datadic_variables_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.datadic_variables_id_seq OWNED BY ref_data.datadic_variables.id;


--
-- Name: mv_datadic_stats; Type: MATERIALIZED VIEW; Schema: ref_data; Owner: -
--

CREATE MATERIALIZED VIEW ref_data.mv_datadic_stats AS
 WITH vars AS (
         SELECT var.id,
            var.study,
            var.source_name,
            var.source_type,
            var.domain,
            var.form_name,
            var.variable_name,
            var.variable_type,
            var.presentation_type,
            var.label,
            var.label_note,
            var.annotation,
            var.is_required,
            var.valid_type,
            var.valid_min,
            var.valid_max,
            var.multi_valid_choices,
            var.is_identifier,
            var.is_derived_var,
            var.multi_derived_from_id,
            var.doc_url,
            var.target_type,
            var.owner_email,
            var.classification,
            var.other_classification,
            var.multi_timepoints,
            var.equivalent_to_id,
            var.storage_type,
            var.db_or_fs,
            var.schema_or_path,
            var.table_or_file,
            var.disabled,
            var.admin_id,
            var.redcap_data_dictionary_id,
            var.created_at,
            var.updated_at,
            var."position",
            var.section_id,
            var.sub_section_id,
            var.title,
            var.storage_varname,
            var.user_id
           FROM ref_data.datadic_variables var
          WHERE ((NOT COALESCE(var.disabled, false)) AND ((var.variable_name)::text <> 'participant_id'::text) AND (NULLIF((var.storage_varname)::text, ''::text) IS NOT NULL))
        )
 SELECT var.id AS variable_id,
    stats.variable AS variable_name,
    var.label AS variable_label,
    stats.results,
    stats.labels,
    stats.mean,
    stats.stddev,
    stats.min,
    stats.med,
    stats.max,
    NULL::character varying AS choices,
    stats.distincts,
    stats.completed,
    stats.total_recs
   FROM (vars var
     JOIN LATERAL ref_data.calc_var_stats_for_numeric(var.id) stats(variable_id, variable, results, labels, min, med, max, mean, stddev, distincts, completed, total_recs, "chart:") ON ((stats.variable IS NOT NULL)))
  WHERE ((var.table_or_file IS NOT NULL) AND ((var.variable_type)::text = ANY (ARRAY[('numeric'::character varying)::text, ('calculated'::character varying)::text])))
UNION
 SELECT var.id AS variable_id,
    stats.variable AS variable_name,
    var.label AS variable_label,
    stats.results,
    stats.labels,
    NULL::numeric AS mean,
    NULL::numeric AS stddev,
    NULL::numeric AS min,
    NULL::numeric AS med,
    NULL::numeric AS max,
    (to_json(var.multi_valid_choices))::character varying AS choices,
    stats.distincts,
    stats.completed,
    stats.total_recs
   FROM (vars var
     JOIN LATERAL ref_data.calc_var_stats_for_categorical(var.id) stats(variable_id, variable, results, labels, cat_counts, distincts, completed, total_recs, "chart:") ON ((stats.variable IS NOT NULL)))
  WHERE ((var.table_or_file IS NOT NULL) AND ((var.variable_type)::text = 'categorical'::text))
UNION
 SELECT var.id AS variable_id,
    stats.variable AS variable_name,
    var.label AS variable_label,
    stats.results,
    stats.labels,
    NULL::numeric AS mean,
    NULL::numeric AS stddev,
    NULL::numeric AS min,
    NULL::numeric AS med,
    NULL::numeric AS max,
    NULL::character varying AS choices,
    stats.distincts,
    stats.completed,
    stats.total_recs
   FROM (vars var
     JOIN LATERAL ref_data.calc_var_stats_for_boolean(var.id) stats(variable_id, variable, results, labels, cat_counts, distincts, completed, total_recs, "chart:") ON ((stats.variable IS NOT NULL)))
  WHERE ((var.table_or_file IS NOT NULL) AND ((var.variable_type)::text = 'dichotomous'::text))
  WITH NO DATA;


--
-- Name: redcap_client_requests; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_client_requests (
    id bigint NOT NULL,
    redcap_project_admin_id bigint,
    action character varying,
    name character varying,
    server_url character varying,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    result jsonb
);


--
-- Name: TABLE redcap_client_requests; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.redcap_client_requests IS 'Redcap client requests';


--
-- Name: redcap_client_requests_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_client_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_client_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_client_requests_id_seq OWNED BY ref_data.redcap_client_requests.id;


--
-- Name: redcap_data_collection_instrument_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_data_collection_instrument_history (
    id bigint NOT NULL,
    redcap_data_collection_instrument_id bigint,
    redcap_project_admin_id bigint,
    name character varying,
    label character varying,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: redcap_data_collection_instrument_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_data_collection_instrument_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_data_collection_instrument_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_data_collection_instrument_history_id_seq OWNED BY ref_data.redcap_data_collection_instrument_history.id;


--
-- Name: redcap_data_collection_instruments; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_data_collection_instruments (
    id bigint NOT NULL,
    name character varying,
    label character varying,
    disabled boolean,
    redcap_project_admin_id bigint,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: redcap_data_collection_instruments_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_data_collection_instruments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_data_collection_instruments_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_data_collection_instruments_id_seq OWNED BY ref_data.redcap_data_collection_instruments.id;


--
-- Name: redcap_data_dictionaries; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_data_dictionaries (
    id bigint NOT NULL,
    redcap_project_admin_id bigint,
    field_count integer,
    captured_metadata jsonb,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: TABLE redcap_data_dictionaries; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.redcap_data_dictionaries IS 'Retrieved Redcap Data Dictionaries (metadata)';


--
-- Name: redcap_data_dictionaries_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_data_dictionaries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_data_dictionaries_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_data_dictionaries_id_seq OWNED BY ref_data.redcap_data_dictionaries.id;


--
-- Name: redcap_data_dictionary_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_data_dictionary_history (
    id bigint NOT NULL,
    redcap_data_dictionary_id bigint,
    redcap_project_admin_id bigint,
    field_count integer,
    captured_metadata jsonb,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: TABLE redcap_data_dictionary_history; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.redcap_data_dictionary_history IS 'Retrieved Redcap Data Dictionaries (metadata) - history';


--
-- Name: redcap_data_dictionary_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_data_dictionary_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_data_dictionary_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_data_dictionary_history_id_seq OWNED BY ref_data.redcap_data_dictionary_history.id;


--
-- Name: redcap_project_admin_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_project_admin_history (
    id bigint NOT NULL,
    redcap_project_admin_id bigint,
    name character varying,
    api_key character varying,
    server_url character varying,
    captured_project_info jsonb,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    transfer_mode character varying,
    frequency character varying,
    status character varying,
    post_transfer_pipeline character varying[] DEFAULT '{}'::character varying[],
    notes character varying,
    study character varying,
    dynamic_model_table character varying
);


--
-- Name: TABLE redcap_project_admin_history; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.redcap_project_admin_history IS 'Redcap project administration - history';


--
-- Name: redcap_project_admin_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_project_admin_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_project_admin_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_project_admin_history_id_seq OWNED BY ref_data.redcap_project_admin_history.id;


--
-- Name: redcap_project_admins; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_project_admins (
    id bigint NOT NULL,
    name character varying,
    api_key character varying,
    server_url character varying,
    captured_project_info jsonb,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    transfer_mode character varying,
    frequency character varying,
    status character varying,
    post_transfer_pipeline character varying[] DEFAULT '{}'::character varying[],
    notes character varying,
    study character varying,
    dynamic_model_table character varying,
    options character varying
);


--
-- Name: TABLE redcap_project_admins; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.redcap_project_admins IS 'Redcap project administration';


--
-- Name: redcap_project_admins_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_project_admins_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_project_admins_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_project_admins_id_seq OWNED BY ref_data.redcap_project_admins.id;


--
-- Name: redcap_project_user_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_project_user_history (
    id bigint NOT NULL,
    redcap_project_user_id bigint,
    redcap_project_admin_id bigint,
    username character varying,
    email character varying,
    expiration character varying,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: redcap_project_user_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_project_user_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_project_user_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_project_user_history_id_seq OWNED BY ref_data.redcap_project_user_history.id;


--
-- Name: redcap_project_users; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_project_users (
    id bigint NOT NULL,
    redcap_project_admin_id bigint,
    username character varying,
    email character varying,
    expiration character varying,
    disabled boolean,
    admin_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: redcap_project_users_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_project_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_project_users_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_project_users_id_seq OWNED BY ref_data.redcap_project_users.id;


--
-- Name: redcap_user_status_rec_history; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_user_status_rec_history (
    id bigint NOT NULL,
    username character varying,
    first_name character varying,
    last_name character varying,
    email_address character varying,
    administrator character varying,
    users_sponsor character varying,
    institution_id character varying,
    comments character varying,
    first_activity timestamp without time zone,
    last_activity timestamp without time zone,
    last_login timestamp without time zone,
    time_of_suspension timestamp without time zone,
    expiration_date timestamp without time zone,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    redcap_user_status_rec_id bigint
);


--
-- Name: redcap_user_status_rec_history_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_user_status_rec_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_user_status_rec_history_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_user_status_rec_history_id_seq OWNED BY ref_data.redcap_user_status_rec_history.id;


--
-- Name: redcap_user_status_recs; Type: TABLE; Schema: ref_data; Owner: -
--

CREATE TABLE ref_data.redcap_user_status_recs (
    id bigint NOT NULL,
    username character varying,
    first_name character varying,
    last_name character varying,
    email_address character varying,
    administrator character varying,
    users_sponsor character varying,
    institution_id character varying,
    comments character varying,
    first_activity timestamp without time zone,
    last_activity timestamp without time zone,
    last_login timestamp without time zone,
    time_of_suspension timestamp without time zone,
    expiration_date timestamp without time zone,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: TABLE redcap_user_status_recs; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON TABLE ref_data.redcap_user_status_recs IS 'Dynamicmodel: Redcap User Status Rec';


--
-- Name: redcap_user_status_recs_id_seq; Type: SEQUENCE; Schema: ref_data; Owner: -
--

CREATE SEQUENCE ref_data.redcap_user_status_recs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redcap_user_status_recs_id_seq; Type: SEQUENCE OWNED BY; Schema: ref_data; Owner: -
--

ALTER SEQUENCE ref_data.redcap_user_status_recs_id_seq OWNED BY ref_data.redcap_user_status_recs.id;


--
-- Name: test_views; Type: VIEW; Schema: ref_data; Owner: -
--

CREATE VIEW ref_data.test_views AS
 SELECT player_infos.id,
    player_infos.master_id,
    player_infos.first_name,
    player_infos.last_name,
    player_infos.middle_name,
    player_infos.nick_name,
    player_infos.birth_date,
    player_infos.death_date,
    player_infos.user_id,
    player_infos.created_at,
    player_infos.updated_at,
    player_infos.contact_pref,
    player_infos.start_year,
    player_infos.rank,
    player_infos.notes,
    player_infos.contact_id,
    player_infos.college,
    player_infos.end_year,
    player_infos.source
   FROM ml_app.player_infos;


--
-- Name: VIEW test_views; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON VIEW ref_data.test_views IS 'Dynamicmodel: Test View';


--
-- Name: COLUMN test_views.first_name; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON COLUMN ref_data.test_views.first_name IS 'First Name';


--
-- Name: view_data_variable_domains; Type: VIEW; Schema: ref_data; Owner: -
--

CREATE VIEW ref_data.view_data_variable_domains AS
 SELECT DISTINCT dv.domain
   FROM ref_data.datadic_variables dv
  WHERE (NOT COALESCE(dv.disabled, false))
  ORDER BY dv.domain;


--
-- Name: VIEW view_data_variable_domains; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON VIEW ref_data.view_data_variable_domains IS 'Dynamicmodel: Data Variable Domains';


--
-- Name: view_datadic_studies; Type: VIEW; Schema: ref_data; Owner: -
--

CREATE VIEW ref_data.view_datadic_studies AS
 SELECT DISTINCT datadic_variables.study
   FROM ref_data.datadic_variables
  WHERE (NOT COALESCE(datadic_variables.disabled, false))
  ORDER BY datadic_variables.study;


--
-- Name: VIEW view_datadic_studies; Type: COMMENT; Schema: ref_data; Owner: -
--

COMMENT ON VIEW ref_data.view_datadic_studies IS 'Dynamicmodel: View Data Dictionary Studies';


--
-- Name: view_redcap_project_details; Type: MATERIALIZED VIEW; Schema: ref_data; Owner: -
--

CREATE MATERIALIZED VIEW ref_data.view_redcap_project_details AS
 SELECT DISTINCT rpa.study,
    rpa.name,
    (string_to_array((rpa.dynamic_model_table)::text, '.'::text))[1] AS schemaname,
    (string_to_array((rpa.dynamic_model_table)::text, '.'::text))[2] AS tablename,
    (jsonb_array_elements(rdd.captured_metadata) ->> 'form_name'::text) AS formname
   FROM (ref_data.redcap_data_dictionaries rdd
     JOIN ref_data.redcap_project_admins rpa ON (((rpa.id = rdd.redcap_project_admin_id) AND (NOT COALESCE(rpa.disabled, false)))))
  ORDER BY rpa.study, rpa.name
  WITH NO DATA;


--
-- Name: view_redcap_projects; Type: MATERIALIZED VIEW; Schema: ref_data; Owner: -
--

CREATE MATERIALIZED VIEW ref_data.view_redcap_projects AS
 SELECT DISTINCT view_redcap_project_details.schemaname,
    view_redcap_project_details.tablename,
    view_redcap_project_details.name
   FROM ref_data.view_redcap_project_details
  WITH NO DATA;


--
-- Name: view_redcap_ipa_completer_ids; Type: VIEW; Schema: ref_data; Owner: -
--

CREATE VIEW ref_data.view_redcap_ipa_completer_ids AS
 SELECT sc.participant_id,
    sc.colname,
    sc.tablename,
    replace((sc.colname)::text, '_complete'::text, ''::text) AS formname,
    rd.name
   FROM (ref_data.statsummary_completers('participant_id'::character varying) sc(participant_id, colname, tablename, colval)
     JOIN ref_data.view_redcap_projects rd ON ((rd.tablename = (sc.tablename)::text)))
  WHERE ((sc.colval = 2) AND ((rd.name)::text ~ '^ipa_'::text))
  ORDER BY sc.tablename, sc.colname;


--
-- Name: view_redcap_ipa_completers; Type: VIEW; Schema: ref_data; Owner: -
--

CREATE VIEW ref_data.view_redcap_ipa_completers AS
 SELECT count(*) AS count,
    sc.colname,
    sc.tablename,
    replace((sc.colname)::text, '_complete'::text, ''::text) AS formname,
    rd.name
   FROM (ref_data.statsummary_completers('participant_id'::character varying) sc(participant_id, colname, tablename, colval)
     JOIN ref_data.view_redcap_projects rd ON ((rd.tablename = (sc.tablename)::text)))
  WHERE ((sc.colval = 2) AND ((rd.name)::text ~ '^ipa_'::text))
  GROUP BY sc.colname, sc.tablename, rd.name
  ORDER BY sc.tablename, sc.colname;


--
-- Name: view_study_datadic; Type: VIEW; Schema: ref_data; Owner: -
--

CREATE VIEW ref_data.view_study_datadic AS
 SELECT DISTINCT a.id,
    a.domain,
        CASE
            WHEN ((a.source_type)::text = 'redcap'::text) THEN (((((a.source_type)::text || '
'::text) || (COALESCE(rpa.name, ''::character varying))::text) || '
'::text) || (a.form_name)::text)
            ELSE (((((a.source_type)::text || '
'::text) || (a.source_name)::text) || '
'::text) || (a.form_name)::text)
        END AS "Source",
        CASE
            WHEN ((COALESCE(a.title, ''::character varying))::text <> ''::text) THEN a.title
            WHEN ((COALESCE(sec.title, ''::character varying))::text <> ''::text) THEN sec.title
            ELSE sec.label
        END AS title,
    a.variable_name,
    a.label,
    a.label_note,
    a.variable_type,
    a.valid_min,
    a.valid_max,
    a.multi_valid_choices,
    a.target_type,
    a.is_derived_var,
    a.multi_derived_from_id,
    a.source_name,
    a.source_type,
    a.form_name,
    a.presentation_type,
    a.is_required,
    a.valid_type,
    a.annotation,
        CASE
            WHEN (a.doc_url IS NOT NULL) THEN (('[documentation]('::text || (a.doc_url)::text) || ')'::text)
            ELSE NULL::text
        END AS doc_url,
    a.is_identifier,
    a.owner_email,
    a.classification,
    a.other_classification,
    a.multi_timepoints,
    ((((((((eq.variable_name)::text || ' in '::text) || (eq.study)::text) || ' '::text) || (eq.source_type)::text) || ' ('::text) || (eq.source_name)::text) || ')'::text) AS equivalent_to_id,
    a.storage_type,
    a.db_or_fs,
    a.schema_or_path,
        CASE
            WHEN ((a.storage_type)::text = 'database'::text) THEN ((((((((('['::text || (a.table_or_file)::text) || '](/reports/reference_data__table_data'::text) || chr(63)) || 'search_attrs[_blank]=true&schema_name='::text) || (a.schema_or_path)::text) || '&table_name='::text) || (a.table_or_file)::text) || ')'::text))::character varying
            ELSE a.table_or_file
        END AS table_or_file,
    a.storage_varname,
    a.redcap_data_dictionary_id,
    a.study,
    a."position",
    a.section_id,
    a.created_at,
    a.updated_at,
    a.disabled,
    a.admin_id
   FROM ((((ref_data.datadic_variables a
     LEFT JOIN ref_data.datadic_variables eq ON ((a.equivalent_to_id = eq.id)))
     LEFT JOIN ref_data.datadic_variables sec ON ((a.section_id = sec.id)))
     LEFT JOIN ref_data.redcap_data_dictionaries rdd ON ((a.redcap_data_dictionary_id = rdd.id)))
     LEFT JOIN ref_data.redcap_project_admins rpa ON ((rdd.redcap_project_admin_id = rpa.id)))
  WHERE ((NOT COALESCE(a.disabled, false)) AND (NOT (((a.variable_name)::text ~* '___'::text) AND ((a.variable_type)::text = ANY (ARRAY[('categorical'::character varying)::text, ('dichotomous item'::character varying)::text])) AND ((a.source_type)::text = 'redcap'::text))))
  ORDER BY a."position", a.id;


--
-- Name: accuracy_score_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.accuracy_score_history ALTER COLUMN id SET DEFAULT nextval('ml_app.accuracy_score_history_id_seq'::regclass);


--
-- Name: accuracy_scores id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.accuracy_scores ALTER COLUMN id SET DEFAULT nextval('ml_app.accuracy_scores_id_seq'::regclass);


--
-- Name: activity_log_bhs_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_bhs_assignment_history_id_seq'::regclass);


--
-- Name: activity_log_bhs_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_bhs_assignments_id_seq'::regclass);


--
-- Name: activity_log_ext_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_ext_assignment_history_id_seq'::regclass);


--
-- Name: activity_log_ext_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_ext_assignments_id_seq'::regclass);


--
-- Name: activity_log_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_history ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_history_id_seq'::regclass);


--
-- Name: activity_log_new_test_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_test_history ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_new_test_history_id_seq'::regclass);


--
-- Name: activity_log_new_tests id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_tests ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_new_tests_id_seq'::regclass);


--
-- Name: activity_log_player_contact_phone_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phone_history ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_player_contact_phone_history_id_seq'::regclass);


--
-- Name: activity_log_player_contact_phones id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phones ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_player_contact_phones_id_seq'::regclass);


--
-- Name: activity_log_player_info_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_info_history ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_player_info_history_id_seq'::regclass);


--
-- Name: activity_log_player_infos id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_infos ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_log_player_infos_id_seq'::regclass);


--
-- Name: activity_logs id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_logs ALTER COLUMN id SET DEFAULT nextval('ml_app.activity_logs_id_seq'::regclass);


--
-- Name: address_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.address_history ALTER COLUMN id SET DEFAULT nextval('ml_app.address_history_id_seq'::regclass);


--
-- Name: addresses id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.addresses ALTER COLUMN id SET DEFAULT nextval('ml_app.addresses_id_seq'::regclass);


--
-- Name: admin_action_logs id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_action_logs ALTER COLUMN id SET DEFAULT nextval('ml_app.admin_action_logs_id_seq'::regclass);


--
-- Name: admin_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_history ALTER COLUMN id SET DEFAULT nextval('ml_app.admin_history_id_seq'::regclass);


--
-- Name: admins id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admins ALTER COLUMN id SET DEFAULT nextval('ml_app.admins_id_seq'::regclass);


--
-- Name: app_configuration_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configuration_history ALTER COLUMN id SET DEFAULT nextval('ml_app.app_configuration_history_id_seq'::regclass);


--
-- Name: app_configurations id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configurations ALTER COLUMN id SET DEFAULT nextval('ml_app.app_configurations_id_seq'::regclass);


--
-- Name: app_type_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_type_history ALTER COLUMN id SET DEFAULT nextval('ml_app.app_type_history_id_seq'::regclass);


--
-- Name: app_types id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_types ALTER COLUMN id SET DEFAULT nextval('ml_app.app_types_id_seq'::regclass);


--
-- Name: bhs_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.bhs_assignment_history_id_seq'::regclass);


--
-- Name: bhs_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.bhs_assignments_id_seq'::regclass);


--
-- Name: college_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.college_history ALTER COLUMN id SET DEFAULT nextval('ml_app.college_history_id_seq'::regclass);


--
-- Name: colleges id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.colleges ALTER COLUMN id SET DEFAULT nextval('ml_app.colleges_id_seq'::regclass);


--
-- Name: config_libraries id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_libraries ALTER COLUMN id SET DEFAULT nextval('ml_app.config_libraries_id_seq'::regclass);


--
-- Name: config_library_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_library_history ALTER COLUMN id SET DEFAULT nextval('ml_app.config_library_history_id_seq'::regclass);


--
-- Name: delayed_jobs id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.delayed_jobs ALTER COLUMN id SET DEFAULT nextval('ml_app.delayed_jobs_id_seq'::regclass);


--
-- Name: dynamic_model_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.dynamic_model_history ALTER COLUMN id SET DEFAULT nextval('ml_app.dynamic_model_history_id_seq'::regclass);


--
-- Name: dynamic_models id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.dynamic_models ALTER COLUMN id SET DEFAULT nextval('ml_app.dynamic_models_id_seq'::regclass);


--
-- Name: exception_logs id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.exception_logs ALTER COLUMN id SET DEFAULT nextval('ml_app.exception_logs_id_seq'::regclass);


--
-- Name: ext_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.ext_assignment_history_id_seq'::regclass);


--
-- Name: ext_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.ext_assignments_id_seq'::regclass);


--
-- Name: ext_gen_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.ext_gen_assignment_history_id_seq'::regclass);


--
-- Name: ext_gen_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.ext_gen_assignments_id_seq'::regclass);


--
-- Name: external_identifier_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifier_history ALTER COLUMN id SET DEFAULT nextval('ml_app.external_identifier_history_id_seq'::regclass);


--
-- Name: external_identifiers id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifiers ALTER COLUMN id SET DEFAULT nextval('ml_app.external_identifiers_id_seq'::regclass);


--
-- Name: external_link_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_link_history ALTER COLUMN id SET DEFAULT nextval('ml_app.external_link_history_id_seq'::regclass);


--
-- Name: external_links id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_links ALTER COLUMN id SET DEFAULT nextval('ml_app.external_links_id_seq'::regclass);


--
-- Name: general_selection_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.general_selection_history ALTER COLUMN id SET DEFAULT nextval('ml_app.general_selection_history_id_seq'::regclass);


--
-- Name: general_selections id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.general_selections ALTER COLUMN id SET DEFAULT nextval('ml_app.general_selections_id_seq'::regclass);


--
-- Name: grit_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.grit_assignment_history_id_seq'::regclass);


--
-- Name: grit_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.grit_assignments_id_seq'::regclass);


--
-- Name: imports id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.imports ALTER COLUMN id SET DEFAULT nextval('ml_app.imports_id_seq'::regclass);


--
-- Name: imports_model_generators id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.imports_model_generators ALTER COLUMN id SET DEFAULT nextval('ml_app.imports_model_generators_id_seq'::regclass);


--
-- Name: item_flag_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_history ALTER COLUMN id SET DEFAULT nextval('ml_app.item_flag_history_id_seq'::regclass);


--
-- Name: item_flag_name_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_name_history ALTER COLUMN id SET DEFAULT nextval('ml_app.item_flag_name_history_id_seq'::regclass);


--
-- Name: item_flag_names id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_names ALTER COLUMN id SET DEFAULT nextval('ml_app.item_flag_names_id_seq'::regclass);


--
-- Name: item_flags id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flags ALTER COLUMN id SET DEFAULT nextval('ml_app.item_flags_id_seq'::regclass);


--
-- Name: manage_users id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.manage_users ALTER COLUMN id SET DEFAULT nextval('ml_app.manage_users_id_seq'::regclass);


--
-- Name: marketo_ids id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.marketo_ids ALTER COLUMN id SET DEFAULT nextval('ml_app.marketo_ids_id_seq'::regclass);


--
-- Name: masters id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.masters ALTER COLUMN id SET DEFAULT nextval('ml_app.masters_id_seq'::regclass);


--
-- Name: message_notifications id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_notifications ALTER COLUMN id SET DEFAULT nextval('ml_app.message_notifications_id_seq'::regclass);


--
-- Name: message_template_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_template_history ALTER COLUMN id SET DEFAULT nextval('ml_app.message_template_history_id_seq'::regclass);


--
-- Name: message_templates id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_templates ALTER COLUMN id SET DEFAULT nextval('ml_app.message_templates_id_seq'::regclass);


--
-- Name: model_references id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.model_references ALTER COLUMN id SET DEFAULT nextval('ml_app.model_references_id_seq'::regclass);


--
-- Name: new_test_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_test_history ALTER COLUMN id SET DEFAULT nextval('ml_app.new_test_history_id_seq'::regclass);


--
-- Name: new_tests id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_tests ALTER COLUMN id SET DEFAULT nextval('ml_app.new_tests_id_seq'::regclass);


--
-- Name: nfs_store_archived_file_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_file_history ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_archived_file_history_id_seq'::regclass);


--
-- Name: nfs_store_archived_files id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_files ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_archived_files_id_seq'::regclass);


--
-- Name: nfs_store_container_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_container_history ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_container_history_id_seq'::regclass);


--
-- Name: nfs_store_containers id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_containers_id_seq'::regclass);


--
-- Name: nfs_store_downloads id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_downloads ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_downloads_id_seq'::regclass);


--
-- Name: nfs_store_filter_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filter_history ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_filter_history_id_seq'::regclass);


--
-- Name: nfs_store_filters id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filters ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_filters_id_seq'::regclass);


--
-- Name: nfs_store_imports id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_imports ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_imports_id_seq'::regclass);


--
-- Name: nfs_store_move_actions id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_move_actions ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_move_actions_id_seq'::regclass);


--
-- Name: nfs_store_stored_file_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_file_history ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_stored_file_history_id_seq'::regclass);


--
-- Name: nfs_store_stored_files id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_files ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_stored_files_id_seq'::regclass);


--
-- Name: nfs_store_trash_actions id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_trash_actions ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_trash_actions_id_seq'::regclass);


--
-- Name: nfs_store_uploads id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_uploads ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_uploads_id_seq'::regclass);


--
-- Name: nfs_store_user_file_actions id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_user_file_actions ALTER COLUMN id SET DEFAULT nextval('ml_app.nfs_store_user_file_actions_id_seq'::regclass);


--
-- Name: page_layout_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layout_history ALTER COLUMN id SET DEFAULT nextval('ml_app.page_layout_history_id_seq'::regclass);


--
-- Name: page_layouts id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layouts ALTER COLUMN id SET DEFAULT nextval('ml_app.page_layouts_id_seq'::regclass);


--
-- Name: player_contact_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contact_history ALTER COLUMN id SET DEFAULT nextval('ml_app.player_contact_history_id_seq'::regclass);


--
-- Name: player_contacts id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contacts ALTER COLUMN id SET DEFAULT nextval('ml_app.player_contacts_id_seq'::regclass);


--
-- Name: player_info_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_info_history ALTER COLUMN id SET DEFAULT nextval('ml_app.player_info_history_id_seq'::regclass);


--
-- Name: player_infos id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_infos ALTER COLUMN id SET DEFAULT nextval('ml_app.player_infos_id_seq'::regclass);


--
-- Name: pro_infos id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.pro_infos ALTER COLUMN id SET DEFAULT nextval('ml_app.pro_infos_id_seq'::regclass);


--
-- Name: protocol_event_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_event_history ALTER COLUMN id SET DEFAULT nextval('ml_app.protocol_event_history_id_seq'::regclass);


--
-- Name: protocol_events id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_events ALTER COLUMN id SET DEFAULT nextval('ml_app.protocol_events_id_seq'::regclass);


--
-- Name: protocol_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_history ALTER COLUMN id SET DEFAULT nextval('ml_app.protocol_history_id_seq'::regclass);


--
-- Name: protocols id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocols ALTER COLUMN id SET DEFAULT nextval('ml_app.protocols_id_seq'::regclass);


--
-- Name: rc_cis id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.rc_cis ALTER COLUMN id SET DEFAULT nextval('ml_app.rc_cis_id_seq'::regclass);


--
-- Name: rc_stage_cif_copy id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.rc_stage_cif_copy ALTER COLUMN id SET DEFAULT nextval('ml_app.rc_stage_cif_copy_id_seq'::regclass);


--
-- Name: report_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.report_history ALTER COLUMN id SET DEFAULT nextval('ml_app.report_history_id_seq'::regclass);


--
-- Name: reports id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.reports ALTER COLUMN id SET DEFAULT nextval('ml_app.reports_id_seq'::regclass);


--
-- Name: role_description_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_description_history ALTER COLUMN id SET DEFAULT nextval('ml_app.role_description_history_id_seq'::regclass);


--
-- Name: role_descriptions id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_descriptions ALTER COLUMN id SET DEFAULT nextval('ml_app.role_descriptions_id_seq'::regclass);


--
-- Name: sage_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.sage_assignments_id_seq'::regclass);


--
-- Name: sage_two_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_two_history ALTER COLUMN id SET DEFAULT nextval('ml_app.sage_two_history_id_seq'::regclass);


--
-- Name: sage_twos id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_twos ALTER COLUMN id SET DEFAULT nextval('ml_app.sage_twos_id_seq'::regclass);


--
-- Name: scantron_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_history ALTER COLUMN id SET DEFAULT nextval('ml_app.scantron_history_id_seq'::regclass);


--
-- Name: scantron_q2_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2_history ALTER COLUMN id SET DEFAULT nextval('ml_app.scantron_q2_history_id_seq'::regclass);


--
-- Name: scantron_q2s id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2s ALTER COLUMN id SET DEFAULT nextval('ml_app.scantron_q2s_id_seq'::regclass);


--
-- Name: scantron_series_two_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_series_two_history ALTER COLUMN id SET DEFAULT nextval('ml_app.scantron_series_two_history_id_seq'::regclass);


--
-- Name: scantron_series_twos id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_series_twos ALTER COLUMN id SET DEFAULT nextval('ml_app.scantron_series_twos_id_seq'::regclass);


--
-- Name: scantrons id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantrons ALTER COLUMN id SET DEFAULT nextval('ml_app.scantrons_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sessions ALTER COLUMN id SET DEFAULT nextval('ml_app.sessions_id_seq'::regclass);


--
-- Name: sleep_assignment_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignment_history ALTER COLUMN id SET DEFAULT nextval('ml_app.sleep_assignment_history_id_seq'::regclass);


--
-- Name: sleep_assignments id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignments ALTER COLUMN id SET DEFAULT nextval('ml_app.sleep_assignments_id_seq'::regclass);


--
-- Name: sub_process_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_process_history ALTER COLUMN id SET DEFAULT nextval('ml_app.sub_process_history_id_seq'::regclass);


--
-- Name: sub_processes id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_processes ALTER COLUMN id SET DEFAULT nextval('ml_app.sub_processes_id_seq'::regclass);


--
-- Name: sync_statuses id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sync_statuses ALTER COLUMN id SET DEFAULT nextval('ml_app.sync_statuses_id_seq'::regclass);


--
-- Name: test1_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1_history ALTER COLUMN id SET DEFAULT nextval('ml_app.test1_history_id_seq'::regclass);


--
-- Name: test1s id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1s ALTER COLUMN id SET DEFAULT nextval('ml_app.test1s_id_seq'::regclass);


--
-- Name: test2_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2_history ALTER COLUMN id SET DEFAULT nextval('ml_app.test2_history_id_seq'::regclass);


--
-- Name: test2s id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2s ALTER COLUMN id SET DEFAULT nextval('ml_app.test2s_id_seq'::regclass);


--
-- Name: test_2_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2_history ALTER COLUMN id SET DEFAULT nextval('ml_app.test_2_history_id_seq'::regclass);


--
-- Name: test_2s id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2s ALTER COLUMN id SET DEFAULT nextval('ml_app.test_2s_id_seq'::regclass);


--
-- Name: test_ext2_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2_history ALTER COLUMN id SET DEFAULT nextval('ml_app.test_ext2_history_id_seq'::regclass);


--
-- Name: test_ext2s id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2s ALTER COLUMN id SET DEFAULT nextval('ml_app.test_ext2s_id_seq'::regclass);


--
-- Name: test_ext_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext_history ALTER COLUMN id SET DEFAULT nextval('ml_app.test_ext_history_id_seq'::regclass);


--
-- Name: test_exts id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_exts ALTER COLUMN id SET DEFAULT nextval('ml_app.test_exts_id_seq'::regclass);


--
-- Name: test_item_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_item_history ALTER COLUMN id SET DEFAULT nextval('ml_app.test_item_history_id_seq'::regclass);


--
-- Name: test_items id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_items ALTER COLUMN id SET DEFAULT nextval('ml_app.test_items_id_seq'::regclass);


--
-- Name: tracker_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history ALTER COLUMN id SET DEFAULT nextval('ml_app.tracker_history_id_seq'::regclass);


--
-- Name: trackers id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers ALTER COLUMN id SET DEFAULT nextval('ml_app.trackers_id_seq'::regclass);


--
-- Name: user_access_control_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_control_history ALTER COLUMN id SET DEFAULT nextval('ml_app.user_access_control_history_id_seq'::regclass);


--
-- Name: user_access_controls id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_controls ALTER COLUMN id SET DEFAULT nextval('ml_app.user_access_controls_id_seq'::regclass);


--
-- Name: user_action_logs id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_action_logs ALTER COLUMN id SET DEFAULT nextval('ml_app.user_action_logs_id_seq'::regclass);


--
-- Name: user_authorization_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_authorization_history ALTER COLUMN id SET DEFAULT nextval('ml_app.user_authorization_history_id_seq'::regclass);


--
-- Name: user_authorizations id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_authorizations ALTER COLUMN id SET DEFAULT nextval('ml_app.user_authorizations_id_seq'::regclass);


--
-- Name: user_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_history ALTER COLUMN id SET DEFAULT nextval('ml_app.user_history_id_seq'::regclass);


--
-- Name: user_preferences id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_preferences ALTER COLUMN id SET DEFAULT nextval('ml_app.user_preferences_id_seq'::regclass);


--
-- Name: user_role_history id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_role_history ALTER COLUMN id SET DEFAULT nextval('ml_app.user_role_history_id_seq'::regclass);


--
-- Name: user_roles id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_roles ALTER COLUMN id SET DEFAULT nextval('ml_app.user_roles_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users ALTER COLUMN id SET DEFAULT nextval('ml_app.users_id_seq'::regclass);


--
-- Name: users_contact_infos id; Type: DEFAULT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users_contact_infos ALTER COLUMN id SET DEFAULT nextval('ml_app.users_contact_infos_id_seq'::regclass);


--
-- Name: data_variable_package_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_history ALTER COLUMN id SET DEFAULT nextval('ref_data.data_variable_package_history_id_seq'::regclass);


--
-- Name: data_variable_package_var_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_var_history ALTER COLUMN id SET DEFAULT nextval('ref_data.data_variable_package_var_history_id_seq'::regclass);


--
-- Name: data_variable_package_vars id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_vars ALTER COLUMN id SET DEFAULT nextval('ref_data.data_variable_package_vars_id_seq'::regclass);


--
-- Name: data_variable_packages id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_packages ALTER COLUMN id SET DEFAULT nextval('ref_data.data_variable_packages_id_seq'::regclass);


--
-- Name: datadic_choice_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choice_history ALTER COLUMN id SET DEFAULT nextval('ref_data.datadic_choice_history_id_seq'::regclass);


--
-- Name: datadic_choices id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choices ALTER COLUMN id SET DEFAULT nextval('ref_data.datadic_choices_id_seq'::regclass);


--
-- Name: datadic_variable_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variable_history ALTER COLUMN id SET DEFAULT nextval('ref_data.datadic_variable_history_id_seq'::regclass);


--
-- Name: datadic_variables id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variables ALTER COLUMN id SET DEFAULT nextval('ref_data.datadic_variables_id_seq'::regclass);


--
-- Name: redcap_client_requests id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_client_requests ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_client_requests_id_seq'::regclass);


--
-- Name: redcap_data_collection_instrument_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instrument_history ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_data_collection_instrument_history_id_seq'::regclass);


--
-- Name: redcap_data_collection_instruments id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instruments ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_data_collection_instruments_id_seq'::regclass);


--
-- Name: redcap_data_dictionaries id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionaries ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_data_dictionaries_id_seq'::regclass);


--
-- Name: redcap_data_dictionary_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionary_history ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_data_dictionary_history_id_seq'::regclass);


--
-- Name: redcap_project_admin_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_admin_history ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_project_admin_history_id_seq'::regclass);


--
-- Name: redcap_project_admins id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_admins ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_project_admins_id_seq'::regclass);


--
-- Name: redcap_project_user_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_user_history ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_project_user_history_id_seq'::regclass);


--
-- Name: redcap_project_users id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_users ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_project_users_id_seq'::regclass);


--
-- Name: redcap_user_status_rec_history id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_user_status_rec_history ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_user_status_rec_history_id_seq'::regclass);


--
-- Name: redcap_user_status_recs id; Type: DEFAULT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_user_status_recs ALTER COLUMN id SET DEFAULT nextval('ref_data.redcap_user_status_recs_id_seq'::regclass);


--
-- Name: accuracy_score_history accuracy_score_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.accuracy_score_history
    ADD CONSTRAINT accuracy_score_history_pkey PRIMARY KEY (id);


--
-- Name: accuracy_scores accuracy_scores_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.accuracy_scores
    ADD CONSTRAINT accuracy_scores_pkey PRIMARY KEY (id);


--
-- Name: activity_log_bhs_assignment_history activity_log_bhs_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignment_history
    ADD CONSTRAINT activity_log_bhs_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: activity_log_bhs_assignments activity_log_bhs_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignments
    ADD CONSTRAINT activity_log_bhs_assignments_pkey PRIMARY KEY (id);


--
-- Name: activity_log_ext_assignment_history activity_log_ext_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignment_history
    ADD CONSTRAINT activity_log_ext_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: activity_log_ext_assignments activity_log_ext_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignments
    ADD CONSTRAINT activity_log_ext_assignments_pkey PRIMARY KEY (id);


--
-- Name: activity_log_history activity_log_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_history
    ADD CONSTRAINT activity_log_history_pkey PRIMARY KEY (id);


--
-- Name: activity_log_new_test_history activity_log_new_test_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_test_history
    ADD CONSTRAINT activity_log_new_test_history_pkey PRIMARY KEY (id);


--
-- Name: activity_log_new_tests activity_log_new_tests_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_tests
    ADD CONSTRAINT activity_log_new_tests_pkey PRIMARY KEY (id);


--
-- Name: activity_log_player_contact_phone_history activity_log_player_contact_phone_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phone_history
    ADD CONSTRAINT activity_log_player_contact_phone_history_pkey PRIMARY KEY (id);


--
-- Name: activity_log_player_contact_phones activity_log_player_contact_phones_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phones
    ADD CONSTRAINT activity_log_player_contact_phones_pkey PRIMARY KEY (id);


--
-- Name: activity_log_player_info_history activity_log_player_info_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_info_history
    ADD CONSTRAINT activity_log_player_info_history_pkey PRIMARY KEY (id);


--
-- Name: activity_log_player_infos activity_log_player_infos_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_infos
    ADD CONSTRAINT activity_log_player_infos_pkey PRIMARY KEY (id);


--
-- Name: activity_logs activity_logs_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_logs
    ADD CONSTRAINT activity_logs_pkey PRIMARY KEY (id);


--
-- Name: address_history address_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.address_history
    ADD CONSTRAINT address_history_pkey PRIMARY KEY (id);


--
-- Name: addresses addresses_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.addresses
    ADD CONSTRAINT addresses_pkey PRIMARY KEY (id);


--
-- Name: admin_action_logs admin_action_logs_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_action_logs
    ADD CONSTRAINT admin_action_logs_pkey PRIMARY KEY (id);


--
-- Name: admin_history admin_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_history
    ADD CONSTRAINT admin_history_pkey PRIMARY KEY (id);


--
-- Name: admins admins_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admins
    ADD CONSTRAINT admins_pkey PRIMARY KEY (id);


--
-- Name: app_configuration_history app_configuration_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configuration_history
    ADD CONSTRAINT app_configuration_history_pkey PRIMARY KEY (id);


--
-- Name: app_configurations app_configurations_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configurations
    ADD CONSTRAINT app_configurations_pkey PRIMARY KEY (id);


--
-- Name: app_type_history app_type_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_type_history
    ADD CONSTRAINT app_type_history_pkey PRIMARY KEY (id);


--
-- Name: app_types app_types_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_types
    ADD CONSTRAINT app_types_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: bhs_assignment_history bhs_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignment_history
    ADD CONSTRAINT bhs_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: bhs_assignments bhs_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignments
    ADD CONSTRAINT bhs_assignments_pkey PRIMARY KEY (id);


--
-- Name: college_history college_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.college_history
    ADD CONSTRAINT college_history_pkey PRIMARY KEY (id);


--
-- Name: colleges colleges_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.colleges
    ADD CONSTRAINT colleges_pkey PRIMARY KEY (id);


--
-- Name: config_libraries config_libraries_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_libraries
    ADD CONSTRAINT config_libraries_pkey PRIMARY KEY (id);


--
-- Name: config_library_history config_library_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_library_history
    ADD CONSTRAINT config_library_history_pkey PRIMARY KEY (id);


--
-- Name: delayed_jobs delayed_jobs_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.delayed_jobs
    ADD CONSTRAINT delayed_jobs_pkey PRIMARY KEY (id);


--
-- Name: dynamic_model_history dynamic_model_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.dynamic_model_history
    ADD CONSTRAINT dynamic_model_history_pkey PRIMARY KEY (id);


--
-- Name: dynamic_models dynamic_models_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.dynamic_models
    ADD CONSTRAINT dynamic_models_pkey PRIMARY KEY (id);


--
-- Name: exception_logs exception_logs_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.exception_logs
    ADD CONSTRAINT exception_logs_pkey PRIMARY KEY (id);


--
-- Name: ext_assignment_history ext_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignment_history
    ADD CONSTRAINT ext_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: ext_assignments ext_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignments
    ADD CONSTRAINT ext_assignments_pkey PRIMARY KEY (id);


--
-- Name: ext_gen_assignment_history ext_gen_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignment_history
    ADD CONSTRAINT ext_gen_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: ext_gen_assignments ext_gen_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignments
    ADD CONSTRAINT ext_gen_assignments_pkey PRIMARY KEY (id);


--
-- Name: external_identifier_history external_identifier_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifier_history
    ADD CONSTRAINT external_identifier_history_pkey PRIMARY KEY (id);


--
-- Name: external_identifiers external_identifiers_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifiers
    ADD CONSTRAINT external_identifiers_pkey PRIMARY KEY (id);


--
-- Name: external_link_history external_link_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_link_history
    ADD CONSTRAINT external_link_history_pkey PRIMARY KEY (id);


--
-- Name: external_links external_links_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_links
    ADD CONSTRAINT external_links_pkey PRIMARY KEY (id);


--
-- Name: general_selection_history general_selection_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.general_selection_history
    ADD CONSTRAINT general_selection_history_pkey PRIMARY KEY (id);


--
-- Name: general_selections general_selections_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.general_selections
    ADD CONSTRAINT general_selections_pkey PRIMARY KEY (id);


--
-- Name: grit_assignment_history grit_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignment_history
    ADD CONSTRAINT grit_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: grit_assignments grit_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignments
    ADD CONSTRAINT grit_assignments_pkey PRIMARY KEY (id);


--
-- Name: imports_model_generators imports_model_generators_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.imports_model_generators
    ADD CONSTRAINT imports_model_generators_pkey PRIMARY KEY (id);


--
-- Name: imports imports_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.imports
    ADD CONSTRAINT imports_pkey PRIMARY KEY (id);


--
-- Name: item_flag_history item_flag_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_history
    ADD CONSTRAINT item_flag_history_pkey PRIMARY KEY (id);


--
-- Name: item_flag_name_history item_flag_name_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_name_history
    ADD CONSTRAINT item_flag_name_history_pkey PRIMARY KEY (id);


--
-- Name: item_flag_names item_flag_names_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_names
    ADD CONSTRAINT item_flag_names_pkey PRIMARY KEY (id);


--
-- Name: item_flags item_flags_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flags
    ADD CONSTRAINT item_flags_pkey PRIMARY KEY (id);


--
-- Name: manage_users manage_users_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.manage_users
    ADD CONSTRAINT manage_users_pkey PRIMARY KEY (id);


--
-- Name: masters masters_msid; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.masters
    ADD CONSTRAINT masters_msid UNIQUE (msid);


--
-- Name: masters masters_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.masters
    ADD CONSTRAINT masters_pkey PRIMARY KEY (id);


--
-- Name: message_notifications message_notifications_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_notifications
    ADD CONSTRAINT message_notifications_pkey PRIMARY KEY (id);


--
-- Name: message_template_history message_template_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_template_history
    ADD CONSTRAINT message_template_history_pkey PRIMARY KEY (id);


--
-- Name: message_templates message_templates_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_templates
    ADD CONSTRAINT message_templates_pkey PRIMARY KEY (id);


--
-- Name: model_references model_references_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.model_references
    ADD CONSTRAINT model_references_pkey PRIMARY KEY (id);


--
-- Name: new_test_history new_test_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_test_history
    ADD CONSTRAINT new_test_history_pkey PRIMARY KEY (id);


--
-- Name: new_tests new_tests_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_tests
    ADD CONSTRAINT new_tests_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_archived_file_history nfs_store_archived_file_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_file_history
    ADD CONSTRAINT nfs_store_archived_file_history_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_archived_files nfs_store_archived_files_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_files
    ADD CONSTRAINT nfs_store_archived_files_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_container_history nfs_store_container_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_container_history
    ADD CONSTRAINT nfs_store_container_history_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_containers nfs_store_containers_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers
    ADD CONSTRAINT nfs_store_containers_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_downloads nfs_store_downloads_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_downloads
    ADD CONSTRAINT nfs_store_downloads_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_filter_history nfs_store_filter_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filter_history
    ADD CONSTRAINT nfs_store_filter_history_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_filters nfs_store_filters_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filters
    ADD CONSTRAINT nfs_store_filters_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_imports nfs_store_imports_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_imports
    ADD CONSTRAINT nfs_store_imports_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_move_actions nfs_store_move_actions_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_move_actions
    ADD CONSTRAINT nfs_store_move_actions_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_stored_file_history nfs_store_stored_file_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_file_history
    ADD CONSTRAINT nfs_store_stored_file_history_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_stored_files nfs_store_stored_files_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_files
    ADD CONSTRAINT nfs_store_stored_files_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_trash_actions nfs_store_trash_actions_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_trash_actions
    ADD CONSTRAINT nfs_store_trash_actions_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_uploads nfs_store_uploads_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_uploads
    ADD CONSTRAINT nfs_store_uploads_pkey PRIMARY KEY (id);


--
-- Name: nfs_store_user_file_actions nfs_store_user_file_actions_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_user_file_actions
    ADD CONSTRAINT nfs_store_user_file_actions_pkey PRIMARY KEY (id);


--
-- Name: page_layout_history page_layout_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layout_history
    ADD CONSTRAINT page_layout_history_pkey PRIMARY KEY (id);


--
-- Name: page_layouts page_layouts_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layouts
    ADD CONSTRAINT page_layouts_pkey PRIMARY KEY (id);


--
-- Name: player_contact_history player_contact_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contact_history
    ADD CONSTRAINT player_contact_history_pkey PRIMARY KEY (id);


--
-- Name: player_contacts player_contacts_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contacts
    ADD CONSTRAINT player_contacts_pkey PRIMARY KEY (id);


--
-- Name: player_info_history player_info_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_info_history
    ADD CONSTRAINT player_info_history_pkey PRIMARY KEY (id);


--
-- Name: player_infos player_infos_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_infos
    ADD CONSTRAINT player_infos_pkey PRIMARY KEY (id);


--
-- Name: pro_infos pro_infos_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.pro_infos
    ADD CONSTRAINT pro_infos_pkey PRIMARY KEY (id);


--
-- Name: protocol_event_history protocol_event_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_event_history
    ADD CONSTRAINT protocol_event_history_pkey PRIMARY KEY (id);


--
-- Name: protocol_events protocol_events_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_events
    ADD CONSTRAINT protocol_events_pkey PRIMARY KEY (id);


--
-- Name: protocol_history protocol_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_history
    ADD CONSTRAINT protocol_history_pkey PRIMARY KEY (id);


--
-- Name: protocols protocols_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocols
    ADD CONSTRAINT protocols_pkey PRIMARY KEY (id);


--
-- Name: rc_cis rc_cis_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.rc_cis
    ADD CONSTRAINT rc_cis_pkey PRIMARY KEY (id);


--
-- Name: rc_stage_cif_copy rc_stage_cif_copy_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.rc_stage_cif_copy
    ADD CONSTRAINT rc_stage_cif_copy_pkey PRIMARY KEY (id);


--
-- Name: report_history report_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.report_history
    ADD CONSTRAINT report_history_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: role_description_history role_description_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_description_history
    ADD CONSTRAINT role_description_history_pkey PRIMARY KEY (id);


--
-- Name: role_descriptions role_descriptions_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_descriptions
    ADD CONSTRAINT role_descriptions_pkey PRIMARY KEY (id);


--
-- Name: sage_assignments sage_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_assignments
    ADD CONSTRAINT sage_assignments_pkey PRIMARY KEY (id);


--
-- Name: sage_two_history sage_two_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_two_history
    ADD CONSTRAINT sage_two_history_pkey PRIMARY KEY (id);


--
-- Name: sage_twos sage_twos_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_twos
    ADD CONSTRAINT sage_twos_pkey PRIMARY KEY (id);


--
-- Name: scantron_history scantron_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_history
    ADD CONSTRAINT scantron_history_pkey PRIMARY KEY (id);


--
-- Name: scantron_q2_history scantron_q2_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2_history
    ADD CONSTRAINT scantron_q2_history_pkey PRIMARY KEY (id);


--
-- Name: scantron_q2s scantron_q2s_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2s
    ADD CONSTRAINT scantron_q2s_pkey PRIMARY KEY (id);


--
-- Name: scantron_series_two_history scantron_series_two_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_series_two_history
    ADD CONSTRAINT scantron_series_two_history_pkey PRIMARY KEY (id);


--
-- Name: scantron_series_twos scantron_series_twos_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_series_twos
    ADD CONSTRAINT scantron_series_twos_pkey PRIMARY KEY (id);


--
-- Name: scantrons scantrons_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantrons
    ADD CONSTRAINT scantrons_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sleep_assignment_history sleep_assignment_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignment_history
    ADD CONSTRAINT sleep_assignment_history_pkey PRIMARY KEY (id);


--
-- Name: sleep_assignments sleep_assignments_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignments
    ADD CONSTRAINT sleep_assignments_pkey PRIMARY KEY (id);


--
-- Name: sub_process_history sub_process_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_process_history
    ADD CONSTRAINT sub_process_history_pkey PRIMARY KEY (id);


--
-- Name: sub_processes sub_processes_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_processes
    ADD CONSTRAINT sub_processes_pkey PRIMARY KEY (id);


--
-- Name: test1_history test1_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1_history
    ADD CONSTRAINT test1_history_pkey PRIMARY KEY (id);


--
-- Name: test1s test1s_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1s
    ADD CONSTRAINT test1s_pkey PRIMARY KEY (id);


--
-- Name: test2_history test2_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2_history
    ADD CONSTRAINT test2_history_pkey PRIMARY KEY (id);


--
-- Name: test2s test2s_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2s
    ADD CONSTRAINT test2s_pkey PRIMARY KEY (id);


--
-- Name: test_2_history test_2_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2_history
    ADD CONSTRAINT test_2_history_pkey PRIMARY KEY (id);


--
-- Name: test_2s test_2s_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2s
    ADD CONSTRAINT test_2s_pkey PRIMARY KEY (id);


--
-- Name: test_ext2_history test_ext2_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2_history
    ADD CONSTRAINT test_ext2_history_pkey PRIMARY KEY (id);


--
-- Name: test_ext2s test_ext2s_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2s
    ADD CONSTRAINT test_ext2s_pkey PRIMARY KEY (id);


--
-- Name: test_ext_history test_ext_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext_history
    ADD CONSTRAINT test_ext_history_pkey PRIMARY KEY (id);


--
-- Name: test_exts test_exts_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_exts
    ADD CONSTRAINT test_exts_pkey PRIMARY KEY (id);


--
-- Name: test_item_history test_item_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_item_history
    ADD CONSTRAINT test_item_history_pkey PRIMARY KEY (id);


--
-- Name: test_items test_items_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_items
    ADD CONSTRAINT test_items_pkey PRIMARY KEY (id);


--
-- Name: tracker_history tracker_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT tracker_history_pkey PRIMARY KEY (id);


--
-- Name: trackers trackers_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT trackers_pkey PRIMARY KEY (id);


--
-- Name: user_access_control_history user_access_control_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_control_history
    ADD CONSTRAINT user_access_control_history_pkey PRIMARY KEY (id);


--
-- Name: user_access_controls user_access_controls_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_controls
    ADD CONSTRAINT user_access_controls_pkey PRIMARY KEY (id);


--
-- Name: user_action_logs user_action_logs_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_action_logs
    ADD CONSTRAINT user_action_logs_pkey PRIMARY KEY (id);


--
-- Name: user_authorization_history user_authorization_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_authorization_history
    ADD CONSTRAINT user_authorization_history_pkey PRIMARY KEY (id);


--
-- Name: user_authorizations user_authorizations_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_authorizations
    ADD CONSTRAINT user_authorizations_pkey PRIMARY KEY (id);


--
-- Name: user_history user_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_history
    ADD CONSTRAINT user_history_pkey PRIMARY KEY (id);


--
-- Name: user_preferences user_preferences_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_preferences
    ADD CONSTRAINT user_preferences_pkey PRIMARY KEY (id);


--
-- Name: user_role_history user_role_history_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_role_history
    ADD CONSTRAINT user_role_history_pkey PRIMARY KEY (id);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);


--
-- Name: users_contact_infos users_contact_infos_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users_contact_infos
    ADD CONSTRAINT users_contact_infos_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: data_variable_package_history data_variable_package_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_history
    ADD CONSTRAINT data_variable_package_history_pkey PRIMARY KEY (id);


--
-- Name: data_variable_package_var_history data_variable_package_var_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_var_history
    ADD CONSTRAINT data_variable_package_var_history_pkey PRIMARY KEY (id);


--
-- Name: data_variable_package_vars data_variable_package_vars_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_vars
    ADD CONSTRAINT data_variable_package_vars_pkey PRIMARY KEY (id);


--
-- Name: data_variable_packages data_variable_packages_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_packages
    ADD CONSTRAINT data_variable_packages_pkey PRIMARY KEY (id);


--
-- Name: datadic_choice_history datadic_choice_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choice_history
    ADD CONSTRAINT datadic_choice_history_pkey PRIMARY KEY (id);


--
-- Name: datadic_choices datadic_choices_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choices
    ADD CONSTRAINT datadic_choices_pkey PRIMARY KEY (id);


--
-- Name: datadic_variable_history datadic_variable_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variable_history
    ADD CONSTRAINT datadic_variable_history_pkey PRIMARY KEY (id);


--
-- Name: datadic_variables datadic_variables_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variables
    ADD CONSTRAINT datadic_variables_pkey PRIMARY KEY (id);


--
-- Name: redcap_client_requests redcap_client_requests_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_client_requests
    ADD CONSTRAINT redcap_client_requests_pkey PRIMARY KEY (id);


--
-- Name: redcap_data_collection_instrument_history redcap_data_collection_instrument_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instrument_history
    ADD CONSTRAINT redcap_data_collection_instrument_history_pkey PRIMARY KEY (id);


--
-- Name: redcap_data_collection_instruments redcap_data_collection_instruments_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instruments
    ADD CONSTRAINT redcap_data_collection_instruments_pkey PRIMARY KEY (id);


--
-- Name: redcap_data_dictionaries redcap_data_dictionaries_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionaries
    ADD CONSTRAINT redcap_data_dictionaries_pkey PRIMARY KEY (id);


--
-- Name: redcap_data_dictionary_history redcap_data_dictionary_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionary_history
    ADD CONSTRAINT redcap_data_dictionary_history_pkey PRIMARY KEY (id);


--
-- Name: redcap_project_admin_history redcap_project_admin_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_admin_history
    ADD CONSTRAINT redcap_project_admin_history_pkey PRIMARY KEY (id);


--
-- Name: redcap_project_admins redcap_project_admins_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_admins
    ADD CONSTRAINT redcap_project_admins_pkey PRIMARY KEY (id);


--
-- Name: redcap_project_user_history redcap_project_user_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_user_history
    ADD CONSTRAINT redcap_project_user_history_pkey PRIMARY KEY (id);


--
-- Name: redcap_project_users redcap_project_users_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_users
    ADD CONSTRAINT redcap_project_users_pkey PRIMARY KEY (id);


--
-- Name: redcap_user_status_rec_history redcap_user_status_rec_history_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_user_status_rec_history
    ADD CONSTRAINT redcap_user_status_rec_history_pkey PRIMARY KEY (id);


--
-- Name: redcap_user_status_recs redcap_user_status_recs_pkey; Type: CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_user_status_recs
    ADD CONSTRAINT redcap_user_status_recs_pkey PRIMARY KEY (id);


--
-- Name: delayed_jobs_priority; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX delayed_jobs_priority ON ml_app.delayed_jobs USING btree (priority, run_at);


--
-- Name: idx_h_on_role_descriptions_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX idx_h_on_role_descriptions_id ON ml_app.role_description_history USING btree (role_description_id);


--
-- Name: index_accuracy_score_history_on_accuracy_score_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_accuracy_score_history_on_accuracy_score_id ON ml_app.accuracy_score_history USING btree (accuracy_score_id);


--
-- Name: index_accuracy_scores_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_accuracy_scores_on_admin_id ON ml_app.accuracy_scores USING btree (admin_id);


--
-- Name: index_activity_log_bhs_assignment_history_on_activity_log_bhs_a; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_bhs_assignment_history_on_activity_log_bhs_a ON ml_app.activity_log_bhs_assignment_history USING btree (activity_log_bhs_assignment_id);


--
-- Name: index_activity_log_bhs_assignment_history_on_bhs_assignment_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_bhs_assignment_history_on_bhs_assignment_id ON ml_app.activity_log_bhs_assignment_history USING btree (bhs_assignment_id);


--
-- Name: index_activity_log_bhs_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_bhs_assignment_history_on_master_id ON ml_app.activity_log_bhs_assignment_history USING btree (master_id);


--
-- Name: index_activity_log_bhs_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_bhs_assignment_history_on_user_id ON ml_app.activity_log_bhs_assignment_history USING btree (user_id);


--
-- Name: index_activity_log_bhs_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_bhs_assignments_on_master_id ON ml_app.activity_log_bhs_assignments USING btree (master_id);


--
-- Name: index_activity_log_bhs_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_bhs_assignments_on_user_id ON ml_app.activity_log_bhs_assignments USING btree (user_id);


--
-- Name: index_activity_log_ext_assignment_history_on_activity_log_ext_a; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignment_history_on_activity_log_ext_a ON ml_app.activity_log_ext_assignment_history USING btree (activity_log_ext_assignment_id);


--
-- Name: index_activity_log_ext_assignment_history_on_ext_assignment_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignment_history_on_ext_assignment_id ON ml_app.activity_log_ext_assignment_history USING btree (ext_assignment_id);


--
-- Name: index_activity_log_ext_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignment_history_on_master_id ON ml_app.activity_log_ext_assignment_history USING btree (master_id);


--
-- Name: index_activity_log_ext_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignment_history_on_user_id ON ml_app.activity_log_ext_assignment_history USING btree (user_id);


--
-- Name: index_activity_log_ext_assignments_on_ext_assignment_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignments_on_ext_assignment_id ON ml_app.activity_log_ext_assignments USING btree (ext_assignment_id);


--
-- Name: index_activity_log_ext_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignments_on_master_id ON ml_app.activity_log_ext_assignments USING btree (master_id);


--
-- Name: index_activity_log_ext_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_ext_assignments_on_user_id ON ml_app.activity_log_ext_assignments USING btree (user_id);


--
-- Name: index_activity_log_history_on_activity_log_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_history_on_activity_log_id ON ml_app.activity_log_history USING btree (activity_log_id);


--
-- Name: index_activity_log_new_test_history_on_activity_log_new_test_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_test_history_on_activity_log_new_test_id ON ml_app.activity_log_new_test_history USING btree (activity_log_new_test_id);


--
-- Name: index_activity_log_new_test_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_test_history_on_master_id ON ml_app.activity_log_new_test_history USING btree (master_id);


--
-- Name: index_activity_log_new_test_history_on_new_test_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_test_history_on_new_test_id ON ml_app.activity_log_new_test_history USING btree (new_test_id);


--
-- Name: index_activity_log_new_test_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_test_history_on_user_id ON ml_app.activity_log_new_test_history USING btree (user_id);


--
-- Name: index_activity_log_new_tests_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_tests_on_master_id ON ml_app.activity_log_new_tests USING btree (master_id);


--
-- Name: index_activity_log_new_tests_on_new_test_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_tests_on_new_test_id ON ml_app.activity_log_new_tests USING btree (new_test_id);


--
-- Name: index_activity_log_new_tests_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_new_tests_on_user_id ON ml_app.activity_log_new_tests USING btree (user_id);


--
-- Name: index_activity_log_player_contact_phone_history_on_activity_log; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phone_history_on_activity_log ON ml_app.activity_log_player_contact_phone_history USING btree (activity_log_player_contact_phone_id);


--
-- Name: index_activity_log_player_contact_phone_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phone_history_on_master_id ON ml_app.activity_log_player_contact_phone_history USING btree (master_id);


--
-- Name: index_activity_log_player_contact_phone_history_on_player_conta; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phone_history_on_player_conta ON ml_app.activity_log_player_contact_phone_history USING btree (player_contact_id);


--
-- Name: index_activity_log_player_contact_phone_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phone_history_on_user_id ON ml_app.activity_log_player_contact_phone_history USING btree (user_id);


--
-- Name: index_activity_log_player_contact_phones_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phones_on_master_id ON ml_app.activity_log_player_contact_phones USING btree (master_id);


--
-- Name: index_activity_log_player_contact_phones_on_player_contact_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phones_on_player_contact_id ON ml_app.activity_log_player_contact_phones USING btree (player_contact_id);


--
-- Name: index_activity_log_player_contact_phones_on_protocol_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phones_on_protocol_id ON ml_app.activity_log_player_contact_phones USING btree (protocol_id);


--
-- Name: index_activity_log_player_contact_phones_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_contact_phones_on_user_id ON ml_app.activity_log_player_contact_phones USING btree (user_id);


--
-- Name: index_activity_log_player_info_history_on_activity_log_player_i; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_info_history_on_activity_log_player_i ON ml_app.activity_log_player_info_history USING btree (activity_log_player_info_id);


--
-- Name: index_activity_log_player_info_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_info_history_on_master_id ON ml_app.activity_log_player_info_history USING btree (master_id);


--
-- Name: index_activity_log_player_info_history_on_player_info_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_info_history_on_player_info_id ON ml_app.activity_log_player_info_history USING btree (player_info_id);


--
-- Name: index_activity_log_player_info_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_info_history_on_user_id ON ml_app.activity_log_player_info_history USING btree (user_id);


--
-- Name: index_activity_log_player_infos_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_infos_on_master_id ON ml_app.activity_log_player_infos USING btree (master_id);


--
-- Name: index_activity_log_player_infos_on_player_info_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_infos_on_player_info_id ON ml_app.activity_log_player_infos USING btree (player_info_id);


--
-- Name: index_activity_log_player_infos_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_activity_log_player_infos_on_user_id ON ml_app.activity_log_player_infos USING btree (user_id);


--
-- Name: index_address_history_on_address_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_address_history_on_address_id ON ml_app.address_history USING btree (address_id);


--
-- Name: index_address_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_address_history_on_master_id ON ml_app.address_history USING btree (master_id);


--
-- Name: index_address_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_address_history_on_user_id ON ml_app.address_history USING btree (user_id);


--
-- Name: index_addresses_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_addresses_on_master_id ON ml_app.addresses USING btree (master_id);


--
-- Name: index_addresses_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_addresses_on_user_id ON ml_app.addresses USING btree (user_id);


--
-- Name: index_admin_action_logs_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_admin_action_logs_on_admin_id ON ml_app.admin_action_logs USING btree (admin_id);


--
-- Name: index_admin_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_admin_history_on_admin_id ON ml_app.admin_history USING btree (admin_id);


--
-- Name: index_admin_history_on_upd_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_admin_history_on_upd_admin_id ON ml_app.admin_history USING btree (updated_by_admin_id);


--
-- Name: index_admins_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_admins_on_admin_id ON ml_app.admins USING btree (admin_id);


--
-- Name: index_app_configuration_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_configuration_history_on_admin_id ON ml_app.app_configuration_history USING btree (admin_id);


--
-- Name: index_app_configuration_history_on_app_configuration_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_configuration_history_on_app_configuration_id ON ml_app.app_configuration_history USING btree (app_configuration_id);


--
-- Name: index_app_configurations_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_configurations_on_admin_id ON ml_app.app_configurations USING btree (admin_id);


--
-- Name: index_app_configurations_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_configurations_on_app_type_id ON ml_app.app_configurations USING btree (app_type_id);


--
-- Name: index_app_configurations_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_configurations_on_user_id ON ml_app.app_configurations USING btree (user_id);


--
-- Name: index_app_type_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_type_history_on_admin_id ON ml_app.app_type_history USING btree (admin_id);


--
-- Name: index_app_type_history_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_type_history_on_app_type_id ON ml_app.app_type_history USING btree (app_type_id);


--
-- Name: index_app_types_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_app_types_on_admin_id ON ml_app.app_types USING btree (admin_id);


--
-- Name: index_bhs_assignment_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignment_history_on_admin_id ON ml_app.bhs_assignment_history USING btree (admin_id);


--
-- Name: index_bhs_assignment_history_on_bhs_assignment_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignment_history_on_bhs_assignment_table_id ON ml_app.bhs_assignment_history USING btree (bhs_assignment_table_id);


--
-- Name: index_bhs_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignment_history_on_master_id ON ml_app.bhs_assignment_history USING btree (master_id);


--
-- Name: index_bhs_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignment_history_on_user_id ON ml_app.bhs_assignment_history USING btree (user_id);


--
-- Name: index_bhs_assignments_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignments_on_admin_id ON ml_app.bhs_assignments USING btree (admin_id);


--
-- Name: index_bhs_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignments_on_master_id ON ml_app.bhs_assignments USING btree (master_id);


--
-- Name: index_bhs_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_bhs_assignments_on_user_id ON ml_app.bhs_assignments USING btree (user_id);


--
-- Name: index_college_history_on_college_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_college_history_on_college_id ON ml_app.college_history USING btree (college_id);


--
-- Name: index_colleges_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_colleges_on_admin_id ON ml_app.colleges USING btree (admin_id);


--
-- Name: index_colleges_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_colleges_on_user_id ON ml_app.colleges USING btree (user_id);


--
-- Name: index_config_libraries_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_config_libraries_on_admin_id ON ml_app.config_libraries USING btree (admin_id);


--
-- Name: index_config_library_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_config_library_history_on_admin_id ON ml_app.config_library_history USING btree (admin_id);


--
-- Name: index_config_library_history_on_config_library_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_config_library_history_on_config_library_id ON ml_app.config_library_history USING btree (config_library_id);


--
-- Name: index_dynamic_model_history_on_dynamic_model_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_dynamic_model_history_on_dynamic_model_id ON ml_app.dynamic_model_history USING btree (dynamic_model_id);


--
-- Name: index_dynamic_models_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_dynamic_models_on_admin_id ON ml_app.dynamic_models USING btree (admin_id);


--
-- Name: index_exception_logs_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_exception_logs_on_admin_id ON ml_app.exception_logs USING btree (admin_id);


--
-- Name: index_exception_logs_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_exception_logs_on_user_id ON ml_app.exception_logs USING btree (user_id);


--
-- Name: index_ext_assignment_history_on_ext_assignment_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_assignment_history_on_ext_assignment_table_id ON ml_app.ext_assignment_history USING btree (ext_assignment_table_id);


--
-- Name: index_ext_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_assignment_history_on_master_id ON ml_app.ext_assignment_history USING btree (master_id);


--
-- Name: index_ext_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_assignment_history_on_user_id ON ml_app.ext_assignment_history USING btree (user_id);


--
-- Name: index_ext_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_assignments_on_master_id ON ml_app.ext_assignments USING btree (master_id);


--
-- Name: index_ext_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_assignments_on_user_id ON ml_app.ext_assignments USING btree (user_id);


--
-- Name: index_ext_gen_assignment_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignment_history_on_admin_id ON ml_app.ext_gen_assignment_history USING btree (admin_id);


--
-- Name: index_ext_gen_assignment_history_on_ext_gen_assignment_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignment_history_on_ext_gen_assignment_table_id ON ml_app.ext_gen_assignment_history USING btree (ext_gen_assignment_table_id);


--
-- Name: index_ext_gen_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignment_history_on_master_id ON ml_app.ext_gen_assignment_history USING btree (master_id);


--
-- Name: index_ext_gen_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignment_history_on_user_id ON ml_app.ext_gen_assignment_history USING btree (user_id);


--
-- Name: index_ext_gen_assignments_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignments_on_admin_id ON ml_app.ext_gen_assignments USING btree (admin_id);


--
-- Name: index_ext_gen_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignments_on_master_id ON ml_app.ext_gen_assignments USING btree (master_id);


--
-- Name: index_ext_gen_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_ext_gen_assignments_on_user_id ON ml_app.ext_gen_assignments USING btree (user_id);


--
-- Name: index_external_identifier_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_external_identifier_history_on_admin_id ON ml_app.external_identifier_history USING btree (admin_id);


--
-- Name: index_external_identifier_history_on_external_identifier_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_external_identifier_history_on_external_identifier_id ON ml_app.external_identifier_history USING btree (external_identifier_id);


--
-- Name: index_external_identifiers_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_external_identifiers_on_admin_id ON ml_app.external_identifiers USING btree (admin_id);


--
-- Name: index_external_link_history_on_external_link_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_external_link_history_on_external_link_id ON ml_app.external_link_history USING btree (external_link_id);


--
-- Name: index_external_links_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_external_links_on_admin_id ON ml_app.external_links USING btree (admin_id);


--
-- Name: index_general_selection_history_on_general_selection_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_general_selection_history_on_general_selection_id ON ml_app.general_selection_history USING btree (general_selection_id);


--
-- Name: index_general_selections_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_general_selections_on_admin_id ON ml_app.general_selections USING btree (admin_id);


--
-- Name: index_grit_assignment_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignment_history_on_admin_id ON ml_app.grit_assignment_history USING btree (admin_id);


--
-- Name: index_grit_assignment_history_on_grit_assignment_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignment_history_on_grit_assignment_table_id ON ml_app.grit_assignment_history USING btree (grit_assignment_table_id);


--
-- Name: index_grit_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignment_history_on_master_id ON ml_app.grit_assignment_history USING btree (master_id);


--
-- Name: index_grit_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignment_history_on_user_id ON ml_app.grit_assignment_history USING btree (user_id);


--
-- Name: index_grit_assignments_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignments_on_admin_id ON ml_app.grit_assignments USING btree (admin_id);


--
-- Name: index_grit_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignments_on_master_id ON ml_app.grit_assignments USING btree (master_id);


--
-- Name: index_grit_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_grit_assignments_on_user_id ON ml_app.grit_assignments USING btree (user_id);


--
-- Name: index_imports_model_generators_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_imports_model_generators_on_admin_id ON ml_app.imports_model_generators USING btree (admin_id);


--
-- Name: index_imports_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_imports_on_user_id ON ml_app.imports USING btree (user_id);


--
-- Name: index_item_flag_history_on_item_flag_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_item_flag_history_on_item_flag_id ON ml_app.item_flag_history USING btree (item_flag_id);


--
-- Name: index_item_flag_name_history_on_item_flag_name_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_item_flag_name_history_on_item_flag_name_id ON ml_app.item_flag_name_history USING btree (item_flag_name_id);


--
-- Name: index_item_flag_names_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_item_flag_names_on_admin_id ON ml_app.item_flag_names USING btree (admin_id);


--
-- Name: index_item_flags_on_item_flag_name_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_item_flags_on_item_flag_name_id ON ml_app.item_flags USING btree (item_flag_name_id);


--
-- Name: index_item_flags_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_item_flags_on_user_id ON ml_app.item_flags USING btree (user_id);


--
-- Name: index_masters_on_created_by_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_masters_on_created_by_user_id ON ml_app.masters USING btree (created_by_user_id);


--
-- Name: index_masters_on_msid; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_masters_on_msid ON ml_app.masters USING btree (msid);


--
-- Name: index_masters_on_pro_info_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_masters_on_pro_info_id ON ml_app.masters USING btree (pro_info_id);


--
-- Name: index_masters_on_proid; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_masters_on_proid ON ml_app.masters USING btree (pro_id);


--
-- Name: index_masters_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_masters_on_user_id ON ml_app.masters USING btree (user_id);


--
-- Name: index_message_notifications_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_notifications_on_app_type_id ON ml_app.message_notifications USING btree (app_type_id);


--
-- Name: index_message_notifications_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_notifications_on_master_id ON ml_app.message_notifications USING btree (master_id);


--
-- Name: index_message_notifications_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_notifications_on_user_id ON ml_app.message_notifications USING btree (user_id);


--
-- Name: index_message_notifications_status; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_notifications_status ON ml_app.message_notifications USING btree (status);


--
-- Name: index_message_template_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_template_history_on_admin_id ON ml_app.message_template_history USING btree (admin_id);


--
-- Name: index_message_template_history_on_message_template_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_template_history_on_message_template_id ON ml_app.message_template_history USING btree (message_template_id);


--
-- Name: index_message_templates_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_message_templates_on_admin_id ON ml_app.message_templates USING btree (admin_id);


--
-- Name: index_ml_app.activity_log_bhs_assignments_on_bhs_assignment_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX "index_ml_app.activity_log_bhs_assignments_on_bhs_assignment_id" ON ml_app.activity_log_bhs_assignments USING btree (bhs_assignment_id);


--
-- Name: index_model_references_on_from_record_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_model_references_on_from_record_master_id ON ml_app.model_references USING btree (from_record_master_id);


--
-- Name: index_model_references_on_from_record_type_and_from_record_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_model_references_on_from_record_type_and_from_record_id ON ml_app.model_references USING btree (from_record_type, from_record_id);


--
-- Name: index_model_references_on_to_record_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_model_references_on_to_record_master_id ON ml_app.model_references USING btree (to_record_master_id);


--
-- Name: index_model_references_on_to_record_type_and_to_record_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_model_references_on_to_record_type_and_to_record_id ON ml_app.model_references USING btree (to_record_type, to_record_id);


--
-- Name: index_model_references_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_model_references_on_user_id ON ml_app.model_references USING btree (user_id);


--
-- Name: index_new_test_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_test_history_on_admin_id ON ml_app.new_test_history USING btree (admin_id);


--
-- Name: index_new_test_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_test_history_on_master_id ON ml_app.new_test_history USING btree (master_id);


--
-- Name: index_new_test_history_on_new_test_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_test_history_on_new_test_table_id ON ml_app.new_test_history USING btree (new_test_table_id);


--
-- Name: index_new_test_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_test_history_on_user_id ON ml_app.new_test_history USING btree (user_id);


--
-- Name: index_new_tests_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_tests_on_admin_id ON ml_app.new_tests USING btree (admin_id);


--
-- Name: index_new_tests_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_tests_on_master_id ON ml_app.new_tests USING btree (master_id);


--
-- Name: index_new_tests_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_new_tests_on_user_id ON ml_app.new_tests USING btree (user_id);


--
-- Name: index_nfs_store_archived_file_history_on_nfs_store_archived_fil; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_archived_file_history_on_nfs_store_archived_fil ON ml_app.nfs_store_archived_file_history USING btree (nfs_store_archived_file_id);


--
-- Name: index_nfs_store_archived_file_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_archived_file_history_on_user_id ON ml_app.nfs_store_archived_file_history USING btree (user_id);


--
-- Name: index_nfs_store_archived_files_on_nfs_store_container_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_archived_files_on_nfs_store_container_id ON ml_app.nfs_store_archived_files USING btree (nfs_store_container_id);


--
-- Name: index_nfs_store_archived_files_on_nfs_store_stored_file_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_archived_files_on_nfs_store_stored_file_id ON ml_app.nfs_store_archived_files USING btree (nfs_store_stored_file_id);


--
-- Name: index_nfs_store_container_history_on_created_by_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_container_history_on_created_by_user_id ON ml_app.nfs_store_container_history USING btree (created_by_user_id);


--
-- Name: index_nfs_store_container_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_container_history_on_master_id ON ml_app.nfs_store_container_history USING btree (master_id);


--
-- Name: index_nfs_store_container_history_on_nfs_store_container_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_container_history_on_nfs_store_container_id ON ml_app.nfs_store_container_history USING btree (nfs_store_container_id);


--
-- Name: index_nfs_store_container_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_container_history_on_user_id ON ml_app.nfs_store_container_history USING btree (user_id);


--
-- Name: index_nfs_store_containers_on_created_by_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_containers_on_created_by_user_id ON ml_app.nfs_store_containers USING btree (created_by_user_id);


--
-- Name: index_nfs_store_containers_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_containers_on_master_id ON ml_app.nfs_store_containers USING btree (master_id);


--
-- Name: index_nfs_store_containers_on_nfs_store_container_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_containers_on_nfs_store_container_id ON ml_app.nfs_store_containers USING btree (nfs_store_container_id);


--
-- Name: index_nfs_store_filter_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_filter_history_on_admin_id ON ml_app.nfs_store_filter_history USING btree (admin_id);


--
-- Name: index_nfs_store_filter_history_on_nfs_store_filter_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_filter_history_on_nfs_store_filter_id ON ml_app.nfs_store_filter_history USING btree (nfs_store_filter_id);


--
-- Name: index_nfs_store_filters_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_filters_on_admin_id ON ml_app.nfs_store_filters USING btree (admin_id);


--
-- Name: index_nfs_store_filters_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_filters_on_app_type_id ON ml_app.nfs_store_filters USING btree (app_type_id);


--
-- Name: index_nfs_store_filters_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_filters_on_user_id ON ml_app.nfs_store_filters USING btree (user_id);


--
-- Name: index_nfs_store_stored_file_history_on_nfs_store_stored_file_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_stored_file_history_on_nfs_store_stored_file_id ON ml_app.nfs_store_stored_file_history USING btree (nfs_store_stored_file_id);


--
-- Name: index_nfs_store_stored_file_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_stored_file_history_on_user_id ON ml_app.nfs_store_stored_file_history USING btree (user_id);


--
-- Name: index_nfs_store_stored_files_on_nfs_store_container_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_stored_files_on_nfs_store_container_id ON ml_app.nfs_store_stored_files USING btree (nfs_store_container_id);


--
-- Name: index_nfs_store_uploads_on_nfs_store_stored_file_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_uploads_on_nfs_store_stored_file_id ON ml_app.nfs_store_uploads USING btree (nfs_store_stored_file_id);


--
-- Name: index_nfs_store_uploads_on_upload_set; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_nfs_store_uploads_on_upload_set ON ml_app.nfs_store_uploads USING btree (upload_set);


--
-- Name: index_page_layout_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_page_layout_history_on_admin_id ON ml_app.page_layout_history USING btree (admin_id);


--
-- Name: index_page_layout_history_on_page_layout_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_page_layout_history_on_page_layout_id ON ml_app.page_layout_history USING btree (page_layout_id);


--
-- Name: index_page_layouts_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_page_layouts_on_admin_id ON ml_app.page_layouts USING btree (admin_id);


--
-- Name: index_page_layouts_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_page_layouts_on_app_type_id ON ml_app.page_layouts USING btree (app_type_id);


--
-- Name: index_player_contact_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_contact_history_on_master_id ON ml_app.player_contact_history USING btree (master_id);


--
-- Name: index_player_contact_history_on_player_contact_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_contact_history_on_player_contact_id ON ml_app.player_contact_history USING btree (player_contact_id);


--
-- Name: index_player_contact_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_contact_history_on_user_id ON ml_app.player_contact_history USING btree (user_id);


--
-- Name: index_player_contacts_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_contacts_on_master_id ON ml_app.player_contacts USING btree (master_id);


--
-- Name: index_player_contacts_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_contacts_on_user_id ON ml_app.player_contacts USING btree (user_id);


--
-- Name: index_player_info_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_info_history_on_master_id ON ml_app.player_info_history USING btree (master_id);


--
-- Name: index_player_info_history_on_player_info_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_info_history_on_player_info_id ON ml_app.player_info_history USING btree (player_info_id);


--
-- Name: index_player_info_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_info_history_on_user_id ON ml_app.player_info_history USING btree (user_id);


--
-- Name: index_player_infos_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_infos_on_master_id ON ml_app.player_infos USING btree (master_id);


--
-- Name: index_player_infos_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_player_infos_on_user_id ON ml_app.player_infos USING btree (user_id);


--
-- Name: index_pro_infos_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_pro_infos_on_master_id ON ml_app.pro_infos USING btree (master_id);


--
-- Name: index_pro_infos_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_pro_infos_on_user_id ON ml_app.pro_infos USING btree (user_id);


--
-- Name: index_protocol_event_history_on_protocol_event_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_protocol_event_history_on_protocol_event_id ON ml_app.protocol_event_history USING btree (protocol_event_id);


--
-- Name: index_protocol_events_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_protocol_events_on_admin_id ON ml_app.protocol_events USING btree (admin_id);


--
-- Name: index_protocol_events_on_sub_process_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_protocol_events_on_sub_process_id ON ml_app.protocol_events USING btree (sub_process_id);


--
-- Name: index_protocol_history_on_protocol_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_protocol_history_on_protocol_id ON ml_app.protocol_history USING btree (protocol_id);


--
-- Name: index_protocols_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_protocols_on_admin_id ON ml_app.protocols USING btree (admin_id);


--
-- Name: index_protocols_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_protocols_on_app_type_id ON ml_app.protocols USING btree (app_type_id);


--
-- Name: index_report_history_on_report_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_report_history_on_report_id ON ml_app.report_history USING btree (report_id);


--
-- Name: index_reports_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_reports_on_admin_id ON ml_app.reports USING btree (admin_id);


--
-- Name: index_role_description_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_role_description_history_on_admin_id ON ml_app.role_description_history USING btree (admin_id);


--
-- Name: index_role_description_history_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_role_description_history_on_app_type_id ON ml_app.role_description_history USING btree (app_type_id);


--
-- Name: index_role_descriptions_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_role_descriptions_on_admin_id ON ml_app.role_descriptions USING btree (admin_id);


--
-- Name: index_role_descriptions_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_role_descriptions_on_app_type_id ON ml_app.role_descriptions USING btree (app_type_id);


--
-- Name: index_sage_assignments_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_assignments_on_admin_id ON ml_app.sage_assignments USING btree (admin_id);


--
-- Name: index_sage_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_assignments_on_master_id ON ml_app.sage_assignments USING btree (master_id);


--
-- Name: index_sage_assignments_on_sage_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_sage_assignments_on_sage_id ON ml_app.sage_assignments USING btree (sage_id);


--
-- Name: index_sage_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_assignments_on_user_id ON ml_app.sage_assignments USING btree (user_id);


--
-- Name: index_sage_two_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_two_history_on_master_id ON ml_app.sage_two_history USING btree (master_id);


--
-- Name: index_sage_two_history_on_sage_two_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_two_history_on_sage_two_id ON ml_app.sage_two_history USING btree (sage_two_id);


--
-- Name: index_sage_two_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_two_history_on_user_id ON ml_app.sage_two_history USING btree (user_id);


--
-- Name: index_sage_twos_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_twos_on_master_id ON ml_app.sage_twos USING btree (master_id);


--
-- Name: index_sage_twos_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sage_twos_on_user_id ON ml_app.sage_twos USING btree (user_id);


--
-- Name: index_scantron_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_history_on_master_id ON ml_app.scantron_history USING btree (master_id);


--
-- Name: index_scantron_history_on_scantron_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_history_on_scantron_table_id ON ml_app.scantron_history USING btree (scantron_table_id);


--
-- Name: index_scantron_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_history_on_user_id ON ml_app.scantron_history USING btree (user_id);


--
-- Name: index_scantron_q2_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2_history_on_admin_id ON ml_app.scantron_q2_history USING btree (admin_id);


--
-- Name: index_scantron_q2_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2_history_on_master_id ON ml_app.scantron_q2_history USING btree (master_id);


--
-- Name: index_scantron_q2_history_on_scantron_q2_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2_history_on_scantron_q2_table_id ON ml_app.scantron_q2_history USING btree (scantron_q2_table_id);


--
-- Name: index_scantron_q2_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2_history_on_user_id ON ml_app.scantron_q2_history USING btree (user_id);


--
-- Name: index_scantron_q2s_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2s_on_admin_id ON ml_app.scantron_q2s USING btree (admin_id);


--
-- Name: index_scantron_q2s_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2s_on_master_id ON ml_app.scantron_q2s USING btree (master_id);


--
-- Name: index_scantron_q2s_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_q2s_on_user_id ON ml_app.scantron_q2s USING btree (user_id);


--
-- Name: index_scantron_series_two_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_series_two_history_on_master_id ON ml_app.scantron_series_two_history USING btree (master_id);


--
-- Name: index_scantron_series_two_history_on_scantron_series_two_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_series_two_history_on_scantron_series_two_id ON ml_app.scantron_series_two_history USING btree (scantron_series_two_id);


--
-- Name: index_scantron_series_two_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_series_two_history_on_user_id ON ml_app.scantron_series_two_history USING btree (user_id);


--
-- Name: index_scantron_series_twos_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_series_twos_on_master_id ON ml_app.scantron_series_twos USING btree (master_id);


--
-- Name: index_scantron_series_twos_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantron_series_twos_on_user_id ON ml_app.scantron_series_twos USING btree (user_id);


--
-- Name: index_scantrons_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantrons_on_master_id ON ml_app.scantrons USING btree (master_id);


--
-- Name: index_scantrons_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_scantrons_on_user_id ON ml_app.scantrons USING btree (user_id);


--
-- Name: index_sessions_on_session_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_sessions_on_session_id ON ml_app.sessions USING btree (session_id);


--
-- Name: index_sessions_on_updated_at; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sessions_on_updated_at ON ml_app.sessions USING btree (updated_at);


--
-- Name: index_sleep_assignment_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignment_history_on_admin_id ON ml_app.sleep_assignment_history USING btree (admin_id);


--
-- Name: index_sleep_assignment_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignment_history_on_master_id ON ml_app.sleep_assignment_history USING btree (master_id);


--
-- Name: index_sleep_assignment_history_on_sleep_assignment_table_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignment_history_on_sleep_assignment_table_id ON ml_app.sleep_assignment_history USING btree (sleep_assignment_table_id);


--
-- Name: index_sleep_assignment_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignment_history_on_user_id ON ml_app.sleep_assignment_history USING btree (user_id);


--
-- Name: index_sleep_assignments_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignments_on_admin_id ON ml_app.sleep_assignments USING btree (admin_id);


--
-- Name: index_sleep_assignments_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignments_on_master_id ON ml_app.sleep_assignments USING btree (master_id);


--
-- Name: index_sleep_assignments_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sleep_assignments_on_user_id ON ml_app.sleep_assignments USING btree (user_id);


--
-- Name: index_sub_process_history_on_sub_process_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sub_process_history_on_sub_process_id ON ml_app.sub_process_history USING btree (sub_process_id);


--
-- Name: index_sub_processes_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sub_processes_on_admin_id ON ml_app.sub_processes USING btree (admin_id);


--
-- Name: index_sub_processes_on_protocol_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_sub_processes_on_protocol_id ON ml_app.sub_processes USING btree (protocol_id);


--
-- Name: index_tracker_history_on_item_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_item_type_id ON ml_app.tracker_history USING btree (item_type, item_id);


--
-- Name: index_tracker_history_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_master_id ON ml_app.tracker_history USING btree (master_id);


--
-- Name: index_tracker_history_on_protocol_event_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_protocol_event_id ON ml_app.tracker_history USING btree (protocol_event_id);


--
-- Name: index_tracker_history_on_protocol_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_protocol_id ON ml_app.tracker_history USING btree (protocol_id);


--
-- Name: index_tracker_history_on_sub_process_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_sub_process_id ON ml_app.tracker_history USING btree (sub_process_id);


--
-- Name: index_tracker_history_on_tracker_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_tracker_id ON ml_app.tracker_history USING btree (tracker_id);


--
-- Name: index_tracker_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_tracker_history_on_user_id ON ml_app.tracker_history USING btree (user_id);


--
-- Name: index_trackers_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_trackers_on_master_id ON ml_app.trackers USING btree (master_id);


--
-- Name: index_trackers_on_protocol_event_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_trackers_on_protocol_event_id ON ml_app.trackers USING btree (protocol_event_id);


--
-- Name: index_trackers_on_protocol_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_trackers_on_protocol_id ON ml_app.trackers USING btree (protocol_id);


--
-- Name: index_trackers_on_sub_process_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_trackers_on_sub_process_id ON ml_app.trackers USING btree (sub_process_id);


--
-- Name: index_trackers_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_trackers_on_user_id ON ml_app.trackers USING btree (user_id);


--
-- Name: index_user_access_control_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_access_control_history_on_admin_id ON ml_app.user_access_control_history USING btree (admin_id);


--
-- Name: index_user_access_control_history_on_user_access_control_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_access_control_history_on_user_access_control_id ON ml_app.user_access_control_history USING btree (user_access_control_id);


--
-- Name: index_user_access_controls_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_access_controls_on_app_type_id ON ml_app.user_access_controls USING btree (app_type_id);


--
-- Name: index_user_action_logs_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_action_logs_on_app_type_id ON ml_app.user_action_logs USING btree (app_type_id);


--
-- Name: index_user_action_logs_on_master_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_action_logs_on_master_id ON ml_app.user_action_logs USING btree (master_id);


--
-- Name: index_user_action_logs_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_action_logs_on_user_id ON ml_app.user_action_logs USING btree (user_id);


--
-- Name: index_user_authorization_history_on_user_authorization_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_authorization_history_on_user_authorization_id ON ml_app.user_authorization_history USING btree (user_authorization_id);


--
-- Name: index_user_history_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_history_on_app_type_id ON ml_app.user_history USING btree (app_type_id);


--
-- Name: index_user_history_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_history_on_user_id ON ml_app.user_history USING btree (user_id);


--
-- Name: index_user_preferences_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_user_preferences_on_user_id ON ml_app.user_preferences USING btree (user_id);


--
-- Name: index_user_role_history_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_role_history_on_admin_id ON ml_app.user_role_history USING btree (admin_id);


--
-- Name: index_user_role_history_on_user_role_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_role_history_on_user_role_id ON ml_app.user_role_history USING btree (user_role_id);


--
-- Name: index_user_roles_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_roles_on_admin_id ON ml_app.user_roles USING btree (admin_id);


--
-- Name: index_user_roles_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_roles_on_app_type_id ON ml_app.user_roles USING btree (app_type_id);


--
-- Name: index_user_roles_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_user_roles_on_user_id ON ml_app.user_roles USING btree (user_id);


--
-- Name: index_users_contact_infos_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_users_contact_infos_on_admin_id ON ml_app.users_contact_infos USING btree (admin_id);


--
-- Name: index_users_contact_infos_on_user_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_users_contact_infos_on_user_id ON ml_app.users_contact_infos USING btree (user_id);


--
-- Name: index_users_on_admin_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_users_on_admin_id ON ml_app.users USING btree (admin_id);


--
-- Name: index_users_on_app_type_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE INDEX index_users_on_app_type_id ON ml_app.users USING btree (app_type_id);


--
-- Name: index_users_on_authentication_token; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_users_on_authentication_token ON ml_app.users USING btree (authentication_token);


--
-- Name: index_users_on_confirmation_token; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_users_on_confirmation_token ON ml_app.users USING btree (confirmation_token);


--
-- Name: index_users_on_email; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON ml_app.users USING btree (email);


--
-- Name: index_users_on_reset_password_token; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_users_on_reset_password_token ON ml_app.users USING btree (reset_password_token);


--
-- Name: index_users_on_unlock_token; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX index_users_on_unlock_token ON ml_app.users USING btree (unlock_token);


--
-- Name: nfs_store_stored_files_unique_file; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX nfs_store_stored_files_unique_file ON ml_app.nfs_store_stored_files USING btree (nfs_store_container_id, file_hash, file_name, path);


--
-- Name: unique_master_protocol; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX unique_master_protocol ON ml_app.trackers USING btree (master_id, protocol_id);


--
-- Name: unique_master_protocol_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX unique_master_protocol_id ON ml_app.trackers USING btree (master_id, protocol_id, id);


--
-- Name: unique_protocol_and_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX unique_protocol_and_id ON ml_app.sub_processes USING btree (protocol_id, id);


--
-- Name: unique_schema_migrations; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX unique_schema_migrations ON ml_app.schema_migrations USING btree (version);


--
-- Name: unique_sub_process_and_id; Type: INDEX; Schema: ml_app; Owner: -
--

CREATE UNIQUE INDEX unique_sub_process_and_id ON ml_app.protocol_events USING btree (sub_process_id, id);


--
-- Name: 5de73de6_id_idx; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "5de73de6_id_idx" ON ref_data.redcap_user_status_rec_history USING btree (redcap_user_status_rec_id);


--
-- Name: 5de73de6_user_idx; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "5de73de6_user_idx" ON ref_data.redcap_user_status_rec_history USING btree (user_id);


--
-- Name: d0aaf0ef_id_idx; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX d0aaf0ef_id_idx ON ref_data.data_variable_package_history USING btree (data_variable_package_id);


--
-- Name: d0aaf0ef_user_idx; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX d0aaf0ef_user_idx ON ref_data.data_variable_package_history USING btree (user_id);


--
-- Name: idx_dch_on_redcap_dd_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_dch_on_redcap_dd_id ON ref_data.datadic_choice_history USING btree (redcap_data_dictionary_id);


--
-- Name: idx_dv_equiv; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_dv_equiv ON ref_data.datadic_variables USING btree (equivalent_to_id);


--
-- Name: idx_dvh_equiv; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_dvh_equiv ON ref_data.datadic_variable_history USING btree (equivalent_to_id);


--
-- Name: idx_dvh_on_redcap_dd_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_dvh_on_redcap_dd_id ON ref_data.datadic_variable_history USING btree (redcap_data_dictionary_id);


--
-- Name: idx_h_on_datadic_variable_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_h_on_datadic_variable_id ON ref_data.datadic_variable_history USING btree (datadic_variable_id);


--
-- Name: idx_h_on_proj_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_h_on_proj_admin_id ON ref_data.redcap_project_user_history USING btree (redcap_project_admin_id);


--
-- Name: idx_h_on_rdci_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_h_on_rdci_id ON ref_data.redcap_data_collection_instrument_history USING btree (redcap_data_collection_instrument_id);


--
-- Name: idx_h_on_redcap_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_h_on_redcap_admin_id ON ref_data.redcap_data_dictionary_history USING btree (redcap_project_admin_id);


--
-- Name: idx_h_on_redcap_project_user_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_h_on_redcap_project_user_id ON ref_data.redcap_project_user_history USING btree (redcap_project_user_id);


--
-- Name: idx_history_on_datadic_choice_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_history_on_datadic_choice_id ON ref_data.datadic_choice_history USING btree (datadic_choice_id);


--
-- Name: idx_history_on_redcap_data_dictionary_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_history_on_redcap_data_dictionary_id ON ref_data.redcap_data_dictionary_history USING btree (redcap_data_dictionary_id);


--
-- Name: idx_history_on_redcap_project_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_history_on_redcap_project_admin_id ON ref_data.redcap_project_admin_history USING btree (redcap_project_admin_id);


--
-- Name: idx_on_redcap_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_on_redcap_admin_id ON ref_data.redcap_data_dictionaries USING btree (redcap_project_admin_id);


--
-- Name: idx_rcr_on_redcap_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_rcr_on_redcap_admin_id ON ref_data.redcap_client_requests USING btree (redcap_project_admin_id);


--
-- Name: idx_rdci_pa; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_rdci_pa ON ref_data.redcap_data_collection_instruments USING btree (redcap_project_admin_id);


--
-- Name: idx_rdcih_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_rdcih_on_admin_id ON ref_data.redcap_data_collection_instrument_history USING btree (admin_id);


--
-- Name: idx_rdcih_on_proj_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX idx_rdcih_on_proj_admin_id ON ref_data.redcap_data_collection_instrument_history USING btree (redcap_project_admin_id);


--
-- Name: index_data_requests.data_variable_packages_on_user_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_data_requests.data_variable_packages_on_user_id" ON ref_data.data_variable_packages USING btree (user_id);


--
-- Name: index_datadic_variables_on_user_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX index_datadic_variables_on_user_id ON ref_data.datadic_variables USING btree (user_id);


--
-- Name: index_ref_data.datadic_choice_history_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.datadic_choice_history_on_admin_id" ON ref_data.datadic_choice_history USING btree (admin_id);


--
-- Name: index_ref_data.datadic_choices_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.datadic_choices_on_admin_id" ON ref_data.datadic_choices USING btree (admin_id);


--
-- Name: index_ref_data.datadic_choices_on_redcap_data_dictionary_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.datadic_choices_on_redcap_data_dictionary_id" ON ref_data.datadic_choices USING btree (redcap_data_dictionary_id);


--
-- Name: index_ref_data.datadic_variable_history_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.datadic_variable_history_on_admin_id" ON ref_data.datadic_variable_history USING btree (admin_id);


--
-- Name: index_ref_data.datadic_variables_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.datadic_variables_on_admin_id" ON ref_data.datadic_variables USING btree (admin_id);


--
-- Name: index_ref_data.datadic_variables_on_redcap_data_dictionary_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.datadic_variables_on_redcap_data_dictionary_id" ON ref_data.datadic_variables USING btree (redcap_data_dictionary_id);


--
-- Name: index_ref_data.redcap_client_requests_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_client_requests_on_admin_id" ON ref_data.redcap_client_requests USING btree (admin_id);


--
-- Name: index_ref_data.redcap_data_collection_instruments_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_data_collection_instruments_on_admin_id" ON ref_data.redcap_data_collection_instruments USING btree (admin_id);


--
-- Name: index_ref_data.redcap_data_dictionaries_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_data_dictionaries_on_admin_id" ON ref_data.redcap_data_dictionaries USING btree (admin_id);


--
-- Name: index_ref_data.redcap_data_dictionary_history_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_data_dictionary_history_on_admin_id" ON ref_data.redcap_data_dictionary_history USING btree (admin_id);


--
-- Name: index_ref_data.redcap_project_admin_history_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_project_admin_history_on_admin_id" ON ref_data.redcap_project_admin_history USING btree (admin_id);


--
-- Name: index_ref_data.redcap_project_admins_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_project_admins_on_admin_id" ON ref_data.redcap_project_admins USING btree (admin_id);


--
-- Name: index_ref_data.redcap_project_user_history_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_project_user_history_on_admin_id" ON ref_data.redcap_project_user_history USING btree (admin_id);


--
-- Name: index_ref_data.redcap_project_users_on_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_project_users_on_admin_id" ON ref_data.redcap_project_users USING btree (admin_id);


--
-- Name: index_ref_data.redcap_project_users_on_redcap_project_admin_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_project_users_on_redcap_project_admin_id" ON ref_data.redcap_project_users USING btree (redcap_project_admin_id);


--
-- Name: index_ref_data.redcap_user_status_recs_on_user_id; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX "index_ref_data.redcap_user_status_recs_on_user_id" ON ref_data.redcap_user_status_recs USING btree (user_id);


--
-- Name: oldd0aaf0ef_user_idx; Type: INDEX; Schema: ref_data; Owner: -
--

CREATE INDEX oldd0aaf0ef_user_idx ON ref_data.data_variable_package_var_history USING btree (user_id);


--
-- Name: accuracy_scores accuracy_score_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER accuracy_score_history_insert AFTER INSERT ON ml_app.accuracy_scores FOR EACH ROW EXECUTE FUNCTION ml_app.log_accuracy_score_update();


--
-- Name: accuracy_scores accuracy_score_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER accuracy_score_history_update AFTER UPDATE ON ml_app.accuracy_scores FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_accuracy_score_update();


--
-- Name: activity_log_bhs_assignments activity_log_bhs_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_bhs_assignment_history_insert AFTER INSERT ON ml_app.activity_log_bhs_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_bhs_assignment_update();


--
-- Name: activity_log_bhs_assignments activity_log_bhs_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_bhs_assignment_history_update AFTER UPDATE ON ml_app.activity_log_bhs_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_bhs_assignment_update();


--
-- Name: activity_log_bhs_assignments activity_log_bhs_assignment_insert_defaults; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_bhs_assignment_insert_defaults BEFORE INSERT ON ml_app.activity_log_bhs_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.activity_log_bhs_assignment_insert_defaults();


--
-- Name: activity_log_bhs_assignments activity_log_bhs_assignment_insert_notification; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_bhs_assignment_insert_notification AFTER INSERT ON ml_app.activity_log_bhs_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.activity_log_bhs_assignment_insert_notification();


--
-- Name: activity_log_ext_assignments activity_log_ext_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_ext_assignment_history_insert AFTER INSERT ON ml_app.activity_log_ext_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_ext_assignment_update();


--
-- Name: activity_log_ext_assignments activity_log_ext_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_ext_assignment_history_update AFTER UPDATE ON ml_app.activity_log_ext_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_ext_assignment_update();


--
-- Name: activity_logs activity_log_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_history_insert AFTER INSERT ON ml_app.activity_logs FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_update();


--
-- Name: activity_logs activity_log_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_history_update AFTER UPDATE ON ml_app.activity_logs FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_update();


--
-- Name: activity_log_new_tests activity_log_new_test_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_new_test_history_insert AFTER INSERT ON ml_app.activity_log_new_tests FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_new_test_update();


--
-- Name: activity_log_new_tests activity_log_new_test_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_new_test_history_update AFTER UPDATE ON ml_app.activity_log_new_tests FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_new_test_update();


--
-- Name: activity_log_player_contact_phones activity_log_player_contact_phone_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_player_contact_phone_history_insert AFTER INSERT ON ml_app.activity_log_player_contact_phones FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_player_contact_phone_update();


--
-- Name: activity_log_player_contact_phones activity_log_player_contact_phone_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_player_contact_phone_history_update AFTER UPDATE ON ml_app.activity_log_player_contact_phones FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_player_contact_phone_update();


--
-- Name: activity_log_player_infos activity_log_player_info_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_player_info_history_insert AFTER INSERT ON ml_app.activity_log_player_infos FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_player_info_update();


--
-- Name: activity_log_player_infos activity_log_player_info_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER activity_log_player_info_history_update AFTER UPDATE ON ml_app.activity_log_player_infos FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_player_info_update();


--
-- Name: addresses address_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER address_history_insert AFTER INSERT ON ml_app.addresses FOR EACH ROW EXECUTE FUNCTION ml_app.log_address_update();


--
-- Name: addresses address_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER address_history_update AFTER UPDATE ON ml_app.addresses FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_address_update();


--
-- Name: addresses address_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER address_insert BEFORE INSERT ON ml_app.addresses FOR EACH ROW EXECUTE FUNCTION ml_app.handle_address_update();


--
-- Name: addresses address_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER address_update BEFORE UPDATE ON ml_app.addresses FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.handle_address_update();


--
-- Name: admins admin_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER admin_history_insert AFTER INSERT ON ml_app.admins FOR EACH ROW EXECUTE FUNCTION ml_app.log_admin_update();


--
-- Name: admins admin_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER admin_history_update AFTER UPDATE ON ml_app.admins FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_admin_update();


--
-- Name: app_configurations app_configuration_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER app_configuration_history_insert AFTER INSERT ON ml_app.app_configurations FOR EACH ROW EXECUTE FUNCTION ml_app.log_app_configuration_update();


--
-- Name: app_configurations app_configuration_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER app_configuration_history_update AFTER UPDATE ON ml_app.app_configurations FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_app_configuration_update();


--
-- Name: app_types app_type_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER app_type_history_insert AFTER INSERT ON ml_app.app_types FOR EACH ROW EXECUTE FUNCTION ml_app.log_app_type_update();


--
-- Name: app_types app_type_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER app_type_history_update AFTER UPDATE ON ml_app.app_types FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_app_type_update();


--
-- Name: bhs_assignments bhs_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER bhs_assignment_history_insert AFTER INSERT ON ml_app.bhs_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_bhs_assignment_update();


--
-- Name: bhs_assignments bhs_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER bhs_assignment_history_update AFTER UPDATE ON ml_app.bhs_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_bhs_assignment_update();


--
-- Name: colleges college_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER college_history_insert AFTER INSERT ON ml_app.colleges FOR EACH ROW EXECUTE FUNCTION ml_app.log_college_update();


--
-- Name: colleges college_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER college_history_update AFTER UPDATE ON ml_app.colleges FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_college_update();


--
-- Name: config_libraries config_library_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER config_library_history_insert AFTER INSERT ON ml_app.config_libraries FOR EACH ROW EXECUTE FUNCTION ml_app.log_config_library_update();


--
-- Name: config_libraries config_library_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER config_library_history_update AFTER UPDATE ON ml_app.config_libraries FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_config_library_update();


--
-- Name: dynamic_models dynamic_model_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER dynamic_model_history_insert AFTER INSERT ON ml_app.dynamic_models FOR EACH ROW EXECUTE FUNCTION ml_app.log_dynamic_model_update();


--
-- Name: dynamic_models dynamic_model_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER dynamic_model_history_update AFTER UPDATE ON ml_app.dynamic_models FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_dynamic_model_update();


--
-- Name: ext_assignments ext_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER ext_assignment_history_insert AFTER INSERT ON ml_app.ext_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_ext_assignment_update();


--
-- Name: ext_assignments ext_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER ext_assignment_history_update AFTER UPDATE ON ml_app.ext_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_ext_assignment_update();


--
-- Name: ext_gen_assignments ext_gen_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER ext_gen_assignment_history_insert AFTER INSERT ON ml_app.ext_gen_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_ext_gen_assignment_update();


--
-- Name: ext_gen_assignments ext_gen_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER ext_gen_assignment_history_update AFTER UPDATE ON ml_app.ext_gen_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_ext_gen_assignment_update();


--
-- Name: external_identifiers external_identifier_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER external_identifier_history_insert AFTER INSERT ON ml_app.external_identifiers FOR EACH ROW EXECUTE FUNCTION ml_app.log_external_identifier_update();


--
-- Name: external_identifiers external_identifier_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER external_identifier_history_update AFTER UPDATE ON ml_app.external_identifiers FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_external_identifier_update();


--
-- Name: external_links external_link_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER external_link_history_insert AFTER INSERT ON ml_app.external_links FOR EACH ROW EXECUTE FUNCTION ml_app.log_external_link_update();


--
-- Name: external_links external_link_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER external_link_history_update AFTER UPDATE ON ml_app.external_links FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_external_link_update();


--
-- Name: general_selections general_selection_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER general_selection_history_insert AFTER INSERT ON ml_app.general_selections FOR EACH ROW EXECUTE FUNCTION ml_app.log_general_selection_update();


--
-- Name: general_selections general_selection_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER general_selection_history_update AFTER UPDATE ON ml_app.general_selections FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_general_selection_update();


--
-- Name: item_flags item_flag_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER item_flag_history_insert AFTER INSERT ON ml_app.item_flags FOR EACH ROW EXECUTE FUNCTION ml_app.log_item_flag_update();


--
-- Name: item_flags item_flag_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER item_flag_history_update AFTER UPDATE ON ml_app.item_flags FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_item_flag_update();


--
-- Name: item_flag_names item_flag_name_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER item_flag_name_history_insert AFTER INSERT ON ml_app.item_flag_names FOR EACH ROW EXECUTE FUNCTION ml_app.log_item_flag_name_update();


--
-- Name: item_flag_names item_flag_name_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER item_flag_name_history_update AFTER UPDATE ON ml_app.item_flag_names FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_item_flag_name_update();


--
-- Name: activity_log_bhs_assignments log_activity_log_bhs_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER log_activity_log_bhs_assignment_history_insert AFTER INSERT ON ml_app.activity_log_bhs_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_bhs_assignments_update();


--
-- Name: activity_log_bhs_assignments log_activity_log_bhs_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER log_activity_log_bhs_assignment_history_update AFTER UPDATE ON ml_app.activity_log_bhs_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_bhs_assignments_update();


--
-- Name: activity_log_player_contact_phones log_activity_log_player_contact_phone_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER log_activity_log_player_contact_phone_history_insert AFTER INSERT ON ml_app.activity_log_player_contact_phones FOR EACH ROW EXECUTE FUNCTION ml_app.log_activity_log_player_contact_phones_update();


--
-- Name: activity_log_player_contact_phones log_activity_log_player_contact_phone_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER log_activity_log_player_contact_phone_history_update AFTER UPDATE ON ml_app.activity_log_player_contact_phones FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_activity_log_player_contact_phones_update();


--
-- Name: role_descriptions log_role_description_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER log_role_description_history_insert AFTER INSERT ON ml_app.role_descriptions FOR EACH ROW EXECUTE FUNCTION ml_app.role_description_history_upd();


--
-- Name: role_descriptions log_role_description_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER log_role_description_history_update AFTER UPDATE ON ml_app.role_descriptions FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.role_description_history_upd();


--
-- Name: message_templates message_template_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER message_template_history_insert AFTER INSERT ON ml_app.message_templates FOR EACH ROW EXECUTE FUNCTION ml_app.log_message_template_update();


--
-- Name: message_templates message_template_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER message_template_history_update AFTER UPDATE ON ml_app.message_templates FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_message_template_update();


--
-- Name: new_tests new_test_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER new_test_history_insert AFTER INSERT ON ml_app.new_tests FOR EACH ROW EXECUTE FUNCTION ml_app.log_new_test_update();


--
-- Name: new_tests new_test_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER new_test_history_update AFTER UPDATE ON ml_app.new_tests FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_new_test_update();


--
-- Name: nfs_store_archived_files nfs_store_archived_file_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_archived_file_history_insert AFTER INSERT ON ml_app.nfs_store_archived_files FOR EACH ROW EXECUTE FUNCTION ml_app.log_nfs_store_archived_file_update();


--
-- Name: nfs_store_archived_files nfs_store_archived_file_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_archived_file_history_update AFTER UPDATE ON ml_app.nfs_store_archived_files FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_nfs_store_archived_file_update();


--
-- Name: nfs_store_containers nfs_store_container_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_container_history_insert AFTER INSERT ON ml_app.nfs_store_containers FOR EACH ROW EXECUTE FUNCTION ml_app.log_nfs_store_container_update();


--
-- Name: nfs_store_containers nfs_store_container_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_container_history_update AFTER UPDATE ON ml_app.nfs_store_containers FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_nfs_store_container_update();


--
-- Name: nfs_store_filters nfs_store_filter_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_filter_history_insert AFTER INSERT ON ml_app.nfs_store_filters FOR EACH ROW EXECUTE FUNCTION ml_app.log_nfs_store_filter_update();


--
-- Name: nfs_store_filters nfs_store_filter_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_filter_history_update AFTER UPDATE ON ml_app.nfs_store_filters FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_nfs_store_filter_update();


--
-- Name: nfs_store_stored_files nfs_store_stored_file_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_stored_file_history_insert AFTER INSERT ON ml_app.nfs_store_stored_files FOR EACH ROW EXECUTE FUNCTION ml_app.log_nfs_store_stored_file_update();


--
-- Name: nfs_store_stored_files nfs_store_stored_file_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER nfs_store_stored_file_history_update AFTER UPDATE ON ml_app.nfs_store_stored_files FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_nfs_store_stored_file_update();


--
-- Name: page_layouts page_layout_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER page_layout_history_insert AFTER INSERT ON ml_app.page_layouts FOR EACH ROW EXECUTE FUNCTION ml_app.log_page_layout_update();


--
-- Name: page_layouts page_layout_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER page_layout_history_update AFTER UPDATE ON ml_app.page_layouts FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_page_layout_update();


--
-- Name: player_contacts player_contact_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_contact_history_insert AFTER INSERT ON ml_app.player_contacts FOR EACH ROW EXECUTE FUNCTION ml_app.log_player_contact_update();


--
-- Name: player_contacts player_contact_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_contact_history_update AFTER UPDATE ON ml_app.player_contacts FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_player_contact_update();


--
-- Name: player_contacts player_contact_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_contact_insert BEFORE INSERT ON ml_app.player_contacts FOR EACH ROW EXECUTE FUNCTION ml_app.handle_player_contact_update();


--
-- Name: player_contacts player_contact_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_contact_update BEFORE UPDATE ON ml_app.player_contacts FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.handle_player_contact_update();


--
-- Name: player_infos player_info_before_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_info_before_update BEFORE UPDATE ON ml_app.player_infos FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.handle_player_info_before_update();


--
-- Name: player_infos player_info_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_info_history_insert AFTER INSERT ON ml_app.player_infos FOR EACH ROW EXECUTE FUNCTION ml_app.log_player_info_update();


--
-- Name: player_infos player_info_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_info_history_update AFTER UPDATE ON ml_app.player_infos FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_player_info_update();


--
-- Name: player_infos player_info_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_info_insert AFTER INSERT ON ml_app.player_infos FOR EACH ROW EXECUTE FUNCTION ml_app.update_master_with_player_info();


--
-- Name: player_infos player_info_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER player_info_update AFTER UPDATE ON ml_app.player_infos FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.update_master_with_player_info();


--
-- Name: pro_infos pro_info_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER pro_info_insert AFTER INSERT ON ml_app.pro_infos FOR EACH ROW EXECUTE FUNCTION ml_app.update_master_with_pro_info();


--
-- Name: pro_infos pro_info_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER pro_info_update AFTER UPDATE ON ml_app.pro_infos FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.update_master_with_pro_info();


--
-- Name: protocol_events protocol_event_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER protocol_event_history_insert AFTER INSERT ON ml_app.protocol_events FOR EACH ROW EXECUTE FUNCTION ml_app.log_protocol_event_update();


--
-- Name: protocol_events protocol_event_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER protocol_event_history_update AFTER UPDATE ON ml_app.protocol_events FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_protocol_event_update();


--
-- Name: protocols protocol_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER protocol_history_insert AFTER INSERT ON ml_app.protocols FOR EACH ROW EXECUTE FUNCTION ml_app.log_protocol_update();


--
-- Name: protocols protocol_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER protocol_history_update AFTER UPDATE ON ml_app.protocols FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_protocol_update();


--
-- Name: rc_stage_cif_copy rc_cis_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER rc_cis_update BEFORE UPDATE ON ml_app.rc_stage_cif_copy FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.handle_rc_cis_update();


--
-- Name: reports report_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER report_history_insert AFTER INSERT ON ml_app.reports FOR EACH ROW EXECUTE FUNCTION ml_app.log_report_update();


--
-- Name: reports report_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER report_history_update AFTER UPDATE ON ml_app.reports FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_report_update();


--
-- Name: scantrons scantron_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER scantron_history_insert AFTER INSERT ON ml_app.scantrons FOR EACH ROW EXECUTE FUNCTION ml_app.log_scantron_update();


--
-- Name: scantrons scantron_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER scantron_history_update AFTER UPDATE ON ml_app.scantrons FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_scantron_update();


--
-- Name: scantron_q2s scantron_q2_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER scantron_q2_history_insert AFTER INSERT ON ml_app.scantron_q2s FOR EACH ROW EXECUTE FUNCTION ml_app.log_scantron_q2_update();


--
-- Name: scantron_q2s scantron_q2_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER scantron_q2_history_update AFTER UPDATE ON ml_app.scantron_q2s FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_scantron_q2_update();


--
-- Name: sleep_assignments sleep_assignment_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER sleep_assignment_history_insert AFTER INSERT ON ml_app.sleep_assignments FOR EACH ROW EXECUTE FUNCTION ml_app.log_sleep_assignment_update();


--
-- Name: sleep_assignments sleep_assignment_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER sleep_assignment_history_update AFTER UPDATE ON ml_app.sleep_assignments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_sleep_assignment_update();


--
-- Name: sub_processes sub_process_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER sub_process_history_insert AFTER INSERT ON ml_app.sub_processes FOR EACH ROW EXECUTE FUNCTION ml_app.log_sub_process_update();


--
-- Name: sub_processes sub_process_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER sub_process_history_update AFTER UPDATE ON ml_app.sub_processes FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_sub_process_update();


--
-- Name: test1s test1_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test1_history_insert AFTER INSERT ON ml_app.test1s FOR EACH ROW EXECUTE FUNCTION ml_app.log_test1_update();


--
-- Name: test1s test1_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test1_history_update AFTER UPDATE ON ml_app.test1s FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_test1_update();


--
-- Name: test2s test2_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test2_history_insert AFTER INSERT ON ml_app.test2s FOR EACH ROW EXECUTE FUNCTION ml_app.log_test2_update();


--
-- Name: test2s test2_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test2_history_update AFTER UPDATE ON ml_app.test2s FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_test2_update();


--
-- Name: test_2s test_2_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test_2_history_insert AFTER INSERT ON ml_app.test_2s FOR EACH ROW EXECUTE FUNCTION ml_app.log_test_2_update();


--
-- Name: test_2s test_2_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test_2_history_update AFTER UPDATE ON ml_app.test_2s FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_test_2_update();


--
-- Name: test_ext2s test_ext2_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test_ext2_history_insert AFTER INSERT ON ml_app.test_ext2s FOR EACH ROW EXECUTE FUNCTION ml_app.log_test_ext2_update();


--
-- Name: test_ext2s test_ext2_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test_ext2_history_update AFTER UPDATE ON ml_app.test_ext2s FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_test_ext2_update();


--
-- Name: test_exts test_ext_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test_ext_history_insert AFTER INSERT ON ml_app.test_exts FOR EACH ROW EXECUTE FUNCTION ml_app.log_test_ext_update();


--
-- Name: test_exts test_ext_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER test_ext_history_update AFTER UPDATE ON ml_app.test_exts FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_test_ext_update();


--
-- Name: trackers tracker_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER tracker_history_insert AFTER INSERT ON ml_app.trackers FOR EACH ROW EXECUTE FUNCTION ml_app.log_tracker_update();


--
-- Name: tracker_history tracker_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER tracker_history_update BEFORE UPDATE ON ml_app.tracker_history FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.handle_tracker_history_update();


--
-- Name: trackers tracker_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER tracker_history_update AFTER UPDATE ON ml_app.trackers FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_tracker_update();


--
-- Name: tracker_history tracker_record_delete; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER tracker_record_delete AFTER DELETE ON ml_app.tracker_history FOR EACH ROW EXECUTE FUNCTION ml_app.handle_delete();


--
-- Name: trackers tracker_upsert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER tracker_upsert BEFORE INSERT ON ml_app.trackers FOR EACH ROW EXECUTE FUNCTION ml_app.tracker_upsert();


--
-- Name: masters update_master_msid_trigger; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER update_master_msid_trigger AFTER INSERT ON ml_app.masters FOR EACH ROW EXECUTE FUNCTION ml_app.update_master_msid();


--
-- Name: user_access_controls user_access_control_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_access_control_history_insert AFTER INSERT ON ml_app.user_access_controls FOR EACH ROW EXECUTE FUNCTION ml_app.log_user_access_control_update();


--
-- Name: user_access_controls user_access_control_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_access_control_history_update AFTER UPDATE ON ml_app.user_access_controls FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_user_access_control_update();


--
-- Name: user_authorizations user_authorization_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_authorization_history_insert AFTER INSERT ON ml_app.user_authorizations FOR EACH ROW EXECUTE FUNCTION ml_app.log_user_authorization_update();


--
-- Name: user_authorizations user_authorization_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_authorization_history_update AFTER UPDATE ON ml_app.user_authorizations FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_user_authorization_update();


--
-- Name: users user_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_history_insert AFTER INSERT ON ml_app.users FOR EACH ROW EXECUTE FUNCTION ml_app.log_user_update();


--
-- Name: users user_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_history_update AFTER UPDATE ON ml_app.users FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_user_update();


--
-- Name: user_roles user_role_history_insert; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_role_history_insert AFTER INSERT ON ml_app.user_roles FOR EACH ROW EXECUTE FUNCTION ml_app.log_user_role_update();


--
-- Name: user_roles user_role_history_update; Type: TRIGGER; Schema: ml_app; Owner: -
--

CREATE TRIGGER user_role_history_update AFTER UPDATE ON ml_app.user_roles FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.log_user_role_update();


--
-- Name: datadic_choices log_datadic_choice_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_datadic_choice_history_insert AFTER INSERT ON ref_data.datadic_choices FOR EACH ROW EXECUTE FUNCTION ml_app.datadic_choice_history_upd();


--
-- Name: datadic_choices log_datadic_choice_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_datadic_choice_history_update AFTER UPDATE ON ref_data.datadic_choices FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.datadic_choice_history_upd();


--
-- Name: datadic_variables log_datadic_variable_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_datadic_variable_history_insert AFTER INSERT ON ref_data.datadic_variables FOR EACH ROW EXECUTE FUNCTION ref_data.log_datadic_variables_update();


--
-- Name: datadic_variables log_datadic_variable_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_datadic_variable_history_update AFTER UPDATE ON ref_data.datadic_variables FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ref_data.log_datadic_variables_update();


--
-- Name: redcap_data_collection_instruments log_redcap_data_collection_instrument_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_data_collection_instrument_history_insert AFTER INSERT ON ref_data.redcap_data_collection_instruments FOR EACH ROW EXECUTE FUNCTION ref_data.redcap_data_collection_instrument_history_upd();


--
-- Name: redcap_data_collection_instruments log_redcap_data_collection_instrument_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_data_collection_instrument_history_update AFTER UPDATE ON ref_data.redcap_data_collection_instruments FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ref_data.redcap_data_collection_instrument_history_upd();


--
-- Name: redcap_data_dictionaries log_redcap_data_dictionary_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_data_dictionary_history_insert AFTER INSERT ON ref_data.redcap_data_dictionaries FOR EACH ROW EXECUTE FUNCTION ml_app.redcap_data_dictionary_history_upd();


--
-- Name: redcap_data_dictionaries log_redcap_data_dictionary_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_data_dictionary_history_update AFTER UPDATE ON ref_data.redcap_data_dictionaries FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.redcap_data_dictionary_history_upd();


--
-- Name: redcap_project_admins log_redcap_project_admin_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_project_admin_history_insert AFTER INSERT ON ref_data.redcap_project_admins FOR EACH ROW EXECUTE FUNCTION ml_app.redcap_project_admin_history_upd();


--
-- Name: redcap_project_admins log_redcap_project_admin_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_project_admin_history_update AFTER UPDATE ON ref_data.redcap_project_admins FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ml_app.redcap_project_admin_history_upd();


--
-- Name: redcap_project_users log_redcap_project_user_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_project_user_history_insert AFTER INSERT ON ref_data.redcap_project_users FOR EACH ROW EXECUTE FUNCTION ref_data.redcap_project_user_history_upd();


--
-- Name: redcap_project_users log_redcap_project_user_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_project_user_history_update AFTER UPDATE ON ref_data.redcap_project_users FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ref_data.redcap_project_user_history_upd();


--
-- Name: redcap_user_status_recs log_redcap_user_status_rec_history_insert; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_user_status_rec_history_insert AFTER INSERT ON ref_data.redcap_user_status_recs FOR EACH ROW EXECUTE FUNCTION ref_data.log_redcap_user_status_recs_update();


--
-- Name: redcap_user_status_recs log_redcap_user_status_rec_history_update; Type: TRIGGER; Schema: ref_data; Owner: -
--

CREATE TRIGGER log_redcap_user_status_rec_history_update AFTER UPDATE ON ref_data.redcap_user_status_recs FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE FUNCTION ref_data.log_redcap_user_status_recs_update();


--
-- Name: accuracy_score_history fk_accuracy_score_history_accuracy_scores; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.accuracy_score_history
    ADD CONSTRAINT fk_accuracy_score_history_accuracy_scores FOREIGN KEY (accuracy_score_id) REFERENCES ml_app.accuracy_scores(id);


--
-- Name: activity_log_bhs_assignment_history fk_activity_log_bhs_assignment_history_activity_log_bhs_assignm; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignment_history
    ADD CONSTRAINT fk_activity_log_bhs_assignment_history_activity_log_bhs_assignm FOREIGN KEY (activity_log_bhs_assignment_id) REFERENCES ml_app.activity_log_bhs_assignments(id);


--
-- Name: activity_log_bhs_assignment_history fk_activity_log_bhs_assignment_history_bhs_assignment_id; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignment_history
    ADD CONSTRAINT fk_activity_log_bhs_assignment_history_bhs_assignment_id FOREIGN KEY (bhs_assignment_id) REFERENCES ml_app.bhs_assignments(id);


--
-- Name: activity_log_bhs_assignment_history fk_activity_log_bhs_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignment_history
    ADD CONSTRAINT fk_activity_log_bhs_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_bhs_assignment_history fk_activity_log_bhs_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignment_history
    ADD CONSTRAINT fk_activity_log_bhs_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_ext_assignment_history fk_activity_log_ext_assignment_history_activity_log_ext_assignm; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignment_history
    ADD CONSTRAINT fk_activity_log_ext_assignment_history_activity_log_ext_assignm FOREIGN KEY (activity_log_ext_assignment_id) REFERENCES ml_app.activity_log_ext_assignments(id);


--
-- Name: activity_log_ext_assignment_history fk_activity_log_ext_assignment_history_ext_assignment_id; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignment_history
    ADD CONSTRAINT fk_activity_log_ext_assignment_history_ext_assignment_id FOREIGN KEY (ext_assignment_id) REFERENCES ml_app.ext_assignments(id);


--
-- Name: activity_log_ext_assignment_history fk_activity_log_ext_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignment_history
    ADD CONSTRAINT fk_activity_log_ext_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_ext_assignment_history fk_activity_log_ext_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignment_history
    ADD CONSTRAINT fk_activity_log_ext_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_new_test_history fk_activity_log_new_test_history_activity_log_new_tests; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_test_history
    ADD CONSTRAINT fk_activity_log_new_test_history_activity_log_new_tests FOREIGN KEY (activity_log_new_test_id) REFERENCES ml_app.activity_log_new_tests(id);


--
-- Name: activity_log_new_test_history fk_activity_log_new_test_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_test_history
    ADD CONSTRAINT fk_activity_log_new_test_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_new_test_history fk_activity_log_new_test_history_new_test_id; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_test_history
    ADD CONSTRAINT fk_activity_log_new_test_history_new_test_id FOREIGN KEY (new_test_id) REFERENCES ml_app.new_tests(id);


--
-- Name: activity_log_new_test_history fk_activity_log_new_test_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_test_history
    ADD CONSTRAINT fk_activity_log_new_test_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_player_contact_phone_history fk_activity_log_player_contact_phone_history_activity_log_playe; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phone_history
    ADD CONSTRAINT fk_activity_log_player_contact_phone_history_activity_log_playe FOREIGN KEY (activity_log_player_contact_phone_id) REFERENCES ml_app.activity_log_player_contact_phones(id);


--
-- Name: activity_log_player_contact_phone_history fk_activity_log_player_contact_phone_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phone_history
    ADD CONSTRAINT fk_activity_log_player_contact_phone_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_player_contact_phone_history fk_activity_log_player_contact_phone_history_player_contact_pho; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phone_history
    ADD CONSTRAINT fk_activity_log_player_contact_phone_history_player_contact_pho FOREIGN KEY (player_contact_id) REFERENCES ml_app.player_contacts(id);


--
-- Name: activity_log_player_contact_phone_history fk_activity_log_player_contact_phone_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phone_history
    ADD CONSTRAINT fk_activity_log_player_contact_phone_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_player_info_history fk_activity_log_player_info_history_activity_log_player_infos; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_info_history
    ADD CONSTRAINT fk_activity_log_player_info_history_activity_log_player_infos FOREIGN KEY (activity_log_player_info_id) REFERENCES ml_app.activity_log_player_infos(id);


--
-- Name: activity_log_player_info_history fk_activity_log_player_info_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_info_history
    ADD CONSTRAINT fk_activity_log_player_info_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_player_info_history fk_activity_log_player_info_history_player_info_id; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_info_history
    ADD CONSTRAINT fk_activity_log_player_info_history_player_info_id FOREIGN KEY (player_info_id) REFERENCES ml_app.player_infos(id);


--
-- Name: activity_log_player_info_history fk_activity_log_player_info_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_info_history
    ADD CONSTRAINT fk_activity_log_player_info_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: address_history fk_address_history_addresses; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.address_history
    ADD CONSTRAINT fk_address_history_addresses FOREIGN KEY (address_id) REFERENCES ml_app.addresses(id);


--
-- Name: address_history fk_address_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.address_history
    ADD CONSTRAINT fk_address_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: address_history fk_address_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.address_history
    ADD CONSTRAINT fk_address_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: admin_history fk_admin_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_history
    ADD CONSTRAINT fk_admin_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: admin_history fk_admin_history_upd_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_history
    ADD CONSTRAINT fk_admin_history_upd_admins FOREIGN KEY (updated_by_admin_id) REFERENCES ml_app.admins(id);


--
-- Name: app_configuration_history fk_app_configuration_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configuration_history
    ADD CONSTRAINT fk_app_configuration_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: app_configuration_history fk_app_configuration_history_app_configurations; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configuration_history
    ADD CONSTRAINT fk_app_configuration_history_app_configurations FOREIGN KEY (app_configuration_id) REFERENCES ml_app.app_configurations(id);


--
-- Name: app_type_history fk_app_type_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_type_history
    ADD CONSTRAINT fk_app_type_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: app_type_history fk_app_type_history_app_types; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_type_history
    ADD CONSTRAINT fk_app_type_history_app_types FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: bhs_assignment_history fk_bhs_assignment_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignment_history
    ADD CONSTRAINT fk_bhs_assignment_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: bhs_assignment_history fk_bhs_assignment_history_bhs_assignments; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignment_history
    ADD CONSTRAINT fk_bhs_assignment_history_bhs_assignments FOREIGN KEY (bhs_assignment_table_id) REFERENCES ml_app.bhs_assignments(id);


--
-- Name: bhs_assignment_history fk_bhs_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignment_history
    ADD CONSTRAINT fk_bhs_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: bhs_assignment_history fk_bhs_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignment_history
    ADD CONSTRAINT fk_bhs_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: college_history fk_college_history_colleges; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.college_history
    ADD CONSTRAINT fk_college_history_colleges FOREIGN KEY (college_id) REFERENCES ml_app.colleges(id);


--
-- Name: dynamic_model_history fk_dynamic_model_history_dynamic_models; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.dynamic_model_history
    ADD CONSTRAINT fk_dynamic_model_history_dynamic_models FOREIGN KEY (dynamic_model_id) REFERENCES ml_app.dynamic_models(id);


--
-- Name: ext_assignment_history fk_ext_assignment_history_ext_assignments; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignment_history
    ADD CONSTRAINT fk_ext_assignment_history_ext_assignments FOREIGN KEY (ext_assignment_table_id) REFERENCES ml_app.ext_assignments(id);


--
-- Name: ext_assignment_history fk_ext_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignment_history
    ADD CONSTRAINT fk_ext_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: ext_assignment_history fk_ext_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignment_history
    ADD CONSTRAINT fk_ext_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: ext_gen_assignment_history fk_ext_gen_assignment_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignment_history
    ADD CONSTRAINT fk_ext_gen_assignment_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: ext_gen_assignment_history fk_ext_gen_assignment_history_ext_gen_assignments; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignment_history
    ADD CONSTRAINT fk_ext_gen_assignment_history_ext_gen_assignments FOREIGN KEY (ext_gen_assignment_table_id) REFERENCES ml_app.ext_gen_assignments(id);


--
-- Name: ext_gen_assignment_history fk_ext_gen_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignment_history
    ADD CONSTRAINT fk_ext_gen_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: ext_gen_assignment_history fk_ext_gen_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignment_history
    ADD CONSTRAINT fk_ext_gen_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: external_link_history fk_external_link_history_external_links; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_link_history
    ADD CONSTRAINT fk_external_link_history_external_links FOREIGN KEY (external_link_id) REFERENCES ml_app.external_links(id);


--
-- Name: general_selection_history fk_general_selection_history_general_selections; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.general_selection_history
    ADD CONSTRAINT fk_general_selection_history_general_selections FOREIGN KEY (general_selection_id) REFERENCES ml_app.general_selections(id);


--
-- Name: grit_assignment_history fk_grit_assignment_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignment_history
    ADD CONSTRAINT fk_grit_assignment_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: grit_assignment_history fk_grit_assignment_history_grit_assignments; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignment_history
    ADD CONSTRAINT fk_grit_assignment_history_grit_assignments FOREIGN KEY (grit_assignment_table_id) REFERENCES ml_app.grit_assignments(id);


--
-- Name: grit_assignment_history fk_grit_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignment_history
    ADD CONSTRAINT fk_grit_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: grit_assignment_history fk_grit_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignment_history
    ADD CONSTRAINT fk_grit_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: item_flag_history fk_item_flag_history_item_flags; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_history
    ADD CONSTRAINT fk_item_flag_history_item_flags FOREIGN KEY (item_flag_id) REFERENCES ml_app.item_flags(id);


--
-- Name: item_flag_name_history fk_item_flag_name_history_item_flag_names; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_name_history
    ADD CONSTRAINT fk_item_flag_name_history_item_flag_names FOREIGN KEY (item_flag_name_id) REFERENCES ml_app.item_flag_names(id);


--
-- Name: message_template_history fk_message_template_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_template_history
    ADD CONSTRAINT fk_message_template_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: message_template_history fk_message_template_history_message_templates; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_template_history
    ADD CONSTRAINT fk_message_template_history_message_templates FOREIGN KEY (message_template_id) REFERENCES ml_app.message_templates(id);


--
-- Name: new_test_history fk_new_test_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_test_history
    ADD CONSTRAINT fk_new_test_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: new_test_history fk_new_test_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_test_history
    ADD CONSTRAINT fk_new_test_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: new_test_history fk_new_test_history_new_tests; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_test_history
    ADD CONSTRAINT fk_new_test_history_new_tests FOREIGN KEY (new_test_table_id) REFERENCES ml_app.new_tests(id);


--
-- Name: new_test_history fk_new_test_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_test_history
    ADD CONSTRAINT fk_new_test_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_archived_file_history fk_nfs_store_archived_file_history_nfs_store_archived_files; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_file_history
    ADD CONSTRAINT fk_nfs_store_archived_file_history_nfs_store_archived_files FOREIGN KEY (nfs_store_archived_file_id) REFERENCES ml_app.nfs_store_archived_files(id);


--
-- Name: nfs_store_archived_file_history fk_nfs_store_archived_file_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_file_history
    ADD CONSTRAINT fk_nfs_store_archived_file_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_container_history fk_nfs_store_container_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_container_history
    ADD CONSTRAINT fk_nfs_store_container_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: nfs_store_container_history fk_nfs_store_container_history_nfs_store_containers; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_container_history
    ADD CONSTRAINT fk_nfs_store_container_history_nfs_store_containers FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: nfs_store_container_history fk_nfs_store_container_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_container_history
    ADD CONSTRAINT fk_nfs_store_container_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_filter_history fk_nfs_store_filter_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filter_history
    ADD CONSTRAINT fk_nfs_store_filter_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_filter_history fk_nfs_store_filter_history_nfs_store_filters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filter_history
    ADD CONSTRAINT fk_nfs_store_filter_history_nfs_store_filters FOREIGN KEY (nfs_store_filter_id) REFERENCES ml_app.nfs_store_filters(id);


--
-- Name: nfs_store_stored_file_history fk_nfs_store_stored_file_history_nfs_store_stored_files; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_file_history
    ADD CONSTRAINT fk_nfs_store_stored_file_history_nfs_store_stored_files FOREIGN KEY (nfs_store_stored_file_id) REFERENCES ml_app.nfs_store_stored_files(id);


--
-- Name: nfs_store_stored_file_history fk_nfs_store_stored_file_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_file_history
    ADD CONSTRAINT fk_nfs_store_stored_file_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: page_layout_history fk_page_layout_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layout_history
    ADD CONSTRAINT fk_page_layout_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: page_layout_history fk_page_layout_history_page_layouts; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layout_history
    ADD CONSTRAINT fk_page_layout_history_page_layouts FOREIGN KEY (page_layout_id) REFERENCES ml_app.page_layouts(id);


--
-- Name: player_contact_history fk_player_contact_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contact_history
    ADD CONSTRAINT fk_player_contact_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: player_contact_history fk_player_contact_history_player_contacts; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contact_history
    ADD CONSTRAINT fk_player_contact_history_player_contacts FOREIGN KEY (player_contact_id) REFERENCES ml_app.player_contacts(id);


--
-- Name: player_contact_history fk_player_contact_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contact_history
    ADD CONSTRAINT fk_player_contact_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: player_info_history fk_player_info_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_info_history
    ADD CONSTRAINT fk_player_info_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: player_info_history fk_player_info_history_player_infos; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_info_history
    ADD CONSTRAINT fk_player_info_history_player_infos FOREIGN KEY (player_info_id) REFERENCES ml_app.player_infos(id);


--
-- Name: player_info_history fk_player_info_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_info_history
    ADD CONSTRAINT fk_player_info_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: protocol_event_history fk_protocol_event_history_protocol_events; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_event_history
    ADD CONSTRAINT fk_protocol_event_history_protocol_events FOREIGN KEY (protocol_event_id) REFERENCES ml_app.protocol_events(id);


--
-- Name: protocol_history fk_protocol_history_protocols; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_history
    ADD CONSTRAINT fk_protocol_history_protocols FOREIGN KEY (protocol_id) REFERENCES ml_app.protocols(id);


--
-- Name: masters fk_rails_00b234154d; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.masters
    ADD CONSTRAINT fk_rails_00b234154d FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: app_configurations fk_rails_00f31a00c4; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configurations
    ADD CONSTRAINT fk_rails_00f31a00c4 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_filters fk_rails_0208c3b54d; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filters
    ADD CONSTRAINT fk_rails_0208c3b54d FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: external_identifier_history fk_rails_0210618434; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifier_history
    ADD CONSTRAINT fk_rails_0210618434 FOREIGN KEY (external_identifier_id) REFERENCES ml_app.external_identifiers(id);


--
-- Name: player_infos fk_rails_08e7f66647; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_infos
    ADD CONSTRAINT fk_rails_08e7f66647 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: user_action_logs fk_rails_08eec3f089; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_action_logs
    ADD CONSTRAINT fk_rails_08eec3f089 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: role_description_history fk_rails_0910ca20ea; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_description_history
    ADD CONSTRAINT fk_rails_0910ca20ea FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: protocol_events fk_rails_0a64e1160a; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_events
    ADD CONSTRAINT fk_rails_0a64e1160a FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_imports fk_rails_0ad81c489c; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_imports
    ADD CONSTRAINT fk_rails_0ad81c489c FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_containers fk_rails_0c84487284; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers
    ADD CONSTRAINT fk_rails_0c84487284 FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: nfs_store_imports fk_rails_0d30944d1b; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_imports
    ADD CONSTRAINT fk_rails_0d30944d1b FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: nfs_store_stored_files fk_rails_0de144234e; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_files
    ADD CONSTRAINT fk_rails_0de144234e FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: nfs_store_trash_actions fk_rails_0e2ecd8d43; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_trash_actions
    ADD CONSTRAINT fk_rails_0e2ecd8d43 FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: masters fk_rails_10869244dc; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.masters
    ADD CONSTRAINT fk_rails_10869244dc FOREIGN KEY (created_by_user_id) REFERENCES ml_app.users(id);


--
-- Name: users fk_rails_1694bfe639; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users
    ADD CONSTRAINT fk_rails_1694bfe639 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: activity_log_history fk_rails_16d57266f7; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_history
    ADD CONSTRAINT fk_rails_16d57266f7 FOREIGN KEY (activity_log_id) REFERENCES ml_app.activity_logs(id);


--
-- Name: user_roles fk_rails_174e058eb3; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_roles
    ADD CONSTRAINT fk_rails_174e058eb3 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: scantrons fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantrons
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test_exts fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_exts
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test_ext2s fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: ext_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_ext_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: ext_gen_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test1s fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1s
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test_2s fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test2s fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_player_infos fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_infos
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: new_tests fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_tests
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_new_tests fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_tests
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: bhs_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_bhs_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: sleep_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: grit_assignments fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: scantron_q2s fk_rails_1a7e2b01e0; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test1s fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1s
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: test_2s fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: test2s fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: new_tests fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_tests
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: bhs_assignments fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: sleep_assignments fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: grit_assignments fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignments
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: scantron_q2s fk_rails_1a7e2b01e0admin; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2s
    ADD CONSTRAINT fk_rails_1a7e2b01e0admin FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_stored_files fk_rails_1cc4562569; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_stored_files
    ADD CONSTRAINT fk_rails_1cc4562569 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: activity_log_player_contact_phones fk_rails_1d67a3e7f2; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phones
    ADD CONSTRAINT fk_rails_1d67a3e7f2 FOREIGN KEY (protocol_id) REFERENCES ml_app.protocols(id);


--
-- Name: config_library_history fk_rails_1ec40f248c; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_library_history
    ADD CONSTRAINT fk_rails_1ec40f248c FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: sub_processes fk_rails_1fc7475261; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_processes
    ADD CONSTRAINT fk_rails_1fc7475261 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: pro_infos fk_rails_20667815e3; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.pro_infos
    ADD CONSTRAINT fk_rails_20667815e3 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: item_flag_names fk_rails_22ccfd95e1; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flag_names
    ADD CONSTRAINT fk_rails_22ccfd95e1 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: player_infos fk_rails_23cd255bc6; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_infos
    ADD CONSTRAINT fk_rails_23cd255bc6 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_containers fk_rails_2708bd6a94; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers
    ADD CONSTRAINT fk_rails_2708bd6a94 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: nfs_store_downloads fk_rails_272f69e6af; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_downloads
    ADD CONSTRAINT fk_rails_272f69e6af FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: role_descriptions fk_rails_291bbea3bc; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_descriptions
    ADD CONSTRAINT fk_rails_291bbea3bc FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: nfs_store_archived_files fk_rails_2b59e23148; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_files
    ADD CONSTRAINT fk_rails_2b59e23148 FOREIGN KEY (nfs_store_stored_file_id) REFERENCES ml_app.nfs_store_stored_files(id);


--
-- Name: model_references fk_rails_2d8072edea; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.model_references
    ADD CONSTRAINT fk_rails_2d8072edea FOREIGN KEY (to_record_master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_player_contact_phones fk_rails_2de1cadfad; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phones
    ADD CONSTRAINT fk_rails_2de1cadfad FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: nfs_store_archived_files fk_rails_2eab578259; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_files
    ADD CONSTRAINT fk_rails_2eab578259 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_roles fk_rails_318345354e; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_roles
    ADD CONSTRAINT fk_rails_318345354e FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: admin_action_logs fk_rails_3389f178f6; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admin_action_logs
    ADD CONSTRAINT fk_rails_3389f178f6 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: page_layouts fk_rails_37a2f11066; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layouts
    ADD CONSTRAINT fk_rails_37a2f11066 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: message_notifications fk_rails_3a3553e146; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_notifications
    ADD CONSTRAINT fk_rails_3a3553e146 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: nfs_store_uploads fk_rails_3f5167a964; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_uploads
    ADD CONSTRAINT fk_rails_3f5167a964 FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: trackers fk_rails_447d125f63; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT fk_rails_447d125f63 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: scantrons fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantrons
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test_exts fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_exts
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test_ext2s fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2s
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: ext_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_ext_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: ext_gen_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.ext_gen_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test1s fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1s
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test_2s fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2s
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test2s fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2s
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_player_infos fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_infos
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: new_tests fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.new_tests
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_new_tests fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_tests
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: bhs_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.bhs_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: activity_log_bhs_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_bhs_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: sleep_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: grit_assignments fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.grit_assignments
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: scantron_q2s fk_rails_45205ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2s
    ADD CONSTRAINT fk_rails_45205ed085 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: role_description_history fk_rails_47581bba71; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_description_history
    ADD CONSTRAINT fk_rails_47581bba71 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: trackers fk_rails_47b051d356; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT fk_rails_47b051d356 FOREIGN KEY (sub_process_id) REFERENCES ml_app.sub_processes(id);


--
-- Name: addresses fk_rails_48c9e0c5a2; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.addresses
    ADD CONSTRAINT fk_rails_48c9e0c5a2 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: colleges fk_rails_49306e4f49; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.colleges
    ADD CONSTRAINT fk_rails_49306e4f49 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: model_references fk_rails_4bbf83b940; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.model_references
    ADD CONSTRAINT fk_rails_4bbf83b940 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: users_contact_infos fk_rails_4decdf690b; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users_contact_infos
    ADD CONSTRAINT fk_rails_4decdf690b FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: message_templates fk_rails_4fe5122ed4; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_templates
    ADD CONSTRAINT fk_rails_4fe5122ed4 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_uploads fk_rails_4ff6d28f98; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_uploads
    ADD CONSTRAINT fk_rails_4ff6d28f98 FOREIGN KEY (nfs_store_stored_file_id) REFERENCES ml_app.nfs_store_stored_files(id);


--
-- Name: exception_logs fk_rails_51ae125c4f; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.exception_logs
    ADD CONSTRAINT fk_rails_51ae125c4f FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: protocol_events fk_rails_564af80fb6; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocol_events
    ADD CONSTRAINT fk_rails_564af80fb6 FOREIGN KEY (sub_process_id) REFERENCES ml_app.sub_processes(id);


--
-- Name: external_identifier_history fk_rails_5b0628cf42; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifier_history
    ADD CONSTRAINT fk_rails_5b0628cf42 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: activity_log_player_contact_phones fk_rails_5ce1857310; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phones
    ADD CONSTRAINT fk_rails_5ce1857310 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: trackers fk_rails_623e0ca5ac; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT fk_rails_623e0ca5ac FOREIGN KEY (protocol_id) REFERENCES ml_app.protocols(id);


--
-- Name: nfs_store_user_file_actions fk_rails_639da31037; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_user_file_actions
    ADD CONSTRAINT fk_rails_639da31037 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: app_configurations fk_rails_647c63b069; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configurations
    ADD CONSTRAINT fk_rails_647c63b069 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: nfs_store_containers fk_rails_6a3d7bf39f; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers
    ADD CONSTRAINT fk_rails_6a3d7bf39f FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: users fk_rails_6a971dc818; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users
    ADD CONSTRAINT fk_rails_6a971dc818 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: protocols fk_rails_6de4fd560d; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocols
    ADD CONSTRAINT fk_rails_6de4fd560d FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: tracker_history fk_rails_6e050927c2; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT fk_rails_6e050927c2 FOREIGN KEY (tracker_id) REFERENCES ml_app.trackers(id);


--
-- Name: accuracy_scores fk_rails_70c17e88fd; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.accuracy_scores
    ADD CONSTRAINT fk_rails_70c17e88fd FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: external_identifiers fk_rails_7218113eac; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_identifiers
    ADD CONSTRAINT fk_rails_7218113eac FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: player_contacts fk_rails_72b1afe72f; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contacts
    ADD CONSTRAINT fk_rails_72b1afe72f FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_move_actions fk_rails_75138f1972; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_move_actions
    ADD CONSTRAINT fk_rails_75138f1972 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_filters fk_rails_776e17eafd; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filters
    ADD CONSTRAINT fk_rails_776e17eafd FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: users_contact_infos fk_rails_7808f5fdb3; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.users_contact_infos
    ADD CONSTRAINT fk_rails_7808f5fdb3 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: activity_log_ext_assignments fk_rails_78888ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_ext_assignments
    ADD CONSTRAINT fk_rails_78888ed085 FOREIGN KEY (ext_assignment_id) REFERENCES ml_app.ext_assignments(id);


--
-- Name: activity_log_player_infos fk_rails_78888ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_infos
    ADD CONSTRAINT fk_rails_78888ed085 FOREIGN KEY (player_info_id) REFERENCES ml_app.player_infos(id);


--
-- Name: activity_log_new_tests fk_rails_78888ed085; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_new_tests
    ADD CONSTRAINT fk_rails_78888ed085 FOREIGN KEY (new_test_id) REFERENCES ml_app.new_tests(id);


--
-- Name: sub_processes fk_rails_7c10a99849; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_processes
    ADD CONSTRAINT fk_rails_7c10a99849 FOREIGN KEY (protocol_id) REFERENCES ml_app.protocols(id);


--
-- Name: user_access_controls fk_rails_8108e25f83; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_controls
    ADD CONSTRAINT fk_rails_8108e25f83 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: tracker_history fk_rails_83aa075398; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT fk_rails_83aa075398 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: pro_infos fk_rails_86cecb1e36; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.pro_infos
    ADD CONSTRAINT fk_rails_86cecb1e36 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: config_library_history fk_rails_88664b466b; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_library_history
    ADD CONSTRAINT fk_rails_88664b466b FOREIGN KEY (config_library_id) REFERENCES ml_app.config_libraries(id);


--
-- Name: app_types fk_rails_8be93bcf4b; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_types
    ADD CONSTRAINT fk_rails_8be93bcf4b FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: tracker_history fk_rails_9513fd1c35; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT fk_rails_9513fd1c35 FOREIGN KEY (sub_process_id) REFERENCES ml_app.sub_processes(id);


--
-- Name: sage_assignments fk_rails_971255ec2c; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_assignments
    ADD CONSTRAINT fk_rails_971255ec2c FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: protocols fk_rails_990daa5f76; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.protocols
    ADD CONSTRAINT fk_rails_990daa5f76 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: role_description_history fk_rails_9d88430088; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_description_history
    ADD CONSTRAINT fk_rails_9d88430088 FOREIGN KEY (role_description_id) REFERENCES ml_app.role_descriptions(id);


--
-- Name: tracker_history fk_rails_9e92bdfe65; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT fk_rails_9e92bdfe65 FOREIGN KEY (protocol_event_id) REFERENCES ml_app.protocol_events(id);


--
-- Name: tracker_history fk_rails_9f5797d684; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT fk_rails_9f5797d684 FOREIGN KEY (protocol_id) REFERENCES ml_app.protocols(id);


--
-- Name: addresses fk_rails_a44670b00a; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.addresses
    ADD CONSTRAINT fk_rails_a44670b00a FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: model_references fk_rails_a4eb981c4a; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.model_references
    ADD CONSTRAINT fk_rails_a4eb981c4a FOREIGN KEY (from_record_master_id) REFERENCES ml_app.masters(id);


--
-- Name: user_preferences fk_rails_a69bfcfd81; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_preferences
    ADD CONSTRAINT fk_rails_a69bfcfd81 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_history fk_rails_af2f6ffc55; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_history
    ADD CONSTRAINT fk_rails_af2f6ffc55 FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: activity_log_player_contact_phones fk_rails_b071294797; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.activity_log_player_contact_phones
    ADD CONSTRAINT fk_rails_b071294797 FOREIGN KEY (player_contact_id) REFERENCES ml_app.player_contacts(id);


--
-- Name: colleges fk_rails_b0a6220067; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.colleges
    ADD CONSTRAINT fk_rails_b0a6220067 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: reports fk_rails_b138baacff; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.reports
    ADD CONSTRAINT fk_rails_b138baacff FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: imports fk_rails_b1e2154c26; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.imports
    ADD CONSTRAINT fk_rails_b1e2154c26 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_roles fk_rails_b345649dfe; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_roles
    ADD CONSTRAINT fk_rails_b345649dfe FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: trackers fk_rails_b822840dc1; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT fk_rails_b822840dc1 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: trackers fk_rails_bb6af37155; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT fk_rails_bb6af37155 FOREIGN KEY (protocol_event_id) REFERENCES ml_app.protocol_events(id);


--
-- Name: imports_model_generators fk_rails_bd9f10d2c7; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.imports_model_generators
    ADD CONSTRAINT fk_rails_bd9f10d2c7 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_uploads fk_rails_bdb308087e; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_uploads
    ADD CONSTRAINT fk_rails_bdb308087e FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: admins fk_rails_c05d151591; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.admins
    ADD CONSTRAINT fk_rails_c05d151591 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_move_actions fk_rails_c1ea9a5fd9; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_move_actions
    ADD CONSTRAINT fk_rails_c1ea9a5fd9 FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: item_flags fk_rails_c2d5bb8930; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flags
    ADD CONSTRAINT fk_rails_c2d5bb8930 FOREIGN KEY (item_flag_name_id) REFERENCES ml_app.item_flag_names(id);


--
-- Name: nfs_store_user_file_actions fk_rails_c423dc1802; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_user_file_actions
    ADD CONSTRAINT fk_rails_c423dc1802 FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: tracker_history fk_rails_c55341c576; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT fk_rails_c55341c576 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: exception_logs fk_rails_c720bf523c; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.exception_logs
    ADD CONSTRAINT fk_rails_c720bf523c FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_action_logs fk_rails_c94bae872a; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_action_logs
    ADD CONSTRAINT fk_rails_c94bae872a FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: masters fk_rails_c9d7977c0c; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.masters
    ADD CONSTRAINT fk_rails_c9d7977c0c FOREIGN KEY (pro_info_id) REFERENCES ml_app.pro_infos(id);


--
-- Name: nfs_store_downloads fk_rails_cd756b42dd; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_downloads
    ADD CONSTRAINT fk_rails_cd756b42dd FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_action_logs fk_rails_cfc9dc539f; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_action_logs
    ADD CONSTRAINT fk_rails_cfc9dc539f FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: message_notifications fk_rails_d3566ee56d; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_notifications
    ADD CONSTRAINT fk_rails_d3566ee56d FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: player_contacts fk_rails_d3c0ddde90; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.player_contacts
    ADD CONSTRAINT fk_rails_d3c0ddde90 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: nfs_store_container_history fk_rails_d6593e5c9d; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_container_history
    ADD CONSTRAINT fk_rails_d6593e5c9d FOREIGN KEY (created_by_user_id) REFERENCES ml_app.users(id);


--
-- Name: config_libraries fk_rails_da3ba4f850; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.config_libraries
    ADD CONSTRAINT fk_rails_da3ba4f850 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: item_flags fk_rails_dce5169cfd; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.item_flags
    ADD CONSTRAINT fk_rails_dce5169cfd FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: nfs_store_trash_actions fk_rails_de41d50f67; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_trash_actions
    ADD CONSTRAINT fk_rails_de41d50f67 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: dynamic_models fk_rails_deec8fcb38; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.dynamic_models
    ADD CONSTRAINT fk_rails_deec8fcb38 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_containers fk_rails_e01d928507; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers
    ADD CONSTRAINT fk_rails_e01d928507 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: sage_assignments fk_rails_e3c559b547; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_assignments
    ADD CONSTRAINT fk_rails_e3c559b547 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: page_layouts fk_rails_e410af4010; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.page_layouts
    ADD CONSTRAINT fk_rails_e410af4010 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: sage_assignments fk_rails_ebab73db27; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sage_assignments
    ADD CONSTRAINT fk_rails_ebab73db27 FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: external_links fk_rails_ebf3863277; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.external_links
    ADD CONSTRAINT fk_rails_ebf3863277 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_archived_files fk_rails_ecfa3cb151; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_archived_files
    ADD CONSTRAINT fk_rails_ecfa3cb151 FOREIGN KEY (nfs_store_container_id) REFERENCES ml_app.nfs_store_containers(id);


--
-- Name: nfs_store_containers fk_rails_ee25fc60fa; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_containers
    ADD CONSTRAINT fk_rails_ee25fc60fa FOREIGN KEY (created_by_user_id) REFERENCES ml_app.users(id);


--
-- Name: app_configurations fk_rails_f0ac516fff; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.app_configurations
    ADD CONSTRAINT fk_rails_f0ac516fff FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: nfs_store_filters fk_rails_f547361daa; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.nfs_store_filters
    ADD CONSTRAINT fk_rails_f547361daa FOREIGN KEY (app_type_id) REFERENCES ml_app.app_types(id);


--
-- Name: general_selections fk_rails_f62500107f; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.general_selections
    ADD CONSTRAINT fk_rails_f62500107f FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: role_descriptions fk_rails_f646dbe30d; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.role_descriptions
    ADD CONSTRAINT fk_rails_f646dbe30d FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: message_notifications fk_rails_fa6dbd15de; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.message_notifications
    ADD CONSTRAINT fk_rails_fa6dbd15de FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: report_history fk_report_history_reports; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.report_history
    ADD CONSTRAINT fk_report_history_reports FOREIGN KEY (report_id) REFERENCES ml_app.reports(id);


--
-- Name: scantron_history fk_scantron_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_history
    ADD CONSTRAINT fk_scantron_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: scantron_history fk_scantron_history_scantrons; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_history
    ADD CONSTRAINT fk_scantron_history_scantrons FOREIGN KEY (scantron_table_id) REFERENCES ml_app.scantrons(id);


--
-- Name: scantron_history fk_scantron_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_history
    ADD CONSTRAINT fk_scantron_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: scantron_q2_history fk_scantron_q2_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2_history
    ADD CONSTRAINT fk_scantron_q2_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: scantron_q2_history fk_scantron_q2_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2_history
    ADD CONSTRAINT fk_scantron_q2_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: scantron_q2_history fk_scantron_q2_history_scantron_q2s; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2_history
    ADD CONSTRAINT fk_scantron_q2_history_scantron_q2s FOREIGN KEY (scantron_q2_table_id) REFERENCES ml_app.scantron_q2s(id);


--
-- Name: scantron_q2_history fk_scantron_q2_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.scantron_q2_history
    ADD CONSTRAINT fk_scantron_q2_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: sleep_assignment_history fk_sleep_assignment_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignment_history
    ADD CONSTRAINT fk_sleep_assignment_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: sleep_assignment_history fk_sleep_assignment_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignment_history
    ADD CONSTRAINT fk_sleep_assignment_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: sleep_assignment_history fk_sleep_assignment_history_sleep_assignments; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignment_history
    ADD CONSTRAINT fk_sleep_assignment_history_sleep_assignments FOREIGN KEY (sleep_assignment_table_id) REFERENCES ml_app.sleep_assignments(id);


--
-- Name: sleep_assignment_history fk_sleep_assignment_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sleep_assignment_history
    ADD CONSTRAINT fk_sleep_assignment_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: sub_process_history fk_sub_process_history_sub_processes; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.sub_process_history
    ADD CONSTRAINT fk_sub_process_history_sub_processes FOREIGN KEY (sub_process_id) REFERENCES ml_app.sub_processes(id);


--
-- Name: test1_history fk_test1_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1_history
    ADD CONSTRAINT fk_test1_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: test1_history fk_test1_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1_history
    ADD CONSTRAINT fk_test1_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test1_history fk_test1_history_test1s; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1_history
    ADD CONSTRAINT fk_test1_history_test1s FOREIGN KEY (test1_table_id) REFERENCES ml_app.test1s(id);


--
-- Name: test1_history fk_test1_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test1_history
    ADD CONSTRAINT fk_test1_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test2_history fk_test2_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2_history
    ADD CONSTRAINT fk_test2_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: test2_history fk_test2_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2_history
    ADD CONSTRAINT fk_test2_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test2_history fk_test2_history_test2s; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2_history
    ADD CONSTRAINT fk_test2_history_test2s FOREIGN KEY (test2_table_id) REFERENCES ml_app.test2s(id);


--
-- Name: test2_history fk_test2_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test2_history
    ADD CONSTRAINT fk_test2_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test_2_history fk_test_2_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2_history
    ADD CONSTRAINT fk_test_2_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: test_2_history fk_test_2_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2_history
    ADD CONSTRAINT fk_test_2_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test_2_history fk_test_2_history_test_2s; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2_history
    ADD CONSTRAINT fk_test_2_history_test_2s FOREIGN KEY (test_2_table_id) REFERENCES ml_app.test_2s(id);


--
-- Name: test_2_history fk_test_2_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_2_history
    ADD CONSTRAINT fk_test_2_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test_ext2_history fk_test_ext2_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2_history
    ADD CONSTRAINT fk_test_ext2_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test_ext2_history fk_test_ext2_history_test_ext2s; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2_history
    ADD CONSTRAINT fk_test_ext2_history_test_ext2s FOREIGN KEY (test_ext2_table_id) REFERENCES ml_app.test_ext2s(id);


--
-- Name: test_ext2_history fk_test_ext2_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext2_history
    ADD CONSTRAINT fk_test_ext2_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: test_ext_history fk_test_ext_history_masters; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext_history
    ADD CONSTRAINT fk_test_ext_history_masters FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: test_ext_history fk_test_ext_history_test_exts; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext_history
    ADD CONSTRAINT fk_test_ext_history_test_exts FOREIGN KEY (test_ext_table_id) REFERENCES ml_app.test_exts(id);


--
-- Name: test_ext_history fk_test_ext_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.test_ext_history
    ADD CONSTRAINT fk_test_ext_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_access_control_history fk_user_access_control_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_control_history
    ADD CONSTRAINT fk_user_access_control_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: user_access_control_history fk_user_access_control_history_user_access_controls; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_access_control_history
    ADD CONSTRAINT fk_user_access_control_history_user_access_controls FOREIGN KEY (user_access_control_id) REFERENCES ml_app.user_access_controls(id);


--
-- Name: user_authorization_history fk_user_authorization_history_user_authorizations; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_authorization_history
    ADD CONSTRAINT fk_user_authorization_history_user_authorizations FOREIGN KEY (user_authorization_id) REFERENCES ml_app.user_authorizations(id);


--
-- Name: user_history fk_user_history_users; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_history
    ADD CONSTRAINT fk_user_history_users FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: user_role_history fk_user_role_history_admins; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_role_history
    ADD CONSTRAINT fk_user_role_history_admins FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: user_role_history fk_user_role_history_user_roles; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.user_role_history
    ADD CONSTRAINT fk_user_role_history_user_roles FOREIGN KEY (user_role_id) REFERENCES ml_app.user_roles(id);


--
-- Name: rc_cis rc_cis_master_id_fkey; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.rc_cis
    ADD CONSTRAINT rc_cis_master_id_fkey FOREIGN KEY (master_id) REFERENCES ml_app.masters(id);


--
-- Name: tracker_history unique_master_protocol_tracker_id; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT unique_master_protocol_tracker_id FOREIGN KEY (master_id, protocol_id, tracker_id) REFERENCES ml_app.trackers(master_id, protocol_id, id);


--
-- Name: trackers valid_protocol_sub_process; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT valid_protocol_sub_process FOREIGN KEY (protocol_id, sub_process_id) REFERENCES ml_app.sub_processes(protocol_id, id) MATCH FULL;


--
-- Name: tracker_history valid_protocol_sub_process; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT valid_protocol_sub_process FOREIGN KEY (protocol_id, sub_process_id) REFERENCES ml_app.sub_processes(protocol_id, id) MATCH FULL;


--
-- Name: trackers valid_sub_process_event; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.trackers
    ADD CONSTRAINT valid_sub_process_event FOREIGN KEY (sub_process_id, protocol_event_id) REFERENCES ml_app.protocol_events(sub_process_id, id);


--
-- Name: tracker_history valid_sub_process_event; Type: FK CONSTRAINT; Schema: ml_app; Owner: -
--

ALTER TABLE ONLY ml_app.tracker_history
    ADD CONSTRAINT valid_sub_process_event FOREIGN KEY (sub_process_id, protocol_event_id) REFERENCES ml_app.protocol_events(sub_process_id, id);


--
-- Name: datadic_variables fk_rails_029902d3e3; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variables
    ADD CONSTRAINT fk_rails_029902d3e3 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: datadic_variable_history fk_rails_143e8a7c25; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variable_history
    ADD CONSTRAINT fk_rails_143e8a7c25 FOREIGN KEY (equivalent_to_id) REFERENCES ref_data.datadic_variables(id);


--
-- Name: redcap_data_dictionaries fk_rails_16cfa46407; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionaries
    ADD CONSTRAINT fk_rails_16cfa46407 FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: redcap_data_dictionary_history fk_rails_25f366a78c; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionary_history
    ADD CONSTRAINT fk_rails_25f366a78c FOREIGN KEY (redcap_data_dictionary_id) REFERENCES ref_data.redcap_data_dictionaries(id);


--
-- Name: redcap_data_collection_instruments fk_rails_2aa7bf926a; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instruments
    ADD CONSTRAINT fk_rails_2aa7bf926a FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: redcap_client_requests fk_rails_32285f308d; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_client_requests
    ADD CONSTRAINT fk_rails_32285f308d FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: datadic_variables fk_rails_34eadb0aee; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variables
    ADD CONSTRAINT fk_rails_34eadb0aee FOREIGN KEY (equivalent_to_id) REFERENCES ref_data.datadic_variables(id);


--
-- Name: redcap_project_users fk_rails_38d0954914; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_users
    ADD CONSTRAINT fk_rails_38d0954914 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: data_variable_package_history fk_rails_3935f6da80; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_history
    ADD CONSTRAINT fk_rails_3935f6da80 FOREIGN KEY (data_variable_package_id) REFERENCES ref_data.data_variable_packages(id);


--
-- Name: redcap_user_status_rec_history fk_rails_409869f35a; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_user_status_rec_history
    ADD CONSTRAINT fk_rails_409869f35a FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: datadic_choice_history fk_rails_42389740a0; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choice_history
    ADD CONSTRAINT fk_rails_42389740a0 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: data_variable_package_var_history fk_rails_45489901da; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_var_history
    ADD CONSTRAINT fk_rails_45489901da FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: data_variable_package_history fk_rails_45489901da; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_history
    ADD CONSTRAINT fk_rails_45489901da FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: redcap_data_dictionaries fk_rails_4766ebe50f; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionaries
    ADD CONSTRAINT fk_rails_4766ebe50f FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: datadic_variable_history fk_rails_5302a77293; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variable_history
    ADD CONSTRAINT fk_rails_5302a77293 FOREIGN KEY (datadic_variable_id) REFERENCES ref_data.datadic_variables(id);


--
-- Name: datadic_variables fk_rails_5578e37430; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variables
    ADD CONSTRAINT fk_rails_5578e37430 FOREIGN KEY (redcap_data_dictionary_id) REFERENCES ref_data.redcap_data_dictionaries(id);


--
-- Name: datadic_choice_history fk_rails_63103b7cf7; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choice_history
    ADD CONSTRAINT fk_rails_63103b7cf7 FOREIGN KEY (datadic_choice_id) REFERENCES ref_data.datadic_choices(id);


--
-- Name: datadic_choices fk_rails_67ca4d7e1f; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choices
    ADD CONSTRAINT fk_rails_67ca4d7e1f FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: datadic_variable_history fk_rails_6ba6ab1e1f; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variable_history
    ADD CONSTRAINT fk_rails_6ba6ab1e1f FOREIGN KEY (redcap_data_dictionary_id) REFERENCES ref_data.redcap_data_dictionaries(id);


--
-- Name: redcap_data_collection_instrument_history fk_rails_6c93846f69; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instrument_history
    ADD CONSTRAINT fk_rails_6c93846f69 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: redcap_project_user_history fk_rails_7ba2e90d7d; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_user_history
    ADD CONSTRAINT fk_rails_7ba2e90d7d FOREIGN KEY (redcap_project_user_id) REFERENCES ref_data.redcap_project_users(id);


--
-- Name: redcap_project_user_history fk_rails_89af917107; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_user_history
    ADD CONSTRAINT fk_rails_89af917107 FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: datadic_variables fk_rails_8dc5a059ee; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variables
    ADD CONSTRAINT fk_rails_8dc5a059ee FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: redcap_data_dictionary_history fk_rails_9a6eca0fe7; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionary_history
    ADD CONSTRAINT fk_rails_9a6eca0fe7 FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: redcap_user_status_recs fk_rails_9c8b8f3760; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_user_status_recs
    ADD CONSTRAINT fk_rails_9c8b8f3760 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: redcap_project_user_history fk_rails_a0bf0fdddb; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_user_history
    ADD CONSTRAINT fk_rails_a0bf0fdddb FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: redcap_project_users fk_rails_a6952cc0e8; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_users
    ADD CONSTRAINT fk_rails_a6952cc0e8 FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: redcap_project_admin_history fk_rails_a7610f4fec; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_project_admin_history
    ADD CONSTRAINT fk_rails_a7610f4fec FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: data_variable_package_vars fk_rails_a89c82cd43; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_package_vars
    ADD CONSTRAINT fk_rails_a89c82cd43 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: data_variable_packages fk_rails_a89c82cd43; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.data_variable_packages
    ADD CONSTRAINT fk_rails_a89c82cd43 FOREIGN KEY (user_id) REFERENCES ml_app.users(id);


--
-- Name: redcap_data_collection_instrument_history fk_rails_cb0b57b6c1; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instrument_history
    ADD CONSTRAINT fk_rails_cb0b57b6c1 FOREIGN KEY (redcap_project_admin_id) REFERENCES ref_data.redcap_project_admins(id);


--
-- Name: datadic_choice_history fk_rails_cb8a1e9d10; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choice_history
    ADD CONSTRAINT fk_rails_cb8a1e9d10 FOREIGN KEY (redcap_data_dictionary_id) REFERENCES ref_data.redcap_data_dictionaries(id);


--
-- Name: redcap_data_collection_instrument_history fk_rails_ce6075441d; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_collection_instrument_history
    ADD CONSTRAINT fk_rails_ce6075441d FOREIGN KEY (redcap_data_collection_instrument_id) REFERENCES ref_data.redcap_data_collection_instruments(id);


--
-- Name: datadic_variable_history fk_rails_d7e89fcbde; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_variable_history
    ADD CONSTRAINT fk_rails_d7e89fcbde FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- Name: datadic_choices fk_rails_f5497a3583; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.datadic_choices
    ADD CONSTRAINT fk_rails_f5497a3583 FOREIGN KEY (redcap_data_dictionary_id) REFERENCES ref_data.redcap_data_dictionaries(id);


--
-- Name: redcap_data_dictionary_history fk_rails_fffede9aa7; Type: FK CONSTRAINT; Schema: ref_data; Owner: -
--

ALTER TABLE ONLY ref_data.redcap_data_dictionary_history
    ADD CONSTRAINT fk_rails_fffede9aa7 FOREIGN KEY (admin_id) REFERENCES ml_app.admins(id);


--
-- PostgreSQL database dump complete
--

commit;
