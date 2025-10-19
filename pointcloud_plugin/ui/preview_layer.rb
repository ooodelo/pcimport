module PointCloud
  module UI
    module PreviewLayer
      module_function

      PREVIEW_POINT_LIMIT = 2_000
      PREVIEW_POINT_SIZE = 1

      def draw(view, tool)
        return unless view.respond_to?(:draw_points)
        return unless tool.respond_to?(:preview_samples)
        return unless tool.respond_to?(:last_drawn_point_count)
        return unless tool.last_drawn_point_count.to_i.zero?

        samples = tool.preview_samples(PREVIEW_POINT_LIMIT)
        return if samples.nil? || samples.empty?

        points = samples.each_with_object([]) do |sample, collection|
          point = extract_point(sample)
          collection << point if point
        end
        return if points.empty?

        view.draw_points(points, PREVIEW_POINT_SIZE, 1, preview_color(tool))
      end

      def extract_point(sample)
        position = extract_position(sample)
        return unless position

        to_point3d(position)
      end

      def extract_position(sample)
        if sample.respond_to?(:key?)
          if sample.key?(:position)
            position = sample[:position]
            return normalize_coordinates(position) if position
          end

          if sample.key?('position')
            position = sample['position']
            return normalize_coordinates(position) if position
          end
        elsif sample.respond_to?(:[])
          position = safe_position_lookup(sample, :position)
          position ||= safe_position_lookup(sample, 'position')
          return normalize_coordinates(position) if position
        end

        if sample.respond_to?(:position)
          position = sample.position
          return normalize_coordinates(position) if position
        end

        if sample.respond_to?(:x) && sample.respond_to?(:y) && sample.respond_to?(:z)
          return [sample.x, sample.y, sample.z]
        end

        if sample.respond_to?(:to_a)
          return normalize_coordinates(sample.to_a)
        end

        normalize_coordinates(sample)
      end

      def normalize_coordinates(value)
        return unless value

        coordinates = value.is_a?(Array) ? value : (value.respond_to?(:to_a) ? value.to_a : nil)
        return unless coordinates && coordinates.length >= 3

        coordinates[0, 3]
      end

      def to_point3d(coords)
        if defined?(Geom::Point3d)
          Geom::Point3d.new(coords[0], coords[1], coords[2])
        else
          coords
        end
      end

      def preview_color(tool)
        if defined?(Sketchup::Color)
          Sketchup::Color.new(0, 0, 0)
        elsif tool.respond_to?(:default_point_color, true)
          tool.send(:default_point_color)
        else
          fallback_color
        end
      end

      def fallback_color
        @fallback_color ||= Struct.new(:red, :green, :blue, :alpha).new(0, 0, 0, 255)
      end

      def safe_position_lookup(sample, key)
        sample[key]
      rescue StandardError, NameError
        nil
      end
    end
  end
end
