# frozen_string_literal: true

# Tests for NfsStore::Manage::Filesystem.clean_path
#
# Purpose
# -------
# `Filesystem.clean_path` is the chokepoint used to normalise every user-supplied
# path that eventually contributes to a filesystem location before any file is
# read, written, moved or streamed via `send_file`. It is invoked from:
#   * NfsStore::Upload.find_upload                  (upload `relative_path`)
#   * NfsStore::HandlesContainerFile#clean_path     (before_validation on rows)
#   * NfsStore::MoveAndRename                       (user-supplied new_path)
#   * NfsStore::Archive::Mounter                    (archive sub-paths)
#   * NfsStore::Manage::ContainerFile               (path resolution)
#   * Filesystem.nfs_store_path                     (final assembled path)
#
# Previously there were no direct unit tests for this method. This file adds:
#
#   1. Characterisation tests covering the documented/observed behaviour
#      (blank/`.`/trailing-slash/lexical normalisation). These should pass on
#      the existing code.
#
#   2. Path-traversal & absolute-path tests that demonstrate the current code
#      silently normalises but does **not** reject `..` segments or leading `/`.
#      These tests are intentionally failing on the current implementation and
#      are the red phase of TDD work to harden the filestore against path
#      traversal attacks (no GitHub issue — security hardening).

require 'rails_helper'

RSpec.describe NfsStore::Manage::Filesystem, type: :model do
  describe '.clean_path' do
    # -------------------------------------------------------------------
    # Characterisation: behaviour that must remain unchanged
    # -------------------------------------------------------------------
    context 'when given blank or no-op input' do
      it 'returns nil for nil' do
        expect(described_class.clean_path(nil)).to be_nil
      end

      it 'returns nil for an empty string' do
        expect(described_class.clean_path('')).to be_nil
      end

      it 'returns nil for the current-directory marker "."' do
        expect(described_class.clean_path('.')).to be_nil
      end
    end

    context 'when given a benign relative path' do
      it 'returns a simple single segment unchanged' do
        expect(described_class.clean_path('reports')).to eq('reports')
      end

      it 'returns a nested path unchanged' do
        expect(described_class.clean_path('reports/2024/q1')).to eq('reports/2024/q1')
      end

      it 'collapses interior "./" segments' do
        expect(described_class.clean_path('reports/./2024')).to eq('reports/2024')
      end

      it 'collapses interior ".." segments that remain within the relative root' do
        expect(described_class.clean_path('reports/2024/../2025')).to eq('reports/2025')
      end

      it 'strips a single trailing slash' do
        # Pathname#cleanpath collapses trailing slashes
        expect(described_class.clean_path('reports/')).to eq('reports')
      end
    end

    # -------------------------------------------------------------------
    # SECURITY (RED): inputs that must be rejected to prevent traversal
    # outside the assembled container root before send_file.
    # -------------------------------------------------------------------
    #
    # These cases currently pass through clean_path with only lexical
    # normalisation, so the resulting string still carries an escape
    # sequence (leading `..`) or an absolute prefix. When that value is
    # subsequently fed into `File.join(parts) -> Pathname#cleanpath` by
    # Filesystem.nfs_store_path, the final filesystem path can escape the
    # container's directory.
    #
    # The expected behaviour after hardening is that clean_path raises
    # FsException::Action for any of these inputs (or another
    # explicit rejection mechanism — adjust the matcher when the green
    # phase chooses the exact contract).

    context 'when given a path that escapes the relative root (SECURITY)' do
      it 'rejects a leading "../" segment' do
        expect { described_class.clean_path('../etc/passwd') }
          .to raise_error(FsException::Action)
      end

      it 'rejects "../" alone' do
        expect { described_class.clean_path('..') }
          .to raise_error(FsException::Action)
      end

      it 'rejects a deeper traversal sequence' do
        expect { described_class.clean_path('../../../etc/passwd') }
          .to raise_error(FsException::Action)
      end

      it 'rejects a path that collapses to a leading ".."' do
        # "foo/../../bar" -> Pathname#cleanpath -> "../bar"
        expect { described_class.clean_path('foo/../../bar') }
          .to raise_error(FsException::Action)
      end
    end

    context 'when given an absolute path (SECURITY)' do
      it 'rejects a Unix-style absolute path' do
        expect { described_class.clean_path('/etc/passwd') }
          .to raise_error(FsException::Action)
      end

      it 'rejects an absolute path that points inside the nfs root' do
        # Even paths that "look" legitimate must not bypass the
        # container-relative join logic.
        expect { described_class.clean_path('/var/nfs_store/anything') }
          .to raise_error(FsException::Action)
      end
    end

    context 'when given a path containing a NUL byte (SECURITY)' do
      it 'rejects embedded NUL bytes' do
        expect { described_class.clean_path("reports\x00/safe") }
          .to raise_error(FsException::Action)
      end
    end
  end

  # -------------------------------------------------------------------
  # END-TO-END EXPLOIT PROOF-OF-CONCEPT (SECURITY)
  # -------------------------------------------------------------------
  #
  # This block demonstrates that the path-assembly logic used by
  # NfsStore (Filesystem.nfs_store_path -> File.join(parts) ->
  # Filesystem.clean_path) collapses traversal sequences AFTER joining
  # them with the container root, yielding an absolute filesystem path
  # OUTSIDE the container directory.
  #
  # The downloads_controller#show flow ultimately passes the result of
  # this assembly to Rails' `send_file`, so an attacker who can supply
  # `path` (e.g. via the chunked upload `relative_path` parameter, or
  # via MoveAndRename's `new_path`) can cause arbitrary local files to
  # be served back through the application.
  #
  # The POC plants a "secret" file on disk, simulates the container
  # root that nfs_store_path would have assembled, and shows that the
  # `clean_path`-normalised result points at the planted secret and
  # that the file is readable via the resulting path.
  describe 'path traversal proof-of-concept' do
    let(:sandbox)   { Dir.mktmpdir('nfs_store_traversal_poc') }
    let(:secret_dir)    { File.join(sandbox, 'secrets') }
    let(:secret_name)   { 'PRIVATE.txt' }
    let(:secret_path)   { File.join(secret_dir, secret_name) }
    let(:secret_body)   { "TOP SECRET payload #{SecureRandom.hex(8)}" }

    # Simulate the directory layout that Filesystem.nfs_store_path would
    # have built up to the container root: <sandbox>/mount/app/containers/<cid>
    let(:container_root) { File.join(sandbox, 'mount', 'app-type-42', 'containers', '00001') }

    before do
      FileUtils.mkdir_p container_root
      FileUtils.mkdir_p secret_dir
      File.write(secret_path, secret_body)
    end

    after { FileUtils.remove_entry(sandbox) if File.exist?(sandbox) }

    it 'lets a malicious `path` escape the container root and read an unrelated file' do
      # Attacker-controlled values, mirroring what ChunkController accepts
      # as `relative_path` + the uploaded file_name.
      malicious_relative_path = '../../../../secrets'   # five levels up from container_root would overshoot; cleanpath caps at sandbox
      malicious_file_name     = secret_name

      # Reproduce the exact assembly that Filesystem.nfs_store_path performs
      # at app/models/nfs_store/manage/filesystem.rb (parts << path; parts << file_name; File.join; clean_path).
      parts = [container_root, malicious_relative_path, malicious_file_name]
      assembled = File.join(parts)
      cleaned   = described_class.clean_path(assembled)

      # 1. clean_path silently normalises the traversal instead of rejecting it.
      expect(cleaned).not_to start_with(container_root),
                             "EXPECT vulnerable: cleaned path should escape container_root but did not. cleaned=#{cleaned.inspect}"

      # 2. The cleaned path resolves to the planted secret file.
      expect(File.expand_path(cleaned)).to eq(File.expand_path(secret_path))

      # 3. send_file would happily stream this file: it exists and is readable.
      expect(File).to exist(cleaned)
      expect(Pathname.new(cleaned)).to be_readable
      expect(File.read(cleaned)).to eq(secret_body)
    end
  end
end
