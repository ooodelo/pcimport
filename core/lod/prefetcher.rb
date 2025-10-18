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
          visible = ordered_keys.select do |key|
            chunk = @chunk_store.fetch(key)
            chunk && frustum.intersects_bounds?(chunk.metadata[:bounds])
          end

          @chunk_store.prefetch(visible.first(budget))
        end
      end
    end
  end
end
