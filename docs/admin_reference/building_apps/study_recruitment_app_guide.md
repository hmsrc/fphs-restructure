# Building a Study Recruitment App: Admin Guide

This guide walks through the common configuration patterns for building a study recruitment
application using ReStructure. The example uses a generalized "study recruitment" domain
that demonstrates workflows, status tracking, sequential screening steps, automated
transitions, and role-based access controls.

All configuration described here is performed via the **admin panel** — no hand-edited YAML
or custom Ruby code is required.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Create the App Type](#2-create-the-app-type)
3. [Set Up App Configurations](#3-set-up-app-configurations)
4. [Create an External Identifier](#4-create-an-external-identifier)
5. [Embedded Dynamic Models via `config_trigger` and `default_embed_resource`](#5-embedded-dynamic-models-via-config_trigger-and-default_embed_resource)
6. [Create a Tracker Activity Log](#6-create-a-tracker-activity-log)
7. [Define Tracker Extra Log Types](#7-define-tracker-extra-log-types)
8. [Create a Screening Activity Log](#8-create-a-screening-activity-log)
9. [Define Screening Extra Log Types](#9-define-screening-extra-log-types)
10. [Configure User Access Controls](#10-configure-user-access-controls)
11. [Summary of Patterns](#11-summary-of-patterns)

---

## 1. Overview

A study recruitment app typically involves:

- **Recruitment tracking** — a timeline of participant status changes (scheduled call,
  contacted, screened, eligible, enrolled, opted out)
- **Multi-step screening** — a sequential workflow guiding screeners through questions,
  assessments, and consent
- **Automated transitions** — saving one step auto-creates status entries or advances
  to the next step
- **Embedded data forms** — larger data collection forms embedded inside workflow steps
- **Role-based access** — coordinators manage scheduling; screeners conduct interviews

The building blocks used:

| Component | Purpose |
|---|---|
| **App Type** | Top-level container for the application |
| **App Configurations** | Runtime settings (UI layout, default panels) |
| **External Identifier** | Unique participant ID (e.g., Study ID) |
| **Dynamic Model** | Data tables for participant-specific data |
| **Activity Log** | Workflow engine — each log tracks a set of activities |
| **Extra Log Types** | Named activity types within an activity log |
| **User Access Controls (UACs)** | Role- and user-based permissions |

---

## 2. Create the App Type

Navigate to **Admin > App Types** and create a new app type.

| Field | Value |
|---|---|
| **Name** | `study-recruitment` |
| **Label** | Study Recruitment |
| **Default Schema** | `study_rec` |

The app type is the top-level container. All activity logs, dynamic models, external
identifiers, and user access controls are scoped to this app type.

---

## 3. Set Up App Configurations

Navigate to **Admin > App Configurations** and add entries for the new app type.

### Hide the Default Search Navbar

Prevents participants from being searched by the default player name search.

| Field | Value |
|---|---|
| **App Type** | study-recruitment |
| **Name** | `hide navbar search` |
| **Value** | `true` |

### Auto-Open Panels on Master Record Load

Automatically expands the details panel and the tracker tab when a participant record opens.

| Field | Value |
|---|---|
| **App Type** | study-recruitment |
| **Name** | `open panels` |
| **Value** | `details, activity_log__study_rec_ids` |

### Create Master Record With External Identifier

When creating a new master record, automatically prompt for the study ID.

| Field | Value |
|---|---|
| **App Type** | study-recruitment |
| **Name** | `create master with` |
| **Value** | `study_rec_id_number` |

### Show External IDs in Search Results

Display the study ID in the master record header.

| Field | Value |
|---|---|
| **App Type** | study-recruitment |
| **Name** | `show ids in master result` |
| **Value** | `study_rec_ids` |

---

## 4. Create an External Identifier

Navigate to **Admin > External Identifiers** and create a new entry. This gives each
participant a unique study ID.

| Field | Value |
|---|---|
| **Name** | `study_rec_ids` |
| **Label** | Study Recruitment ID |
| **External ID Attribute** | `study_rec_id` |
| **Min ID** | `10000` |
| **Max ID** | `99999` |
| **Schema Name** | `study_rec` |
| **Category** | `study-recruitment` |

This creates a `study_rec_ids` table with auto-incrementing IDs in the specified range.

---

## 5. Embedded Dynamic Models via `config_trigger` and `default_embed_resource`

When an activity log step needs its own data collection form, the recommended approach
is to let the system auto-create the dynamic model using `config_trigger` and
`default_embed_resource`, then edit the resulting dynamic model to add fields and logic.

### How It Works

1. In the screening activity log options, add `config_trigger` and
   `embed: default_embed_resource` to the extra log type that needs embedded data
2. When the activity log configuration is saved, `config_trigger.on_define.create_defaults`
   automatically:
   - Creates a dynamic model with a table name derived from the activity log's category,
     process name, and extra log type (e.g., `study_recruitment_screening_initial_contact_recs`)
   - Creates UACs for the specified role
3. Navigate to **Admin > Dynamic Models**, find the auto-created model, and edit its
   **Options** to add the fields, field_options, and show_if logic you need

### The `config_trigger` Definition

Define a reusable anchor in the screening activity log's `_definitions`:

```yaml
_definitions:
  config_trigger_create_embed: &create_embed
    on_define:
      create_defaults:
        user_access_control:
          role_name: screener
        embed:
          fields:
            - select_still_interested
            - select_continue_now
            - callback_date
            - callback_time
            - notes
```

Then reference it in the extra log type:

```yaml
initial_contact:
  config_trigger: *create_embed
  embed: default_embed_resource
  # ... rest of the extra log type options
```

### Editing the Auto-Created Dynamic Model

After saving the activity log, navigate to the auto-created dynamic model and set its
**Options** to define field behavior:

> **Important: Field Naming Convention for Dropdowns**
>
> Fields that should render as dropdown selectors must have names starting with
> `select_` (e.g., `select_still_interested`, `select_age_eligible`).
> This prefix tells the UI framework to render the field as a `<select>` element
> using the `alt_options` values. Fields without this prefix render as plain text inputs.

```yaml
default:
  label: Initial Call Data
  fields:
    - select_still_interested
    - select_continue_now
    - callback_date
    - callback_time
    - notes

  field_options:
    select_still_interested:
      edit_as:
        alt_options:
          - 'yes'
          - 'no'
          - 'not sure'
    select_continue_now:
      edit_as:
        alt_options:
          - 'yes'
          - 'no - schedule callback'

  show_if:
    callback_date:
      select_continue_now: 'no - schedule callback'
    callback_time:
      select_continue_now: 'no - schedule callback'
```

> **Note**: You do not need to specify `_db_columns` — the system automatically creates
> the database columns based on the fields listed in `config_trigger.on_define.create_defaults.embed.fields`.

### Key Pattern: `show_if` — Conditional Field Visibility

The `show_if` option controls which fields are visible based on other field values.
In the example above, `callback_date` and `callback_time` only appear when the screener
selects "no - schedule callback" for `select_continue_now`.

The `show_if` syntax supports:

- **Simple match**: `field_name: value` — show when field equals value
- **List match**: `field_name: [val1, val2]` — show when field is any listed value
- **Logic blocks**: `all:`, `any:`, `not_all:`, `not_any:` — combine multiple conditions
- **Current mode**: `current_mode: edit` — show only in edit mode

```yaml
show_if:
  # Simple: show callback_date when select_continue_now is 'no - schedule callback'
  callback_date:
    select_continue_now: 'no - schedule callback'

  # Logic block: show consent_notes in edit mode AND when select_consented is 'yes'
  consent_notes:
    all:
      select_consented: 'yes'
      current_mode: edit

  # Any: show follow_up_notes when EITHER condition is met
  follow_up_notes:
    any:
      select_result: follow up
      select_activity: schedule follow up
```

---

## 6. Create a Tracker Activity Log

The **Tracker** is the central status board for a participant. Each entry represents a
status change or milestone. Many entries are auto-created by save triggers from other
activity logs.

Navigate to **Admin > Activity Logs** and create a new entry.

| Field | Value |
|---|---|
| **Name** | `Study Recruitment Tracker` |
| **Item Type** | `study_rec_id` |
| **Schema Name** | `study_rec` |
| **Category** | `study-recruitment` |
| **Action When Attribute** | `created_at` |

The **Options** field will contain all the extra log type definitions. Start with the
structural settings:

```yaml
_configurations:
  use_current_version: true

_definitions:
  # Reusable anchors for conditions
  never_create: &never_create
    never: true

  enabled_if: &enabled_if
    always: true

_default:
  view_options: &view_options_default
    hide_unless_creatable: true
  showable_if: *enabled_if
  creatable_if: *enabled_if
  editable_if: *enabled_if
```

### Key Pattern: `_definitions` — Reusable YAML Anchors

Define anchors in `_definitions` to avoid repeating the same conditions. Reference
them later using `*anchor_name`:

```yaml
_definitions:
  never_create: &never_create
    never: true

# Later, in an extra log type:
started_screening:
  creatable_if: *never_create
```

### Key Pattern: `_default` — Shared Defaults

Options defined under `_default` are automatically applied to all extra log types.
Individual extra log types can override any default value.

### Key Pattern: `view_options.hide_unless_creatable`

Setting `hide_unless_creatable: true` causes the add button for an extra log type to
be hidden when its `creatable_if` conditions are not met. This keeps the tracker tidy
by only showing relevant actions.

---

## 7. Define Tracker Extra Log Types

Each extra log type in the tracker options represents a different status or action.
Add these to the **Options** field of the tracker activity log.

### 7.1 Schedule Call — A Manually Created Entry

This is a standard user-initiated tracker entry with editable fields.

```yaml
schedule_call:
  label: Schedule Call

  fields:
    - select_who
    - follow_up_when
    - notes

  field_options:
    select_who:
      edit_as:
        field_type: select_user_with_role_screener

  caption_before:
    all_fields:
      show_caption: |
        Call scheduled for **{{follow_up_when::date}}**.
        View the **Screening** tab for the screening script.
    select_who: Who will perform the call?
    follow_up_when: Scheduled date
    notes: Additional notes for the screener

  creatable_if:
    <<: *enabled_if
    has_not_created_activity: screening_started

  showable_if:
    always: true
```

### Key Pattern: `caption_before` — Instructional Text

Captions display contextual text before specific fields or before all fields.
They support Handlebars substitutions (`{{field_name}}`) and markdown formatting.

```yaml
caption_before:
  # Before all fields — different text for show vs edit mode
  all_fields:
    show_caption: |
      Read-only summary text with **markdown** and {{field_substitutions}}.
    edit_caption: |
      Instructions shown when editing.

  # Before a specific field
  select_who: Who will perform the call?

  # Before the submit button
  submit: |
    Click Save to confirm scheduling.
```

The `show_caption` / `edit_caption` variants display different text depending on whether
the record is being viewed (show mode) or edited (edit mode). Use `new_caption` to show
text only when creating a new record.

### Key Pattern: `creatable_if` with Activity Conditions

The `has_created_activity` and `has_not_created_activity` shortcuts check whether
specific tracker entries exist for this participant. This enables workflow gating:

```yaml
# Allow creation only if no screening has started
creatable_if:
  has_not_created_activity: screening_started

# Allow creation only after opt-in AND not yet completed
creatable_if:
  has_created_activity: opted_in
  has_not_created_activity:
    - screening_complete
    - opted_out

# Never allow manual creation (auto-created by save_trigger)
creatable_if:
  never: true
```

### 7.2 Screening Started — Auto-Created Status Entry

This entry is created automatically when a screening step triggers it. Users cannot
create it manually.

```yaml
screening_started:
  label: Screening Started

  creatable_if: *never_create

  caption_before:
    all_fields: |
      The participant started the screening process.

  showable_if:
    always: true
```

### 7.3 Screening Complete — Auto-Created Status Entry

```yaml
screening_complete:
  label: Screening Complete

  creatable_if: *never_create

  caption_before:
    all_fields: |
      The screening has been completed.

  showable_if:
    always: true
```

### 7.4 Eligible — Auto-Created

```yaml
eligible:
  label: Eligible

  creatable_if: *never_create

  caption_before:
    all_fields: |
      The participant was found to be eligible based on screening.

  showable_if:
    always: true
```

### 7.5 Enrolled — Manually Created After Eligibility

```yaml
enrolled:
  label: Participant Enrolled

  fields:

  caption_before:
    all_fields:
      edit_caption: |
        The participant has completed screening. Click **Save**
        to enroll the participant in the study.
      show_caption: |
        The participant has been enrolled in the study.

  creatable_if:
    <<: *enabled_if
    has_created_activity: eligible
    has_not_created_activity:
      - enrolled
      - opted_out
      - ineligible

  showable_if:
    always: true
```

### 7.6 Opted Out — Exit Status

```yaml
opted_out:
  label: Exit (Opt-Out)

  fields:
    - notes

  caption_before:
    all_fields: |
      The participant opted out.

  creatable_if:
    <<: *enabled_if
    has_not_created_activity:
      - opted_out
      - ineligible
      - enrolled

  showable_if:
    always: true
```

---

## 8. Create a Screening Activity Log

The **Screening** activity log manages the multi-step screening workflow. Each step
is an extra log type that guides the screener through the interview.

Navigate to **Admin > Activity Logs** and create a new entry.

| Field | Value |
|---|---|
| **Name** | `Study Recruitment Screening` |
| **Item Type** | `study_rec_id` (same as tracker) |
| **Process Name** | `screening` |
| **Schema Name** | `study_rec` |
| **Category** | `study-recruitment` |
| **Action When Attribute** | `created_at` |

**Important**: The `Item Type` must match the tracker's item type so both activity logs
reference the same external identifier record. The `Process Name` differentiates this
log from the tracker (which has no process name).

Set the **Options** field to define the screening steps.

---

## 9. Define Screening Extra Log Types

### 9.1 Initial Contact — First Step with Embedded Data

```yaml
_configurations:
  use_current_version: true

_definitions:
  never_create: &never_create
    never: true

  config_trigger_create_embed: &create_embed
    on_define:
      create_defaults:
        user_access_control:
          role_name: screener
        embed:
          fields:
            - select_still_interested
            - select_continue_now
            - callback_date
            - callback_time
            - notes

_default:
  showable_if:
    always: true
  editable_if:
    always: true

initial_contact:
  label: Initial Contact

  fields:
    - select_who
    - notes

  field_options:
    select_who:
      edit_as:
        field_type: select_user_with_role_screener

  config_trigger: *create_embed
  embed: default_embed_resource

  caption_before:
    select_who: Screener performing the call
    notes: Notes about the initial contact

  save_trigger:
    on_create:
      create_reference:
        - activity_log__study_rec_ids:
            force_create: true
            in: master
            with:
              extra_log_type: screening_started

  save_action:
    on_save:
      create_next_creatable: true
```

### Key Pattern: `embed` — Embedded Dynamic Models

The `embed` option directly embeds a dynamic model form inside the activity log step.
When the user opens the step, the embedded model's fields appear inline.

```yaml
# Use default_embed_resource to automatically embed the DM created by config_trigger
embed: default_embed_resource

# Or embed any specific dynamic model by resource name
embed: dynamic_model__some_other_model

# Or use the expanded form for more control
embed:
  resource_name: dynamic_model__some_other_model
  resource_id: some_field_id
```

When using `default_embed_resource`, the system looks up the dynamic model named by
the activity log's category, process name, and extra log type — for example,
an `initial_contact` step in a `screening` process with category `study-recruitment`
auto-resolves to `dynamic_model__study_recruitment_screening_initial_contact_recs`.

The embedded model displays its own `fields`, `show_if`, and `field_options` as defined
in its own options. The parent activity log step simply provides the container.

### Key Pattern: `save_trigger.create_reference` — Cross-Log Automation

The `save_trigger` with `create_reference` automatically creates an entry in another
activity log when this step is saved. This is how screening steps add status entries
to the tracker.

```yaml
save_trigger:
  on_create:
    create_reference:
      # Create a "Screening Started" entry in the tracker
      - activity_log__study_rec_ids:
          force_create: true
          in: master
          with:
            extra_log_type: screening_started

      # Create a "Contacted" entry only if select_still_interested is 'yes'
      - activity_log__study_rec_ids:
          force_create: true
          in: master
          with:
            extra_log_type: contacted
          if:
            all:
              embedded_item:
                select_still_interested: 'yes'
```

Key properties:

| Property | Description |
|---|---|
| `model_name` | Resource name of the target (e.g., `activity_log__study_rec_ids`) |
| `in: master` | Create the reference in the same master record |
| `force_create: true` | Bypass UAC checks (the trigger runs as the system) |
| `with:` | Set field values on the created record |
| `if:` | Conditional — only create if conditions are met |

### Key Pattern: `save_action.create_next_creatable` — Auto-Advance

After saving a step, `create_next_creatable` automatically opens the next available
step (the first step whose `creatable_if` conditions are satisfied).

```yaml
save_action:
  on_save:
    create_next_creatable: true
```

> **Note**: `on_save` is shorthand that applies to both create and update events.
> If you need different behavior, use `on_create` and `on_update` separately — these
> override `on_save` for their respective events.

This creates a smooth workflow where the screener saves one step and the next step
automatically opens, without manual button clicking.

### 9.2 Eligibility Questions — Sequential Step

```yaml
eligibility_questions:
  label: Eligibility Questions

  fields:
    - select_age_eligible
    - select_health_eligible
    - select_location_eligible
    - notes

  field_options:
    select_age_eligible:
      edit_as:
        alt_options:
          - 'yes'
          - 'no'
    select_health_eligible:
      edit_as:
        alt_options:
          - 'yes'
          - 'no'
          - 'needs review'
    select_location_eligible:
      edit_as:
        alt_options:
          - 'yes'
          - 'no'

  caption_before:
    all_fields:
      edit_caption: |
        Complete the eligibility questions below.
      show_caption: |
        Eligibility responses have been recorded.

  creatable_if:
    has_created_activity: initial_contact

  save_action:
    on_save:
      create_next_creatable: true
```

### 9.3 Consent — With Conditional Trigger

```yaml
consent:
  label: Consent

  fields:
    - select_consented
    - consent_date
    - notes

  field_options:
    select_consented:
      edit_as:
        alt_options:
          - 'yes'
          - 'no'

  caption_before:
    select_consented: Did the participant give verbal consent to continue?
    consent_date: Date consent was given

  show_if:
    consent_date:
      select_consented: 'yes'

  creatable_if:
    has_created_activity: eligibility_questions

  save_action:
    on_save:
      create_next_creatable: true
```

### 9.4 Finalize — Terminal Step with Multiple Triggers

```yaml
finalize:
  label: Finalize Screening

  fields:
    - select_result
    - notes

  field_options:
    select_result:
      edit_as:
        alt_options:
          - 'eligible'
          - 'ineligible'
          - 'needs further review'

  caption_before:
    all_fields:
      edit_caption: |
        Review the screening results and finalize.
      show_caption: |
        The screening has been finalized.

  creatable_if:
    has_created_activity: consent

  editable_if:
    never: true

  save_trigger:
    on_create:
      create_reference:
        # Always create a "Screening Complete" tracker entry
        - activity_log__study_rec_ids:
            force_create: true
            in: master
            with:
              extra_log_type: screening_complete

        # Create "Eligible" only if result is 'eligible'
        - activity_log__study_rec_ids:
            force_create: true
            in: master
            with:
              extra_log_type: eligible
            if:
              all:
                this:
                  select_result: 'eligible'

        # Create "Ineligible" if result is 'ineligible'
        - activity_log__study_rec_ids:
            force_create: true
            in: master
            with:
              extra_log_type: ineligible
            if:
              all:
                this:
                  select_result: 'ineligible'

  save_action:
    on_save:
      refresh_panel:
        - value: activity_log__study_rec_ids
```

### Key Pattern: `save_action.refresh_panel` — Refresh Another Tab

After saving the finalize step, `refresh_panel` forces the tracker tab to reload
so the user immediately sees the auto-created status entries.

```yaml
save_action:
  on_save:
    refresh_panel:
      - value: activity_log__study_rec_ids
```

### Key Pattern: `editable_if: never` — Lock After Creation

Setting `editable_if: never: true` prevents the record from being edited after creation.
This is used for finalization steps where the data should be locked once submitted.

> **Note**: If `editable_if` is not defined at all, the default behavior is to only allow
> editing the most recently created item in the list. Use `always: true` to make all items
> always editable.

---

## 10. Configure User Access Controls

Access to activity logs and their extra log types is controlled through User Access
Controls (UACs). Each UAC grants a specific access level for a specific resource.

### UAC Resource Types

| Resource Type | Resource Name Pattern | Controls |
|---|---|---|
| `table` | `activity_log__study_rec_ids` | Access to the entire tracker log |
| `activity_log_type` | `activity_log__study_rec_id__schedule_call` | Access to a specific extra log type |
| `table` | `dynamic_model__study_recruitment_screening_initial_contact_recs` | Access to an embedded dynamic model |
| `table` | `trackers` | Required for any role with create/update access |
| `general` | `app_type` | Access to the app type itself |

### Access Levels

| Level | Description |
|---|---|
| `read` | View records only |
| `create` | Create and view records |
| `edit` | Create, view, and edit records |

### Example: Coordinator Role

Navigate to **Admin > User Access Controls** and create entries for the coordinator role.

| Resource Type | Resource Name | Role | Access |
|---|---|---|---|
| `general` | `app_type` | coordinator | `read` |
| `table` | `trackers` | coordinator | `create` |
| `table` | `tracker_histories` | coordinator | `read` |
| `table` | `activity_log__study_rec_ids` | coordinator | `create` |
| `activity_log_type` | `activity_log__study_rec_id__schedule_call` | coordinator | `create` |
| `activity_log_type` | `activity_log__study_rec_id__enrolled` | coordinator | `create` |
| `activity_log_type` | `activity_log__study_rec_id__opted_out` | coordinator | `create` |
| `activity_log_type` | `activity_log__study_rec_id__screening_started` | coordinator | `read` |
| `activity_log_type` | `activity_log__study_rec_id__screening_complete` | coordinator | `read` |
| `activity_log_type` | `activity_log__study_rec_id__eligible` | coordinator | `read` |

### Example: Screener Role

| Resource Type | Resource Name | Role | Access |
|---|---|---|---|
| `general` | `app_type` | screener | `read` |
| `table` | `trackers` | screener | `create` |
| `table` | `tracker_histories` | screener | `read` |
| `table` | `activity_log__study_rec_id_screenings` | screener | `read` |
| `activity_log_type` | `activity_log__study_rec_id_screening__initial_contact` | screener | `create` |
| `activity_log_type` | `activity_log__study_rec_id_screening__eligibility_questions` | screener | `create` |
| `activity_log_type` | `activity_log__study_rec_id_screening__consent` | screener | `create` |
| `activity_log_type` | `activity_log__study_rec_id_screening__finalize` | screener | `create` |
| `table` | `dynamic_model__study_recruitment_screening_initial_contact_recs` | screener | `create` |

> **Note**: The embedded dynamic model UAC
> (`dynamic_model__study_recruitment_screening_initial_contact_recs`) is auto-created
> by `config_trigger.on_define.create_defaults` when the screening activity log is saved.
> You only need to manually create it if the auto-created access level needs adjustment.

### Assigning Roles to Users

Navigate to **Admin > User Roles** and assign roles to individual users.

| User | App Type | Role |
|---|---|---|
| <coordinator@example.com> | study-recruitment | coordinator |
| <screener@example.com> | study-recruitment | screener |

---

## 11. Summary of Patterns

### Pattern Reference

| Pattern | Where Used | Purpose |
|---|---|---|
| `_definitions` + YAML anchors | Options top level | DRY reusable conditions |
| `_default` | Options top level | Shared defaults for all extra log types |
| `extra_log_type` key | Under options | Define a named activity step |
| `label` | Extra log type | Display name and add-button text |
| `fields` | Extra log type | Which fields to show |
| `caption_before` | Extra log type | Instructional text with markdown + Handlebars |
| `show_if` | Extra log type | Conditional field visibility |
| `field_options` | Extra log type | Per-field config (dropdowns, defaults, validation) |
| `creatable_if` | Extra log type | When the add button is available |
| `editable_if` | Extra log type | When editing is allowed |
| `showable_if` | Extra log type | When the entry is visible |
| `embed` | Extra log type | Embed a dynamic model form (`default_embed_resource` or explicit name) |
| `config_trigger` | Extra log type / `_definitions` | Auto-create dynamic models and UACs on save |
| `save_trigger.create_reference` | Extra log type | Auto-create records in other logs |
| `save_action.create_next_creatable` | Extra log type | Auto-advance to next step |
| `save_action.refresh_panel` | Extra log type | Refresh another tab after save |
| `view_options.hide_unless_creatable` | `_default` or extra log type | Hide add button when not available |
| `has_created_activity` | `creatable_if` conditions | Gate on prior activity existence |
| `has_not_created_activity` | `creatable_if` conditions | Gate on prior activity absence |
| `never: true` | `creatable_if` / `editable_if` | Prevent manual creation/editing |
| UAC `role_name` + `resource_type` | User Access Controls | Role-based permissions per resource |

### Workflow Summary

```
Coordinator: Schedule Call (tracker)
    ↓
Screener: Initial Contact (screening, embeds dynamic model)
    → save_trigger → creates "Screening Started" in tracker
    → save_action → auto-opens Eligibility Questions
    ↓
Screener: Eligibility Questions (screening)
    → save_action → auto-opens Consent
    ↓
Screener: Consent (screening)
    → save_action → auto-opens Finalize
    ↓
Screener: Finalize (screening, locked after creation)
    → save_trigger → creates "Screening Complete" in tracker
    → save_trigger → creates "Eligible" or "Ineligible" in tracker (conditional)
    → save_action → refreshes tracker panel
    ↓
Coordinator: Enrolled / Opted Out (tracker, manual)
```
