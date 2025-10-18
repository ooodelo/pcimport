# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Lod
      # Maintains a reservoir sampler for each octree node.
      class ReservoirLOD
        NodeReservoir = Struct.new(:size, :samples, :seen, keyword_init: true) do
          def offer(points)
            points.each { |point| add(point) }
          end

          def sample(quota)
            return samples.dup if quota.nil? || quota <= 0 || samples.length <= quota

            quota = quota.to_i
            quota = samples.length if quota > samples.length
            samples.sample(quota)
          end

          def reset!
            samples.clear
            self.seen = 0
          end

          private

          def add(point)
            self.seen += 1
            if samples.length < size
              samples << point
            else
              index = rand(seen)
              samples[index] = point if index < size
            end
          end
        end

        attr_reader :reservoir_size

        def initialize(reservoir_size)
          @reservoir_size = reservoir_size
          @reservoirs = {}
        end

        def update_node(node_id, points)
          return unless node_id

          reservoir = (@reservoirs[node_id] ||= build_reservoir)
          enumerable = points.respond_to?(:each) ? points : Array(points)
          reservoir.offer(enumerable)
        end

        def sample_node(node_id, quota)
          reservoir = @reservoirs[node_id]
          return [] unless reservoir

          reservoir.sample(quota)
        end

        def reset!
          @reservoirs.each_value(&:reset!)
        end

        private

        def build_reservoir
          NodeReservoir.new(size: reservoir_size, samples: [], seen: 0)
        end
      end

      Reservoir = ReservoirLOD
    end
  end
end
