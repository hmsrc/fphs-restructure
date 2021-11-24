# frozen_string_literal: true

module ReportResults
  module ReportsListHelper
    #
    # Generate the full table cell markup
    def report_list_result_cell(field_num, col_content)
      orig_col_content = col_content
      col_name = report_column_name(field_num)

      if @view_options.show_all_booleans_as_checkboxed && [true, false].include?(col_content)
        @show_as[col_name] ||= 'checkbox'
      end

      table_name = @result_tables[field_num]

      cell = ReportResults::ReportsListResultCell.new(table_name, col_content, col_name, @col_tags[col_name], @show_as[col_name],
                                                       selection_options_handler_for(table_name))
      col_tag = cell.html_tag
      col_content = cell.view_content

      if col_tag.present?
        col_tag_start = "<#{col_tag} class=\"#{cell.expandable? ? 'expandable' : ''}\">"
        col_tag_end = "</#{col_tag}>"
      end

      extra_classes = ''
      extra_classes += 'report-el-object-id' if col_name == 'id'
      extra_classes += @col_classes[col_name] if @col_classes[col_name]
      if orig_col_content.instance_of?(Date) || orig_col_content.instance_of?(Time)
        # Keep an original version of the time, since the tag content will be updated with user preferences
        time_attr = "data-time-orig-val=\"#{orig_col_content}\""
      end

      res = <<~END_HTML
        <div data-col-type="#{col_name}"
            data-col-table="#{table_name}"
            data-col-var-type="#{orig_col_content.class.name}" #{time_attr}
            class="report-list-el #{extra_classes}">#{col_tag_start}#{col_content}#{col_tag_end}</div>
      END_HTML

      res.html_safe
    end


  end
end
