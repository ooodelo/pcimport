# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../core/chunk'

module PointCloudPlugin
  module Core
    class ChunkPackerTest < Minitest::Test
      def test_pack_aligns_arrays_with_missing_attributes
        points = [
          { position: [0.0, 0.0, 0.0], color: [10, 20, 30], intensity: 100 },
          { position: [1.0, 0.0, 0.0] },
          { position: [0.0, 1.0, 0.0], intensity: 50 },
          { position: [0.0, 0.0, 1.0], color: [1, 2, 3] }
        ]

        chunk = ChunkPacker.new.pack(points)

        size = chunk.positions[:x].size
        assert_equal size, chunk.colors[:r].size
        assert_equal size, chunk.colors[:g].size
        assert_equal size, chunk.colors[:b].size
        assert_equal size, chunk.intensities.size

        assert_equal [10, nil, nil, 1], chunk.colors[:r]
        assert_equal [20, nil, nil, 2], chunk.colors[:g]
        assert_equal [30, nil, nil, 3], chunk.colors[:b]
        assert_equal [100, nil, 50, nil], chunk.intensities
      end

      def test_point_at_returns_correct_attributes
        points = [
          { position: [0.0, 0.0, 0.0], color: [10, 20, 30], intensity: 100 },
          { position: [1.0, 0.0, 0.0] },
          { position: [0.0, 1.0, 0.0], intensity: 50 },
          { position: [0.0, 0.0, 1.0], color: [1, 2, 3] }
        ]

        chunk = ChunkPacker.new.pack(points)

        first_point = chunk.point_at(0)
        assert_in_delta 0.0, first_point[:position][0]
        assert_in_delta 0.0, first_point[:position][1]
        assert_in_delta 0.0, first_point[:position][2]
        assert_equal [10, 20, 30], first_point[:color]
        assert_equal 100, first_point[:intensity]

        second_point = chunk.point_at(1)
        assert_in_delta 1.0, second_point[:position][0], 0.0001
        assert_in_delta 0.0, second_point[:position][1]
        assert_in_delta 0.0, second_point[:position][2]
        assert_nil second_point[:color]
        assert_nil second_point[:intensity]

        third_point = chunk.point_at(2)
        assert_in_delta 0.0, third_point[:position][0]
        assert_in_delta 1.0, third_point[:position][1], 0.0001
        assert_in_delta 0.0, third_point[:position][2]
        assert_nil third_point[:color]
        assert_equal 50, third_point[:intensity]

        fourth_point = chunk.point_at(3)
        assert_in_delta 0.0, fourth_point[:position][0]
        assert_in_delta 0.0, fourth_point[:position][1]
        assert_in_delta 1.0, fourth_point[:position][2], 0.0001
        assert_equal [1, 2, 3], fourth_point[:color]
        assert_nil fourth_point[:intensity]
      end
    end
  end
end
