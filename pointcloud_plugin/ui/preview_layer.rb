module PointCloud
  module UI
    module PreviewLayer
      module_function

      SAMPLE_LIMIT = 2_000
      POINT_SIZE = 1

      def draw(view, tool)
        return unless view.respond_to?(:draw_points)
        return unless tool.respond_to?(:reservoir_samples)
        return unless tool.respond_to?(:last_drawn_point_count)
        return unless tool.last_drawn_point_count.to_i.zero?

        samples = tool.reservoir_samples(SAMPLE_LIMIT)
        return if samples.nil? || samples.empty?

        points = samples.map { |sample| to_point(sample) }.compact
        return if points.empty?

        view.draw_points(points, POINT_SIZE, 1, preview_color)
      end

      def to_point(sample)
        position = extract_position(sample)
        return unless position

        Geom::Point3d.new(*position)
      end

      def extract_position(sample)
        if sample.respond_to?(:[]) && sample[:position]
          coords = sample[:position]
        elsif sample.respond_to?(:position)
          coords = sample.position
        elsif sample.respond_to?(:to_a)
          coords = sample.to_a
        end

        return unless coords.is_a?(Array) && coords.length >= 3

        coords.first(3)
      end

      def preview_color
        if defined?(Sketchup::Color)
          Sketchup::Color.new(0, 0, 0)
        else
          'black'
        end
      end
      private_class_method :to_point, :extract_position, :preview_color
    end
  end
end
