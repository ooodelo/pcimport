# frozen_string_literal: true

require 'set'

require_relative '../chunk_store'
require_relative '../chunk'
require_relative 'reservoir'
require_relative 'budget_distributor'
require_relative '../spatial/index_builder'

module PointCloudPlugin
  module Core
    module Lod
      # Coordinates chunk submission and frame budgeting using an octree.
      class Pipeline
        attr_reader :chunk_store, :reservoir, :index_builder

        def initialize(chunk_store:, reservoir_size: 5_000)
          @chunk_store = chunk_store
          @reservoir = ReservoirLOD.new(reservoir_size)
          @budget_distributor = BudgetDistributor.new
          @index_builder = Spatial::IndexBuilder.new(chunk_store)
          @chunk_nodes = {}
          @budget = 1
          @lod_cache = Hash.new { |hash, key| hash[key] = {} }
          register_chunk_store_callbacks
        end

        def submit_chunk(key, chunk)
          chunk_store.store(key, chunk)
          node = index_builder.add_chunk(key, chunk)
          @chunk_nodes[key] = node
          update_reservoir(node, chunk)
          clear_lod_cache_for(key)
        end

        def next_chunks(
          frame_budget: @budget,
          frustum: nil,
          camera_position: nil,
          visible_chunk_keys: nil,
          visible_nodes: nil
        )
          @budget = frame_budget
          budget = frame_budget
          unlimited_budget = budget.nil? || budget <= 0
          visible_nodes ||= determine_visible_nodes_from_keys(visible_chunk_keys)
          visible_nodes = determine_visible_nodes(frustum) if visible_nodes.nil?
          visible_nodes = filter_nodes_by_visible_keys(visible_nodes, visible_chunk_keys)
          return [] if visible_nodes.empty?

          if unlimited_budget
            keys = ordered_keys_for_nodes(visible_nodes, visible_chunk_keys)
            return keys.map { |key| [key, chunk_store.fetch(key)] }
          end

          quotas = @budget_distributor.distribute(visible_nodes, budget, camera_position)
          requests = allocate_chunk_requests(visible_nodes, quotas, visible_chunk_keys)
          build_chunk_list(requests)
        end

        def visible_nodes_for(frustum = nil, visible_chunk_keys: nil)
          nodes = determine_visible_nodes_from_keys(visible_chunk_keys)
          return nodes unless nodes.nil?

          determine_visible_nodes(frustum)
        end

        private

        def determine_visible_nodes_from_keys(visible_chunk_keys)
          return nil if visible_chunk_keys.nil?

          keys = Array(visible_chunk_keys).compact
          return [] if keys.empty?

          keys.filter_map { |key| @chunk_nodes[key] }.uniq
        end

        def filter_nodes_by_visible_keys(nodes, visible_keys)
          return Array(nodes).compact if visible_keys.nil?

          visible_set = Array(visible_keys).compact.to_set
          return [] if visible_set.empty?

          Array(nodes).compact.select do |node|
            node.chunk_refs.any? { |ref| visible_set.include?(ref[:key]) }
          end
        end

        def determine_visible_nodes(frustum)
          return [] unless index_builder.root

          if frustum
            index_builder.visible_nodes(frustum)
          else
            index_builder.root.visible_nodes(nil)
          end
        end

        def ordered_keys_for_nodes(nodes, visible_chunk_keys = nil)
          nodes.flat_map do |node|
            filtered_chunk_refs(node, visible_chunk_keys).map { |ref| ref[:key] }
          end.uniq
        end

        def allocate_chunk_requests(nodes, quotas, visible_chunk_keys)
          visible_set = visible_chunk_keys && Array(visible_chunk_keys).compact.to_set
          requests = Hash.new(0)

          nodes.each do |node|
            chunk_refs = filtered_chunk_refs(node, visible_set)
            next if chunk_refs.empty?

            node_quota = quotas[node].to_i
            next if node_quota <= 0

            total_points = chunk_refs.sum { |ref| ref[:point_count] }
            next if total_points <= 0

            remaining = node_quota

            chunk_refs.each_with_index do |ref, index|
              share =
                if index == chunk_refs.length - 1
                  remaining
                else
                  ((node_quota * ref[:point_count]) / total_points.to_f).floor
                end

              share = [[share, 0].max, remaining].min
              requests[ref[:key]] += share
              remaining -= share
              break if remaining <= 0
            end
          end

          requests
        end

        def filtered_chunk_refs(node, visible_keys)
          return node.chunk_refs unless visible_keys

          node.chunk_refs.select { |ref| visible_keys.include?(ref[:key]) }
        end

        def build_chunk_list(requests)
          requests.each_with_object([]) do |(key, requested_points), list|
            next if requested_points <= 0

            chunk = chunk_store.fetch(key)
            unless chunk
              clear_lod_cache_for(key)
              next
            end

            sampled = fetch_or_store_lod_chunk(key, requested_points) do
              downsample_chunk(chunk, requested_points)
            end
            list << [key, sampled]
          end
        end

        def fetch_or_store_lod_chunk(key, requested_points)
          cache = @lod_cache[key]
          return cache[requested_points] if cache.key?(requested_points)

          cache[requested_points] = yield
        end

        def downsample_chunk(chunk, target_points)
          return chunk if chunk.nil?

          return chunk if target_points.nil? || target_points <= 0
          return chunk if !chunk.respond_to?(:size) || chunk.size <= target_points
          return chunk unless chunk.respond_to?(:positions) && chunk.respond_to?(:colors) && chunk.respond_to?(:intensities)

          indices = evenly_spaced_indices(chunk.size, target_points)

          positions = {
            x: indices.map { |index| chunk.positions[:x][index] },
            y: indices.map { |index| chunk.positions[:y][index] },
            z: indices.map { |index| chunk.positions[:z][index] }
          }

          colors = {
            r: indices.map { |index| chunk.colors[:r][index] },
            g: indices.map { |index| chunk.colors[:g][index] },
            b: indices.map { |index| chunk.colors[:b][index] }
          }

          intensities = indices.map { |index| chunk.intensities[index] }

          metadata = chunk.metadata ? chunk.metadata.dup : {}
          metadata[:lod] = { original_size: chunk.size, sampled_size: target_points }

          Chunk.new(
            origin: chunk.origin,
            scale: chunk.scale,
            positions: positions,
            colors: colors,
            intensities: intensities,
            metadata: metadata
          )
        end

        def evenly_spaced_indices(total_points, target_points)
          return (0...total_points).to_a if target_points >= total_points

          step = total_points.fdiv(target_points)
          indices = Array.new(target_points) { |i| (i * step).floor }
          indices[-1] = total_points - 1

          (1...indices.length).each do |index|
            indices[index] = [indices[index], indices[index - 1] + 1].max
          end

          indices.map! { |value| [value, total_points - 1].min }
          indices
        end

        def update_reservoir(node, chunk)
          return unless node

          reservoir.update_node(node.id, chunk.each_point)
        end

        def register_chunk_store_callbacks
          return unless chunk_store.respond_to?(:on_remove)

          chunk_store.on_remove do |key|
            clear_lod_cache_for(key)
          end
        end

        def clear_lod_cache_for(key)
          return unless key

          @lod_cache.delete(key)
        end
      end
    end
  end
end
