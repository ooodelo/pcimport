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
        attr_reader :chunk_store, :reservoir

        def initialize(chunk_store:, reservoir_size: 5_000)
          @chunk_store = chunk_store
          @reservoir = Reservoir.new(reservoir_size)
          @render_queue = []
          @budget = 1
        end

        def submit_chunk(key, chunk)
          chunk_store.store(key, chunk)
          enqueue(key, chunk)
          update_reservoir(chunk)
        end

        def next_chunks(frame_budget: @budget)
          @budget = frame_budget
          remaining_points = frame_budget
          selected_keys = []

          while remaining_points.positive? && (entry = @render_queue.shift)
            key, _morton, point_count = entry
            selected_keys << key
            remaining_points -= point_count
          end

          selected_keys.map do |key|
            [key, chunk_store.fetch(key)]
          end
        end

        def enqueue(key, chunk)
          center = chunk.metadata[:bounds][:min].zip(chunk.metadata[:bounds][:max]).map { |min, max| (min + max) * 0.5 }
          quantized = center.map { |value| (value / chunk.scale).to_i }
          morton = Spatial::Morton.encode(*quantized)
          @render_queue << [key, morton, chunk.size]
          @render_queue.sort_by! { |_, value, _| value }
        end

        private

        def update_reservoir(chunk)
          chunk.each_point do |point|
            reservoir.offer(point)
          end
        end
      end
    end
  end
end
