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

        def nearest_to_ray(origin, direction, k = 1)
          distances = @points.map do |candidate|
            [candidate, distance_to_ray(origin, direction, candidate[:position])]
          end

          distances.sort_by! { |_, dist| dist }
          distances.first(k)
        end

        private

        def distance(point_a, point_b)
          (0...3).sum { |axis| (point_a[axis] - point_b[axis])**2 }
        end

        def distance_to_ray(origin, direction, point)
          coordinates = extract_coordinates(point)
          vector_to_point = (0...3).map { |axis| coordinates[axis] - origin[axis] }
          projection = dot_product(vector_to_point, direction)

          if projection.negative?
            distance(coordinates, origin)
          else
            closest_point = (0...3).map { |axis| origin[axis] + direction[axis] * projection }
            distance(coordinates, closest_point)
          end
        end

        def extract_coordinates(point)
          if point.respond_to?(:to_a)
            coordinates = point.to_a
            [coordinates[0], coordinates[1], coordinates[2]]
          else
            [point[0], point[1], point[2]]
          end
        end

        def dot_product(vector_a, vector_b)
          (0...3).sum { |axis| vector_a[axis] * vector_b[axis] }
        end
      end
    end
  end
end
