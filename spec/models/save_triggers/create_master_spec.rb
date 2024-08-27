require 'rails_helper'

AlNameGenTestCr = 'Gen Test ELT Save'

RSpec.describe SaveTriggers::CreateMaster, type: :model do
  include ModelSupport
  include ActivityLogSupport

  def last_msid
    last_msid = (Master.order(msid: :desc).first.msid || 123) + 1
  end

  before :example do
    SetupHelper.setup_al_player_contact_phones
    SetupHelper.setup_al_gen_tests AlNameGenTestCr, 'elt_save_test', 'player_contact'
    create_user
    @master = create_master
    @player_contact = @master.player_contacts.create! data: '(617)123-1234 b', rec_type: :phone, rank: 10
    @al = create_item master: @master
    add_reference_def_to(@al, [player_contacts: { from: 'this', add: 'many' }])
    expect(@al.master_id).to eq @master.id
    setup_access @al.resource_name, resource_type: :activity_log_type, access: :create, user: @user
  end

  it 'creates a master record after saving the current one' do
    pn = random_phone_number

    config = {
      with: { msid: last_msid }
    }
    @trigger = SaveTriggers::CreateMaster.new(config, @al)
    @trigger.perform

    expect(Master.last).to eq @al.save_trigger_results['created_master']
  end
end
