# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Spatial
      # Brute force K nearest neighbour search used for snapping.
      class Knn
        def initialize(points)
          @points = points
        end

        def nearest(point, k = 1)
          distances = @points.map do |candidate|
            [candidate, distance(point, candidate[:position])]
          end

          distances.sort_by! { |_, dist| dist }
          distances.first(k)
        end

        private

        def distance(point_a, point_b)
          (0...3).sum { |axis| (point_a[axis] - point_b[axis])**2 }
        end
      end
    end
  end
end
