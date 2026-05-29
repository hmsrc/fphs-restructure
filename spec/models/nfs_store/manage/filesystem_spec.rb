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
end
