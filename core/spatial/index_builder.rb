# frozen_string_literal: true

require_relative 'morton'

module PointCloudPlugin
  module Core
    module Spatial
      # Builds a spatial index for chunks using Morton ordering.
      class IndexBuilder
        def initialize(chunk_store)
          @chunk_store = chunk_store
        end

        def build
          entries = []
          @chunk_store.each_in_memory do |key, chunk|
            center = chunk.metadata[:bounds][:min].zip(chunk.metadata[:bounds][:max]).map { |min, max| (min + max) * 0.5 }
            scale = chunk.scale
            code = Morton.encode(*(center.map { |component| (component / scale).to_i }))
            entries << [key, code]
          end

          entries.sort_by { |entry| entry[1] }.map(&:first)
        end
      end
    end
  end
end
