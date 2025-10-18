# frozen_string_literal: true

require_relative 'octree'

module PointCloudPlugin
  module Core
    module Spatial
      # Builds and maintains an octree covering the chunks stored in memory.
      class IndexBuilder
        DEFAULT_MAX_DEPTH = 8
        DEFAULT_MAX_POINTS = 200_000
        DEFAULT_MAX_CHUNKS = 8

        attr_reader :root

        def initialize(chunk_store, max_depth: DEFAULT_MAX_DEPTH, max_points_per_node: DEFAULT_MAX_POINTS,
                       max_chunks_per_node: DEFAULT_MAX_CHUNKS)
          @chunk_store = chunk_store
          @max_depth = max_depth
          @max_points_per_node = max_points_per_node
          @max_chunks_per_node = max_chunks_per_node
          @chunk_to_node = {}
          @root = nil
        end

        def build
          entries = []
          @chunk_store.each_in_memory do |key, chunk|
            bounds = chunk.metadata[:bounds]
            next unless bounds

            entries << [key, chunk]
          end

          rebuild(entries)
        end

        def add_chunk(key, chunk)
          bounds = chunk.metadata[:bounds]
          return unless bounds

          if @root.nil?
            initialize_root(bounds)
          elsif !contains_bounds?(@root.bbox, bounds)
            rebuild(existing_chunks + [[key, chunk]])
            return @chunk_to_node[key]
          end

          node = @root.add_chunk(
            key: key,
            bounds: bounds,
            point_count: chunk.size,
            max_depth: @max_depth,
            max_points_per_node: @max_points_per_node,
            max_chunks_per_node: @max_chunks_per_node
          )

          @chunk_to_node[key] = node
          node
        end

        def node_for(key)
          @chunk_to_node[key]
        end

        def visible_nodes(frustum)
          return [] unless @root

          @root.visible_nodes(frustum)
        end

        private

        def rebuild(entries)
          unless entries.any?
            @root = nil
            @chunk_to_node.clear
            return
          end

          bounds = combined_bounds(entries.map { |(_, chunk)| chunk.metadata[:bounds] })
          initialize_root(bounds)

          @chunk_to_node.clear

          entries.each do |key, chunk|
            node = @root.add_chunk(
              key: key,
              bounds: chunk.metadata[:bounds],
              point_count: chunk.size,
              max_depth: @max_depth,
              max_points_per_node: @max_points_per_node,
              max_chunks_per_node: @max_chunks_per_node
            )
            @chunk_to_node[key] = node
          end

          @root
        end

        def existing_chunks
          @chunk_to_node.keys.map do |key|
            chunk = @chunk_store.fetch(key)
            [key, chunk] if chunk
          end.compact
        end

        def initialize_root(bounds)
          normalized = normalize_bounds(bounds)
          @root = OctreeNode.new(bbox: normalized, depth: 0)
        end

        def combined_bounds(bounds_list)
          mins = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
          maxs = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]

          bounds_list.each do |bounds|
            3.times do |axis|
              mins[axis] = [mins[axis], bounds[:min][axis]].min
              maxs[axis] = [maxs[axis], bounds[:max][axis]].max
            end
          end

          { min: mins, max: maxs }
        end

        def contains_bounds?(outer, inner)
          3.times.all? do |axis|
            inner[:min][axis] >= outer[:min][axis] && inner[:max][axis] <= outer[:max][axis]
          end
        end

        def normalize_bounds(bounds)
          {
            min: bounds[:min].map(&:to_f),
            max: bounds[:max].map(&:to_f)
          }
        end
      end
    end
  end
end
