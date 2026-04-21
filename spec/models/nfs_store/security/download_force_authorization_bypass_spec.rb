# frozen_string_literal: true

# Security regression coverage for nfs_store download authorization.
#
# These examples intentionally document current vulnerable behavior: passing
# force: true to retrieve_file_from skips the action-level authorization check
# (download_files), while still allowing retrieval when container access exists.

require 'rails_helper'

RSpec.describe NfsStore::Download, type: :model do
  include PlayerContactSupport
  include ModelSupport
  include NfsStoreSupport

  before(:each) do
    setup_nfs_store
    setup_container_and_al
    setup_default_filters

    upload_file('force-bypass.txt', 'top secret test content')
    @stored_file = @container.stored_files.last

    setup_access :download_files, resource_type: :general, access: nil, user: @user
    @user.clear_has_access_to!
    @container.current_user = @user
  end

  it 'blocks retrieval when download action authorization is enforced' do
    expect(@user.can?(:download_files)).to be_nil

    download = NfsStore::Download.new(container: @container, activity_log: @activity_log)
    download.current_user = @user

    expect do
      download.retrieve_file_from(@stored_file.id, :stored_file, for_action: :download)
    end.to raise_error(FsException::NoAccess)
  end

  it 'retrieves the same file when force bypass is used' do
    expect(@user.can?(:download_files)).to be_nil

    download = NfsStore::Download.new(container: @container, activity_log: @activity_log)
    download.current_user = @user

    retrieved_path = download.retrieve_file_from(
      @stored_file.id,
      :stored_file,
      for_action: :download,
      force: true
    )

    expect(retrieved_path).to be_present
    expect(File.exist?(retrieved_path)).to be true
  end
end