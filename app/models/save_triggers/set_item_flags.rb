# frozen_string_literal: true

class SaveTriggers::SetItemFlags < SaveTriggers::SaveTriggersBase
  def self.config_def(if_extras: {})
    # [
    #   {
    #       if: if_extras,
    #       first: 'set flags on the first matching reference with this configuration, specifying {update: return_result}',
    #       force_not_editable_save: 'true allows the update to succeed even if the referenced item is set as not_editable',
    #       flags: 'list of flag name ids or names'
    #   }
    # ]
  end

  def initialize(config, item)
    super

    @model_defs = config
  end

  def perform
    @model_defs = [@model_defs] unless @model_defs.is_a? Array

    @model_defs.each do |config|
      flag_list = []

      # We calculate the conditional if inside each item, rather than relying
      # on the outer processing in ActivityLogOptions#calc_save_trigger_if
      if config[:if]
        ca = ConditionalActions.new config[:if], @item
        next unless ca.calc_action_if
      end

      config[:flags].each do |def_val|
        if def_val.is_a? Hash
          ca = ConditionalActions.new def_val, @item
          res = ca.get_this_val
        else
          res = FieldDefaults.calculate_default @item, def_val
        end
        flag_list << res
      end

      @item.transaction do
        ca = ConditionalActions.new config[:first], @item
        res = ca.get_this_val
        raise FphsException, "No reference found to set flags on: #{config[:first]&.keys}" unless res

        # Convert flag names to ids
        if flag_list.first.is_a? String
          flag_list = Classification::ItemFlagName.available_to_item(res).where(name: flag_list).ids
        end

        curr_user = @item.current_user || @item.user
        res.current_user = curr_user
        fs = config[:force_not_editable_save]
        res.force_save! if fs
        ItemFlag.set_flags flag_list, res, curr_user, force_save: fs
      end
    end
  end
end
