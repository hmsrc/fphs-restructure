module ItemFlagsHelper
  def flag_edit_form_id
    "item-flag-edit-form-#{@master.id}-#{@flag_item_type}-#{@flag_item.id}-#{@id}"
  end

  def flag_edit_form_hash(extras = {})
    extras.merge({ url: "/masters/#{@master.id}/#{@flag_item.item_type}/#{@flag_item.id}/item_flags",
                   action: :post,
                   remote: true,
                   html: {
                     'data-result-target' => "#item-flag-#{@master.id}-#{@flag_item_type}-#{@flag_item.id}-#{@id}",
                     'data-template' => 'item-flags-result-template'
                   } })
  end

  def item_flag_path
    "#{url_for([@master, @flag_item])}/item_flags/#{@id}"
  end

  def flag_inline_cancel_button
    cancel_href = if @id
                    item_flag_path
                  else
                    "#{item_flag_path}cancel"
                  end

    "<a class=\"show-entity show-item-flag pull-right glyphicon glyphicon-remove-sign\" title=\"cancel\" href=\"#{cancel_href}\" data-remote=\"true\" data-item-flag-id=\"#{@id}\" data-result-target=\"#item-flag-#{@master.id}-#{@flag_item.id}-#{@id}\" data-template=\"item-flag-result-template\"></a>".html_safe
  end

  def item_flags_array(item_type = nil)
    item_type ||= @flag_item_type

    Classification::ItemFlagName.selector_collection(item_type:)
  end

  #
  # Generate options for select using result from #item_flags_array
  # @param [Array{Hash}] array generated from #item_flags_array
  # @param [Symbol|String] value_attr - attribute to use as value for choice
  # @param [Symbol|String] name_attr - attribute to use as display name for choice
  # @param [Hash] options - options, such as selected: 'value', disabled: [<values>]
  # @return [String] HTML option tags
  def item_flags_options(array, value_attr, name_attr, options)
    options_for_select(array.map { |r| r.values_at(name_attr.to_s, value_attr.to_s) }, **options)
  end

  def flags_selected(item = nil)
    item ||= @flag_item
    s = item.item_flags.map { |i| i.item_flag_name_id }
    logger.info "Selected #{s}"
    s
  end
end
