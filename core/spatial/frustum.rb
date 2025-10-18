# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Spatial
      Plane = Struct.new(:normal, :distance)

      # Simple frustum used to test chunk visibility.
      class Frustum
        attr_reader :planes

        def initialize(planes)
          @planes = planes
        end

        def contains_point?(point)
          planes.all? do |plane|
            dot = plane.normal.zip(point).sum { |component, value| component * value }
            dot + plane.distance >= 0
          end
        end

        def intersects_bounds?(bounds)
          corners = build_corners(bounds)

          planes.all? do |plane|
            corners.any? do |corner|
              dot = plane.normal.zip(corner).sum { |component, value| component * value }
              dot + plane.distance >= 0
            end
          end
        end

        private

        def build_corners(bounds)
          mins = bounds[:min]
          maxs = bounds[:max]
          [
            [mins[0], mins[1], mins[2]],
            [mins[0], mins[1], maxs[2]],
            [mins[0], maxs[1], mins[2]],
            [mins[0], maxs[1], maxs[2]],
            [maxs[0], mins[1], mins[2]],
            [maxs[0], mins[1], maxs[2]],
            [maxs[0], maxs[1], mins[2]],
            [maxs[0], maxs[1], maxs[2]]
          ]
        end
      end
    end
  end
end
