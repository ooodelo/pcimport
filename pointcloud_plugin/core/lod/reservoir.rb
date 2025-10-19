# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Lod
      # Reservoir sampling to select representative points for preview.
      class Reservoir
        attr_reader :size, :samples

        def initialize(size)
          @size = size
          @samples = []
          @seen = 0
        end

        def offer(point)
          @seen += 1
          if samples.size < size
            samples << point
          else
            index = rand(@seen)
            samples[index] = point if index < size
          end
        end

        def sample(quota)
          return samples.dup if quota.nil?

          quota = quota.to_i
          return [] if quota <= 0
          return samples.dup if quota >= samples.size

          samples.sample(quota)
        end

        def reset!
          @samples.clear
          @seen = 0
        end
      end

      # Reservoir LOD management keeps an independent reservoir per node.
      class ReservoirLOD
        attr_reader :default_size, :reservoirs

        def initialize(reservoir_size)
          @default_size = reservoir_size
          @reservoirs = {}
        end

        def update_node(node_id, points)
          return unless node_id

          reservoir = reservoir_for(node_id)
          return unless points.respond_to?(:each)

          points.each do |point|
            reservoir.offer(point)
          end
        end

        def sample_node(node_id, quota)
          reservoir = @reservoirs[node_id]
          return [] unless reservoir

          reservoir.sample(quota)
        end

        def samples(total_quota: nil)
          total_quota = total_quota.nil? ? default_size : total_quota.to_i
          return [] if total_quota <= 0 || reservoirs.empty?

          nodes = reservoirs.keys
          base_quota, remainder = total_quota.divmod(nodes.size)

          nodes.each_with_index.flat_map do |node_id, index|
            quota = base_quota
            quota += 1 if index < remainder
            next [] if quota.zero?

            sample_node(node_id, quota)
          end
        end

        def reset!
          @reservoirs.clear
        end

        private

        def reservoir_for(node_id)
          @reservoirs[node_id] ||= Reservoir.new(default_size)
        end
      end
    end
  end
end
