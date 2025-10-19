# frozen_string_literal: true

require_relative 'manifest'
require_relative 'chunk_serializer'
require_relative 'sample_cache'

module PointCloudPlugin
  module Core
    # Provides access to cached PCCB chunks and preview samples without going
    # through the LOD pipeline. Intended for overlay rendering and other
    # inspection tooling.
    class OverlayDataSource
      ChunkEntry = Struct.new(:key, :path)

      attr_reader :cache_path, :manifest

      def initialize(cache_path:, manifest: nil, chunk_serializer: nil)
        @cache_path = cache_path
        @manifest = manifest
        @chunk_serializer = chunk_serializer || ChunkSerializer.new
        @chunk_entries = nil
      end

      def manifest=(value)
        @manifest = value
        refresh!
      end

      def refresh!
        @chunk_entries = discover_chunk_entries
        self
      end

      def each_entry
        refresh_if_needed
        return enum_for(:each_entry) unless block_given?

        @chunk_entries.each do |entry|
          yield entry
        end
      end

      def chunk_keys
        refresh_if_needed
        @chunk_entries.map(&:key)
      end

      def chunk_path(key)
        return unless key

        entry = find_entry(key)
        entry&.path
      end

      def chunk?(key)
        !!chunk_path(key)
      end

      def load_chunk(key)
        path = chunk_path(key)
        return unless path && File.exist?(path)

        serializer.read(path)
      rescue StandardError
        nil
      end

      def sample_metadata
        SampleCache.metadata(cache_path)
      end

      def read_samples(limit: nil)
        SampleCache.read_samples(cache_path, limit: limit)
      end

      private

      attr_reader :chunk_serializer

      alias serializer chunk_serializer

      def refresh_if_needed
        @chunk_entries ||= discover_chunk_entries
      end

      def discover_chunk_entries
        files = manifest_chunk_files
        files = filesystem_chunk_files if files.empty?
        files.uniq!
        files.compact!
        files.map! do |path|
          key = File.basename(path).sub(/\.(pccb|chunk)\z/i, '')
          ChunkEntry.new(key, path)
        end
        files.sort_by!(&:key)
        files
      rescue StandardError
        []
      end

      def manifest_chunk_files
        return [] unless manifest && manifest.respond_to?(:chunks)

        base = cache_path.to_s
        return [] if base.empty?

        Array(manifest.chunks).each_with_object([]) do |filename, collection|
          next unless filename

          path = File.join(base, filename.to_s)
          collection << path if File.exist?(path)
        end
      rescue StandardError
        []
      end

      def filesystem_chunk_files
        base = cache_path.to_s
        return [] if base.empty?

        glob = Dir.glob(File.join(base, '*.pccb'))
        legacy = Dir.glob(File.join(base, '*.chunk'))
        glob + legacy
      rescue StandardError
        []
      end

      def find_entry(key)
        refresh_if_needed
        @chunk_entries.find { |entry| entry.key.to_s == key.to_s }
      end
    end
  end
end
