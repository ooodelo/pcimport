# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../ui/preview_layer'

unless defined?(Geom::Point3d)
  module Geom
    Point3d = Struct.new(:x, :y, :z)
  end
end

module PointCloud
  module UI
    class PreviewLayerTest < Minitest::Test
      class FakeView
        attr_reader :drawn

        def initialize
          @drawn = []
        end

        def draw_points(points, size, style, color)
          @drawn << { points: points, size: size, style: style, color: color }
        end
      end

      class FakeTool
        attr_reader :last_limit

        def initialize(drawn_count:, samples: [])
          @drawn_count = drawn_count
          @samples = samples
          @last_limit = nil
        end

        def last_drawn_point_count
          @drawn_count
        end

        def reservoir_samples(limit = nil)
          @last_limit = limit
          return @samples.dup if limit.nil?

          @samples.first(limit)
        end
      end

      def setup
        @view = FakeView.new
      end

      def test_skip_when_points_already_drawn
        tool = FakeTool.new(drawn_count: 10, samples: [{ position: [0.0, 0.0, 0.0] }])

        PreviewLayer.draw(@view, tool)

        assert_empty @view.drawn
        assert_nil tool.last_limit
      end

      def test_draws_preview_points_when_no_points_drawn
        samples = [
          { position: [0.0, 0.0, 0.0] },
          { position: [1.0, 1.0, 1.0] }
        ]
        tool = FakeTool.new(drawn_count: 0, samples: samples)

        PreviewLayer.draw(@view, tool)

        refute_empty @view.drawn
        batch = @view.drawn.first
        assert_equal PointCloud::UI::PreviewLayer::POINT_SIZE, batch[:size]
        assert_equal 'black', batch[:color]
        assert_equal samples.length, batch[:points].length
        assert batch[:points].all? { |point| point.is_a?(Geom::Point3d) }
        assert_equal PointCloud::UI::PreviewLayer::SAMPLE_LIMIT, tool.last_limit
      end

      def test_skip_when_no_samples
        tool = FakeTool.new(drawn_count: 0, samples: [])

        PreviewLayer.draw(@view, tool)

        assert_empty @view.drawn
        assert_equal PointCloud::UI::PreviewLayer::SAMPLE_LIMIT, tool.last_limit
      end
    end
  end
end
