# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Spatial
      # Represents a node in an octree hierarchy used for LOD selection.
      class OctreeNode
        attr_reader :bbox, :children, :chunk_refs, :point_count, :depth, :id

        @@next_id = 0

        def self.next_id
          @@next_id += 1
        end

        def initialize(bbox:, depth: 0)
          @bbox = normalize_bbox(bbox)
          @depth = depth
          @children = Array.new(8)
          @chunk_refs = []
          @point_count = 0
          @id = self.class.next_id
        end

        def leaf?
          @children.compact.empty?
        end

        def add_chunk(key:, bounds:, point_count:, max_depth:, max_points_per_node:, max_chunks_per_node:)
          @point_count += point_count
          reference = { key: key, bounds: normalize_bbox(bounds), point_count: point_count }

          if should_subdivide?(max_depth, max_points_per_node, max_chunks_per_node)
            subdivide!
            redistribute_chunks(max_depth, max_points_per_node, max_chunks_per_node)
          end

          insert_reference(reference, max_depth, max_points_per_node, max_chunks_per_node)
        end

        def subdivide!
          return unless leaf?

          center = midpoint
          mins = bbox[:min]
          maxs = bbox[:max]

          (0...8).each do |index|
            child_min = []
            child_max = []

            3.times do |axis|
              use_max = (index >> axis) & 1
              if use_max.zero?
                child_min << mins[axis]
                child_max << center[axis]
              else
                child_min << center[axis]
                child_max << maxs[axis]
              end
            end

            child_bbox = { min: child_min, max: child_max }
            @children[index] = OctreeNode.new(bbox: child_bbox, depth: depth + 1)
          end
        end

        def visible_nodes(frustum, results = [])
          return results if frustum && !frustum.intersects_bounds?(bbox)

          if chunk_refs.any?
            results << self
          end

          @children.compact.each do |child|
            child.visible_nodes(frustum, results)
          end

          results
        end

        def each_leaf(results = [])
          if leaf?
            results << self
          else
            @children.compact.each { |child| child.each_leaf(results) }
          end

          results
        end

        def center
          midpoint
        end

        def diagonal_length
          mins = bbox[:min]
          maxs = bbox[:max]
          Math.sqrt(3.times.sum { |axis| (maxs[axis] - mins[axis])**2 })
        end

        private

        def should_subdivide?(max_depth, max_points_per_node, max_chunks_per_node)
          return false if depth >= max_depth
          return false if leaf? && chunk_refs.empty? && point_count <= max_points_per_node

          point_count > max_points_per_node || chunk_refs.length >= max_chunks_per_node
        end

        def insert_reference(reference, max_depth, max_points_per_node, max_chunks_per_node)
          child_index = child_index_for(reference[:bounds])

          if child_index && @children[child_index]
            @children[child_index].add_chunk(
              key: reference[:key],
              bounds: reference[:bounds],
              point_count: reference[:point_count],
              max_depth: max_depth,
              max_points_per_node: max_points_per_node,
              max_chunks_per_node: max_chunks_per_node
            )
          else
            chunk_refs << reference
            self
          end
        end

        def redistribute_chunks(max_depth, max_points_per_node, max_chunks_per_node)
          existing = chunk_refs.dup
          chunk_refs.clear
          existing.each do |reference|
            insert_reference(reference, max_depth, max_points_per_node, max_chunks_per_node)
          end
        end

        def child_index_for(bounds)
          center = midpoint
          mins = bounds[:min]
          maxs = bounds[:max]

          indices = 3.times.map do |axis|
            if maxs[axis] <= center[axis]
              0
            elsif mins[axis] >= center[axis]
              1
            else
              return nil
            end
          end

          indices[0] | (indices[1] << 1) | (indices[2] << 2)
        end

        def midpoint
          mins = bbox[:min]
          maxs = bbox[:max]
          mins.each_with_index.map { |value, axis| (value + maxs[axis]) * 0.5 }
        end

        def normalize_bbox(bounds)
          {
            min: bounds[:min].map(&:to_f),
            max: bounds[:max].map(&:to_f)
          }
        end
      end
    end
  end
end
