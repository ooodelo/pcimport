# frozen_string_literal: true

require 'json'
require 'fileutils'

require_relative 'chunk_serializer'
require_relative 'file_hasher'

module PointCloudPlugin
  module Core
    # Encapsulates manifest metadata that describes a cached point cloud.
    class Manifest
      MANIFEST_FILE = 'manifest.json'

      attr_reader :cache_path

      def self.load(cache_path)
        manifest_path = File.join(cache_path, MANIFEST_FILE)
        return unless File.exist?(manifest_path)

        data = JSON.parse(File.binread(manifest_path))
        manifest = new(cache_path: cache_path, data: data)
        manifest.ensure_chunk_inventory!
        manifest
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def self.create(cache_path, source_path: nil, project_path: nil)
        manifest = new(cache_path: cache_path)
        manifest.project_path = project_path if project_path
        manifest.update_source!(source_path) if source_path
        manifest.write!
        manifest
      end

      def self.clone_cache(source_dir, destination_dir, project_path: nil)
        FileUtils.mkdir_p(File.dirname(destination_dir))
        FileUtils.rm_rf(destination_dir)
        FileUtils.mkdir_p(destination_dir)
        FileUtils.cp_r(File.join(source_dir, '.'), destination_dir)

        manifest = load(destination_dir)
        if manifest
          manifest.project_path = project_path if project_path
          manifest.write!
        end
        manifest
      rescue StandardError
        invalidate!(destination_dir)
        raise
      end

      def self.invalidate!(cache_dir)
        FileUtils.rm_rf(cache_dir)
      rescue StandardError
        nil
      end

      def initialize(cache_path:, data: nil)
        @cache_path = cache_path
        @data = default_manifest.merge(data.is_a?(Hash) ? deep_stringify(data) : {})
      end

      def path
        File.join(cache_path, MANIFEST_FILE)
      end

      def project_path
        @data['project_path']
      end

      def project_path=(value)
        @data['project_path'] = value
      end

      def source
        @data['source']
      end

      def update_source!(source_path)
        return unless source_path && File.exist?(source_path)

        signature = build_source_metadata(source_path)
        update_source_signature!(signature)
      end

      def update_source_signature!(signature)
        return unless signature.is_a?(Hash)

        @data['source'] = deep_stringify(signature)
      end

      def valid_for?(source_path)
        return false unless source_path && File.exist?(source_path)

        expected = build_source_metadata(source_path)
        current = source

        return false unless current
        return false unless FileHasher.signatures_match?(current, expected)

        chunks.all? do |filename|
          File.exist?(File.join(cache_path, filename))
        end
      rescue StandardError
        false
      end

      def chunks
        @data['chunks'] ||= []
      end

      def chunks=(list)
        @data['chunks'] = Array(list).map(&:to_s)
      end

      def add_chunk(filename)
        chunks << filename.to_s unless chunks.include?(filename.to_s)
      end

      def version
        @data['version']
      end

      def version=(value)
        @data['version'] = value
      end

      def chunk_format_version
        @data['chunk_format_version']
      end

      def chunk_format_version=(value)
        @data['chunk_format_version'] = value
      end

      def preview_file
        @data['preview_file']
      end

      def preview_file=(value)
        @data['preview_file'] = value
      end

      def anchors
        @data['anchors'] ||= default_anchors
      end

      def anchors=(flags)
        @data['anchors'] = default_anchors.merge(deep_stringify(flags))
      end

      def write!
        FileUtils.mkdir_p(cache_path)
        File.binwrite(path, JSON.pretty_generate(@data))
      end

      # Ensures the manifest knows which chunks exist in the cache directory.
      def ensure_chunk_inventory!
        glob = Dir.glob(File.join(cache_path, '*.pccb'))
        legacy = Dir.glob(File.join(cache_path, '*.chunk'))
        files = (glob + legacy).map { |file| File.basename(file) }
        self.chunks = files.sort
        if glob.any?
          self.chunk_format_version = ChunkSerializer::VERSION
        end
      rescue StandardError
        nil
      end

      private

      def default_manifest
        {
          'version' => 1,
          'chunk_format_version' => ChunkSerializer::VERSION,
          'project_path' => nil,
          'source' => nil,
          'chunks' => [],
          'preview_file' => nil,
          'anchors' => default_anchors
        }
      end

      def default_anchors
        {
          'has_world_anchor' => false,
          'has_custom_anchors' => false
        }
      end

      def deep_stringify(object)
        case object
        when Hash
          object.each_with_object({}) do |(key, value), memo|
            memo[key.to_s] = deep_stringify(value)
          end
        when Array
          object.map { |value| deep_stringify(value) }
        else
          object
        end
      end

      def build_source_metadata(source_path)
        FileHasher.signature_for(source_path)
      end
    end
  end
end
