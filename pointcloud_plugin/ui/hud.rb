# frozen_string_literal: true

module PointCloudPlugin
  module UI
    # Simple heads-up display showing import progress and stats.
    class Hud
      attr_reader :metrics

      def initialize
        @metrics = {}
      end

      def update(new_metrics)
        @metrics.merge!(new_metrics)
      end

      def draw(view)
        return unless view.respond_to?(:draw_text)

        lines = metrics.map { |key, value| "#{key}: #{value}" }
        origin = Geom::Point3d.new(20, 40, 0)
        view.draw_text(origin, lines.join("\n"))
      end
    end
  end
end
