# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Spatial
      Plane = Struct.new(:normal, :distance)

      # Simple frustum used to test chunk visibility.
      class Frustum
        DEFAULT_EPSILON = 1e-4

        attr_reader :planes, :epsilon

        def self.from_view_matrices(modelview, projection, epsilon: DEFAULT_EPSILON)
          mv = to_matrix(modelview)
          proj = to_matrix(projection)
          clip = multiply_matrices(proj, mv)
          from_clip_matrix(clip, epsilon: epsilon)
        end

        def self.from_clip_matrix(matrix, epsilon: DEFAULT_EPSILON)
          clip = to_matrix(matrix)
          planes = extract_planes(clip)
          new(planes, epsilon: epsilon)
        end

        def self.to_matrix(matrix)
          values =
            case matrix
            when Array
              matrix.flatten
            else
              matrix.respond_to?(:to_a) ? matrix.to_a.flatten : nil
            end

          raise ArgumentError, 'matrix must contain 16 numeric values' unless values&.length == 16

          values.each_slice(4).map { |row| row.map(&:to_f) }
        end
        private_class_method :to_matrix

        def self.multiply_matrices(a, b)
          Array.new(4) do |row|
            Array.new(4) do |col|
              (0..3).sum { |k| a[row][k] * b[k][col] }
            end
          end
        end
        private_class_method :multiply_matrices

        def self.extract_planes(clip)
          # Gribb-Hartmann extraction assumes clip matrix is row-major.
          row0, row1, row2, row3 = clip

          raw_planes = [
            add_rows(row3, row0),
            subtract_rows(row3, row0),
            add_rows(row3, row1),
            subtract_rows(row3, row1),
            add_rows(row3, row2),
            subtract_rows(row3, row2)
          ]

          raw_planes.map do |plane|
            normal = plane[0, 3]
            distance = plane[3]
            normalize_plane(normal, distance)
          end.compact
        end
        private_class_method :extract_planes

        def self.add_rows(a, b)
          a.zip(b).map { |av, bv| av + bv }
        end
        private_class_method :add_rows

        def self.subtract_rows(a, b)
          a.zip(b).map { |av, bv| av - bv }
        end
        private_class_method :subtract_rows

        def self.normalize_plane(normal, distance)
          length = Math.sqrt(normal.sum { |component| component * component })
          return nil if length.zero?

          Plane.new(normal.map { |component| component / length }, distance / length)
        end
        private_class_method :normalize_plane

        def initialize(planes, epsilon: DEFAULT_EPSILON)
          @planes = planes
          @epsilon = epsilon
        end

        def contains_point?(point)
          planes.all? do |plane|
            dot = plane.normal.zip(point).sum { |component, value| component * value }
            dot + plane.distance >= -epsilon
          end
        end

        def intersects_bounds?(bounds)
          corners = build_corners(bounds)

          planes.all? do |plane|
            corners.any? do |corner|
              dot = plane.normal.zip(corner).sum { |component, value| component * value }
              dot + plane.distance >= -epsilon
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
