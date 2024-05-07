class AddItemIndexToTrackerHistory < ActiveRecord::Migration[6.1]
  def change
    add_index(:tracker_history, %i[item_type item_id], if_not_exists: true, name: 'index_tracker_history_on_item_type_id')
  end
end
