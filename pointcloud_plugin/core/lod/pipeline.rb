# frozen_string_literal: true

require_relative '../chunk_store'
require_relative '../chunk'
require_relative 'reservoir'
require_relative '../spatial/morton'

module PointCloudPlugin
  module Core
    module Lod
      # Coordinates chunk submission, Morton sorting and frame budgeting.
      class Pipeline
        MAX_MORTON_COORD = (1 << 21) - 1

        attr_reader :chunk_store, :reservoir

        def initialize(chunk_store:, reservoir_size: 5_000)
          @chunk_store = chunk_store
          @reservoir = Reservoir.new(reservoir_size)
          @render_queue = []
          @budget = 1
          @global_bounds = nil
        end

        def submit_chunk(key, chunk)
          chunk_store.store(key, chunk)
          update_global_bounds(chunk)
          enqueue(key, chunk)
          update_reservoir(chunk)
        end

        def next_chunks(frame_budget: @budget)
          @budget = frame_budget
          budget = frame_budget
          unlimited_budget = budget.nil? || budget <= 0
          selected = []
          points_accumulated = 0

          while (entry = @render_queue.first)
            break unless unlimited_budget || points_accumulated < budget

            key, _morton, point_count = entry
            remaining_budget = unlimited_budget ? point_count : budget - points_accumulated
            break unless unlimited_budget || remaining_budget.positive?

            @render_queue.shift

            points_to_take = unlimited_budget ? point_count : [point_count, remaining_budget].min
            selected << [key, points_to_take]
            points_accumulated += points_to_take
          end

          selected.map do |key, requested_points|
            chunk = chunk_store.fetch(key)
            chunk = downsample_chunk(chunk, requested_points) if requested_points.positive?
            [key, chunk]
          end
        end

        def enqueue(key, chunk)
          morton = compute_morton_code(chunk)
          @render_queue << [key, morton, chunk.size]
          @render_queue.sort_by! { |_, value, _| value }
        end

        private

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

        def update_reservoir(chunk)
          chunk.each_point do |point|
            reservoir.offer(point)
          end
        end

        def update_global_bounds(chunk)
          bounds = chunk.metadata && chunk.metadata[:bounds]
          return unless bounds

          min_bounds = bounds[:min]
          max_bounds = bounds[:max]
          return unless min_bounds && max_bounds

          if @global_bounds
            3.times do |axis|
              @global_bounds[:min][axis] = [@global_bounds[:min][axis], min_bounds[axis]].min
              @global_bounds[:max][axis] = [@global_bounds[:max][axis], max_bounds[axis]].max
            end
          else
            @global_bounds = {
              min: min_bounds.dup,
              max: max_bounds.dup
            }
          end
        end

        def compute_morton_code(chunk)
          bounds = chunk.metadata && chunk.metadata[:bounds]
          return 0 unless bounds

          center = bounds[:min].zip(bounds[:max]).map { |min, max| (min + max) * 0.5 }
          global_bounds = @global_bounds || bounds

          quantized = center.each_with_index.map do |component, axis|
            min = global_bounds[:min][axis]
            max = global_bounds[:max][axis]
            range = max - min
            normalized = range.zero? ? 0.0 : (component - min) / range
            (normalized * MAX_MORTON_COORD).round.clamp(0, MAX_MORTON_COORD)
          end

          Spatial::Morton.encode(*quantized)
        end
      end
    end
  end
end
