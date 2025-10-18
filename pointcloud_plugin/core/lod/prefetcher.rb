# frozen_string_literal: true

require_relative '../spatial/index_builder'
require_relative '../spatial/frustum'

module PointCloudPlugin
  module Core
    module Lod
      # Determines which chunks should be prefetched based on view parameters.
      class Prefetcher
        def initialize(chunk_store)
          @chunk_store = chunk_store
          @index_builder = Spatial::IndexBuilder.new(chunk_store)
        end

        def prefetch_for_view(frustum, budget: 8)
          ordered_keys = @index_builder.build

          visible_chunks = []
          ordered_keys.each do |key|
            chunk = @chunk_store.fetch(key)
            next unless chunk

            bounds = chunk.metadata[:bounds]
            next unless bounds && frustum.intersects_bounds?(bounds)

            visible_chunks << [key, chunk]
          end

          selected_keys = []
          remaining_points = budget

          visible_chunks.each do |key, chunk|
            selected_keys << key
            remaining_points -= chunk.size
            break if remaining_points <= 0
          end

          @chunk_store.prefetch(selected_keys)
        end
      end
    end
  end
end
