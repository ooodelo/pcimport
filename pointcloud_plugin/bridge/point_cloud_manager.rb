# frozen_string_literal: true

require_relative '../core/lod/pipeline'
require_relative '../core/lod/prefetcher'
require_relative 'main_thread_queue'

module PointCloudPlugin
  module Bridge
    # Keeps track of active point clouds and their associated resources.
    class PointCloudManager
      Cloud = Struct.new(:id, :name, :pipeline, :prefetcher, :job)

      attr_reader :clouds

      def initialize
        @clouds = {}
        @queue = MainThreadQueue.new
      end

      def register_cloud(name:, pipeline:, job: nil, id: nil)
        id = normalize_identifier(id)
        validate_unique_id!(id)
        id ||= next_id
        prefetcher = Core::Lod::Prefetcher.new(pipeline.chunk_store)
        clouds[id] = Cloud.new(id, name, pipeline, prefetcher, job)
        update_last_id_tracker(id)
        id
      end

      def remove_cloud(id)
        cloud = clouds.delete(id)
        cloud&.job&.join
      end

      def each_cloud
        return enum_for(:each_cloud) unless block_given?

        clouds.values.each { |cloud| yield cloud }
      end

      def queue
        @queue
      end

      private

      def next_id
        (@last_id ||= 0)
        @last_id += 1
      end

      def normalize_identifier(identifier)
        return identifier if identifier.nil?

        identifier.is_a?(String) || identifier.is_a?(Integer) ? identifier : identifier.to_s
      end

      def validate_unique_id!(identifier)
        return unless identifier

        raise ArgumentError, "Cloud identifier '#{identifier}' already registered" if clouds.key?(identifier)
      end

      def update_last_id_tracker(identifier)
        return unless identifier.is_a?(Integer)

        @last_id = identifier if !@last_id || identifier > @last_id
      end
    end
  end
end
