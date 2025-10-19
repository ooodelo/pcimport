# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'tmpdir'
require 'time'

require_relative 'manifest'
require_relative 'sample_cache'

module PointCloudPlugin
  module Core
    # Handles discovery and bookkeeping of point cloud caches for a model.
    #
    # The cache layout is organized per-project using the following structure:
    #   <project>/PointCloudCache/<cloud_id>
    # When the model has not been saved yet a temporary folder is used instead.
    #
    # Metadata about registered clouds is stored on the SketchUp model via the
    # attribute dictionary `PointCloudImporter` under the key `clouds` so that
    # cache associations survive reloads.
    class ProjectCacheManager
      NAMESPACE = 'PointCloudImporter'
      CLOUDS_KEY = 'clouds'
      CACHE_DIRNAME = 'PointCloudCache'

      attr_reader :model

      def initialize(model = nil, file_utils: FileUtils)
        @model = model
        @file_utils = file_utils
        @clouds = load_clouds
        migrate_clouds!
      end

      # Returns absolute path to the project (.skp) file if available.
      def project_path
        return @project_path if defined?(@project_path)

        @project_path = begin
          next unless model
          next unless model.respond_to?(:path)

          raw = model.path
          raw = raw.to_s
          raw = nil if raw.empty?
          raw && File.expand_path(raw)
        rescue StandardError
          nil
        end
      end

      # Computes the cache root for the project and ensures the directory
      # exists when +ensure:+ is true.
      def cache_root(ensure_path: true)
        base = if project_directory
                 File.join(project_directory, CACHE_DIRNAME)
               else
                 File.join(Dir.tmpdir, 'PointCloudImporter', sanitized_model_identifier)
               end

        ensure_directory(base) if ensure_path
        base
      end

      # Returns the absolute cache directory for the supplied +cloud_id+.
      def cache_path_for(cloud_id, ensure_path: true)
        path = File.join(cache_root(ensure_path: ensure_path), cloud_id.to_s)
        ensure_directory(path) if ensure_path
        path
      end

      # Generates a unique identifier suitable for cache folder naming.
      def generate_cloud_identifier
        loop do
          candidate = SecureRandom.uuid
          return candidate unless @clouds.key?(candidate)
        end
      end

      # Finds metadata for a previously registered cloud that originated from
      # +source_path+. Returns a hash that always includes the `id` key when
      # a match is found.
      def find_cloud_for_source(source_path)
        normalized = normalize_path(source_path)
        @clouds.each do |id, data|
          next unless data['source_path'] == normalized

          return data.merge('id' => id)
        end
        nil
      end

      # Registers bookkeeping data for the specified +cloud_id+.
      def register_cloud(id:, name:, source_path:, cache_path:, manifest: nil)
        normalized_source = normalize_path(source_path)
        manifest_path = if manifest&.respond_to?(:path)
                          manifest.path
                        end
        data = {
          'id' => id.to_s,
          'name' => name,
          'source_path' => normalized_source,
          'cache_path' => cache_path,
          'project_path' => project_path,
          'manifest_path' => manifest_path,
          'updated_at' => Time.now.utc.iso8601
        }

        @clouds[id.to_s] = data
        persist_clouds!
        data
      end

      # Returns a shallow copy of the registered clouds metadata.
      def clouds
        @clouds.transform_values(&:dup)
      end

      def cache_hit_payload(cache_path:, manifest: nil)
        cache_path = cache_path && cache_path.to_s
        manifest ||= safe_manifest(manifest, cache_path)

        metadata = Core::SampleCache.metadata(cache_path)
        anchors_ready = metadata[:anchors_ready]

        if manifest
          anchors_data = manifest.anchors || {}
          anchors_ready ||= anchors_data['has_custom_anchors'] || anchors_data[:has_custom_anchors]
          anchors_ready ||= anchors_data['has_world_anchor'] || anchors_data[:has_world_anchor]
        end

        sample_ready = metadata[:sample_ready]
        anchors_ready &&= sample_ready

        stage_progress = default_stage_progress_hash.transform_values { 1.0 }
        timings = {
          total: 0.0,
          stages: stage_progress.transform_values { 0.0 }
        }

        {
          stage: :navigating,
          stage_progress: stage_progress,
          cache_hit: true,
          sample_ready: sample_ready,
          anchors_ready: anchors_ready,
          preview_ready: sample_ready,
          timings: timings,
          error: nil,
          completion_status: :completed
        }
      end

      private

      attr_reader :file_utils

      def safe_manifest(manifest, cache_path)
        return manifest if manifest.is_a?(Manifest)
        return nil unless cache_path && !cache_path.to_s.empty?

        Manifest.load(cache_path)
      rescue StandardError
        nil
      end

      def default_stage_progress_hash
        {
          hash_check: 0.0,
          sampling: 0.0,
          cache_write: 0.0,
          build: 0.0
        }
      end

      def migrate_clouds!
        return if @clouds.empty?

        @clouds.each do |id, data|
          desired_path = cache_path_for(id, ensure_path: false)
          current_path = data['cache_path']

          next if desired_path == current_path

          if current_path && Dir.exist?(current_path)
            begin
              Manifest.clone_cache(current_path, desired_path, project_path: project_path)
            rescue StandardError
              Manifest.invalidate!(desired_path)
            end
          end

          data['cache_path'] = desired_path
          data['project_path'] = project_path
        end

        persist_clouds!
      end

      def ensure_directory(path)
        file_utils.mkdir_p(path)
      rescue StandardError
        # Swallow directory creation issues but keep behaviour predictable.
        nil
      end

      def project_directory
        return unless project_path

        File.dirname(project_path)
      end

      def sanitized_model_identifier
        identifier = if model && model.respond_to?(:guid)
                        model.guid.to_s
                      elsif model
                        "model_#{model.object_id}"
                      else
                        'default'
                      end

        identifier = identifier.gsub(/[\\\/:"<>\|\*\?]+/, '_')
        identifier.empty? ? 'default' : identifier
      end

      def load_clouds
        return {} unless model&.respond_to?(:get_attribute)

        raw = model.get_attribute(NAMESPACE, CLOUDS_KEY, {})
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(key, value), memo|
          next unless value.is_a?(Hash)

          memo[key.to_s] = value.transform_keys(&:to_s)
        end
      rescue StandardError
        {}
      end

      def persist_clouds!
        return unless model&.respond_to?(:set_attribute)

        model.set_attribute(NAMESPACE, CLOUDS_KEY, @clouds.transform_values { |value| value.dup })
      rescue StandardError
        nil
      end

      def normalize_path(path)
        return unless path

        expanded = File.expand_path(path)
        expanded.tr('\\', '/')
      rescue StandardError
        path
      end
    end
  end
end
