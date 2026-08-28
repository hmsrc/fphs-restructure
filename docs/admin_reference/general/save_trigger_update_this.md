# `update_this`

## Update the Current Record

Update fields on the current record when this trigger fires. Commonly used in `before_save` to set computed values before the save completes. `update_this` is commonly used
with before_save (so computed values are set before the save completes)
but works with any save_trigger event.

```yaml
!defs(save_triggers_update_this_options_defs.yaml)
```

### Attributes

#### `with`

A hash specifying each field to be updated with a value. `with` fields take precedence over `with_result:` fields when both set the same attribute.

# !defs(save_triggers_with_attribute_values_defs.yaml)

#### `with_result`

# !defs(save_triggers_with_result_attribute_values_defs.yaml)

#### `force_not_editable_save`

When set to `true`, this allows the update to succeed even if the item is set as not_editable.

#### `force_not_valid`

When set to `true`, this allows the update to succeed even if `valid_if` checks fail.

### Lifecycle Hooks

See: [trigger lifecycle hooks](save_trigger.md#lifecycle-hooks)

### Pattern 1: Update the current item's own attributes

`embedded_item:` (nested within `with:`) updates the item's embedded item at the same time.

```yaml
!defs(save_triggers_update_this_pattern_1_basic_defs.yaml)
```

### Pattern 2: Map attributes from a related item using with_result

```yaml
!defs(save_triggers_update_this_pattern_2_with_result_defs.yaml)
```
