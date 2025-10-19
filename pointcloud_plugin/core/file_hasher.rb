# frozen_string_literal: true

require 'base64'
require 'digest'

module PointCloudPlugin
  module Core
    # Computes lightweight file signatures suitable for cache validation.
    class FileHasher
      DEFAULT_SAMPLE_BYTES = 64 * 1024
      MTIME_TOLERANCE = 1.0

      attr_reader :path, :sample_bytes

      def initialize(path, sample_bytes: DEFAULT_SAMPLE_BYTES)
        @path = path
        @sample_bytes = sample_bytes.to_i.positive? ? sample_bytes.to_i : DEFAULT_SAMPLE_BYTES
      end

      def signature
        self.class.signature_for(path, sample_bytes: sample_bytes)
      end

      def matches_manifest?(manifest_signature)
        current_signature = signature
        self.class.signatures_match?(manifest_signature, current_signature)
      end

      def self.signature_for(path, sample_bytes: DEFAULT_SAMPLE_BYTES)
        return unless path && File.exist?(path)

        stat = File.stat(path)
        size = stat.size
        signature = {
          'name' => File.basename(path),
          'size' => size,
          'mtime' => stat.mtime.to_f
        }

        if size <= sample_bytes * 2
          signature['hash'] = Digest::SHA256.file(path).hexdigest
        else
          leading, trailing = sample_edges(path, sample_bytes, size)
          signature['leading_bytes'] = encode(leading) unless leading.empty?
          signature['trailing_bytes'] = encode(trailing) unless trailing.empty?
        end

        signature
      rescue Errno::ENOENT
        nil
      end

      def self.signatures_match?(expected, actual)
        return false unless expected.is_a?(Hash) && actual.is_a?(Hash)

        return false unless expected['name'].to_s == actual['name'].to_s
        return false unless expected['size'].to_i == actual['size'].to_i

        expected_mtime = expected['mtime']
        actual_mtime = actual['mtime']
        return false unless mtimes_close?(expected_mtime, actual_mtime)

        expected_hash = expected['hash']
        actual_hash = actual['hash']
        if expected_hash && actual_hash
          return false unless expected_hash == actual_hash
        end

        if expected_hash.nil? || actual_hash.nil?
          if expected['leading_bytes'] && actual['leading_bytes']
            return false unless expected['leading_bytes'] == actual['leading_bytes']
          end

          if expected['trailing_bytes'] && actual['trailing_bytes']
            return false unless expected['trailing_bytes'] == actual['trailing_bytes']
          end
        end

        true
      end

      def self.mtimes_close?(a, b)
        return false if a.nil? || b.nil?

        (a.to_f - b.to_f).abs <= MTIME_TOLERANCE
      end

      def self.sample_edges(path, sample_bytes, size)
        leading = ''.b
        trailing = ''.b
        return [leading, trailing] unless sample_bytes.positive? && size.positive?

        File.open(path, 'rb') do |file|
          leading = file.read(sample_bytes) || ''.b
          if size > sample_bytes
            seek_position = [size - sample_bytes, 0].max
            file.seek(seek_position, IO::SEEK_SET)
            trailing = file.read(sample_bytes) || ''.b
          end
        end

        [leading, trailing]
      rescue Errno::ENOENT
        ['', '']
      end

      def self.encode(bytes)
        Base64.strict_encode64(bytes)
      end
    end
  end
end
