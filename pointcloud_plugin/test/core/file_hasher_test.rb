# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

require_relative '../../core/file_hasher'

module PointCloudPlugin
  module Core
    class FileHasherTest < Minitest::Test
      def setup
        @tmpdir = Dir.mktmpdir('file-hasher-test')
      end

      def teardown
        Dir.glob(File.join(@tmpdir, '*')).each { |path| File.delete(path) }
        Dir.rmdir(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
      rescue StandardError
        nil
      end

      def test_signature_includes_hash_for_small_file
        path = File.join(@tmpdir, 'small.bin')
        File.binwrite(path, 'abc123')

        signature = FileHasher.signature_for(path)

        refute_nil signature
        assert_equal 'small.bin', signature['name']
        assert_equal 6, signature['size']
        assert_in_delta File.mtime(path).to_f, signature['mtime'], 1.0
        assert signature.key?('hash')
        refute signature.key?('leading_bytes')
        refute signature.key?('trailing_bytes')
      end

      def test_signatures_match_using_samples
        path = File.join(@tmpdir, 'large.bin')
        File.binwrite(path, '0123456789' * 32)

        hasher = FileHasher.new(path, sample_bytes: 8)
        signature = hasher.signature

        refute_nil signature
        refute signature.key?('hash')
        assert signature.key?('leading_bytes')
        assert signature.key?('trailing_bytes')

        duplicate = signature.dup
        assert FileHasher.signatures_match?(signature, duplicate)

        duplicate['trailing_bytes'] = FileHasher.encode('changed')
        refute FileHasher.signatures_match?(signature, duplicate)
      end

      def test_signatures_do_not_match_when_hash_presence_differs
        path = File.join(@tmpdir, 'mixed.bin')
        File.binwrite(path, 'a' * 150)

        hashed = FileHasher.signature_for(path, sample_bytes: 80)
        sampled = FileHasher.signature_for(path, sample_bytes: 32)

        refute FileHasher.signatures_match?(hashed, sampled)
      end

      def test_signatures_do_not_match_when_sample_presence_differs
        path = File.join(@tmpdir, 'sampled.bin')
        File.binwrite(path, '0123456789' * 64)

        signature = FileHasher.signature_for(path, sample_bytes: 16)

        missing_leading = signature.dup
        missing_leading.delete('leading_bytes')
        refute FileHasher.signatures_match?(signature, missing_leading)

        missing_trailing = signature.dup
        missing_trailing.delete('trailing_bytes')
        refute FileHasher.signatures_match?(signature, missing_trailing)
      end
    end
  end
end
