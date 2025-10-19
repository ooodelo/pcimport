# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../ui/preview_layer'

module PointCloud
  module UI
    class PreviewLayerTest < Minitest::Test
      class FakeView
        attr_reader :draw_calls

        def respond_to_missing?(method_name, include_private = false)
          method_name == :draw_points || super
        end

        def respond_to?(method_name, include_private = false)
          method_name == :draw_points || super
        end

        def draw_points(points, point_size, style, color)
          @draw_calls ||= []
          @draw_calls << { points: points, size: point_size, style: style, color: color }
        end
      end

      FakeTool = Struct.new(:count, :samples, :color) do
        def last_drawn_point_count
          count
        end

        def preview_samples(limit)
          limit && limit > 0 ? samples.first(limit) : samples
        end

        def respond_to_missing?(method_name, include_private = false)
          method_name == :default_point_color || super
        end

        def method_missing(method_name, *args, &block)
          if method_name == :default_point_color
            color
          else
            super
          end
        end
      end

      def test_skips_when_main_render_has_points
        view = FakeView.new
        tool = FakeTool.new(5, [{ position: [0.0, 0.0, 0.0] }], nil)

        PreviewLayer.draw(view, tool)

        assert_nil view.draw_calls
      end

      def test_draws_preview_when_no_points_rendered
        view = FakeView.new
        sample = { position: [1.0, 2.0, 3.0] }
        tool = FakeTool.new(0, [sample], :color)

        PreviewLayer.draw(view, tool)

        refute_nil view.draw_calls
        call = view.draw_calls.first
        assert_equal [sample[:position]], call[:points]
        assert_equal PreviewLayer::PREVIEW_POINT_SIZE, call[:size]
        assert_equal 1, call[:style]
        assert_equal :color, call[:color]
      end
    end
  end
end
