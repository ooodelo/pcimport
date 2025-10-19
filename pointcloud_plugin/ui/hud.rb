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

        lines = format_metrics
        return if lines.empty?

        text = lines.join("\n")
        options = text_options
        text_size = extent_for(view, text, options)
        origin = text_origin(view, text_size)

        draw_outline(view, origin, text, options)
        view.draw_text(origin, text, options)
      end

      private

      PRIORITY_KEYS = %w[fps load_status load_speed points_on_screen memory_notice].freeze

      def format_metrics
        PRIORITY_KEYS.filter_map do |key|
          value = metrics[key.to_sym] || metrics[key]
          next if value.nil?

          "#{humanize_key(key)}: #{format_value(value)}"
        end
      end

      def humanize_key(key)
        key.to_s.split('_').map(&:capitalize).join(' ')
      end

      def format_value(value)
        case value
        when Numeric
          format_number(value)
        else
          value
        end
      end

      def format_number(value)
        number = value.to_f
        return number.round(2) if number.between?(-1_000, 1_000)

        thresholds = [
          [1_000_000_000, 'B'],
          [1_000_000, 'M'],
          [1_000, 'K']
        ]

        thresholds.each do |limit, suffix|
          next unless number.abs >= limit

          scaled = number / limit
          return format('%.1f%s', scaled, suffix)
        end

        number.round
      end

      def extent_for(view, text, options)
        return [0, 0] unless view.respond_to?(:text_extent)

        result = view.text_extent(text, options)
        valid_extent(result)
      rescue ArgumentError
        valid_extent(view.text_extent(text))
      end

      def valid_extent(value)
        return [0, 0] unless value.is_a?(Array) && value.length >= 2

        [value[0], value[1]]
      end

      def text_origin(view, text_size)
        margin = 20
        width = view.respond_to?(:vpwidth) ? view.vpwidth : 0

        x = [width - margin - text_size[0], margin].max
        y = margin + text_size[1]
        Geom::Point3d.new(x, y, 0)
      end

      def draw_outline(view, origin, text, options)
        outline_color = Sketchup::Color.new(0, 0, 0)
        outline_options = options.merge(color: outline_color)
        offsets = [[-1, 0], [1, 0], [0, -1], [0, 1]]

        offsets.each do |dx, dy|
          point = Geom::Point3d.new(origin.x + dx, origin.y + dy, origin.z)
          view.draw_text(point, text, outline_options)
        end
      end

      def text_options
        {
          color: Sketchup::Color.new(255, 255, 255),
          size: 12
        }
      end
    end
  end
end
