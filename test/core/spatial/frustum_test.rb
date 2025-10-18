# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/spatial/frustum'

module PointCloudPlugin
  module Core
    module Spatial
      class FrustumTest < Minitest::Test
        def test_extracts_planes_from_identity_matrices
          frustum = Frustum.from_view_matrices(identity_matrix, identity_matrix)

          assert_equal 6, frustum.planes.size
          assert frustum.contains_point?([0.0, 0.0, 0.0])
          refute frustum.contains_point?([2.0, 0.0, 0.0])
        end

        def test_intersects_bounds_respects_epsilon
          frustum = Frustum.from_clip_matrix(identity_matrix, epsilon: 0.1)
          bounds = { min: [1.05, -0.1, -0.1], max: [1.1, 0.1, 0.1] }

          assert frustum.intersects_bounds?(bounds)

          tight_frustum = Frustum.from_clip_matrix(identity_matrix, epsilon: 0.0)
          refute tight_frustum.intersects_bounds?(bounds)
        end

        private

        def identity_matrix
          [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0]
          ]
        end
      end
    end
  end
end
