# frozen_string_literal: true

module PointCloudPlugin
  module Core
    # Utility helpers for converting units between metric, imperial and model units.
    module Units
      UNIT_TO_METERS = {
        meter: 1.0,
        millimeter: 0.001,
        centimeter: 0.01,
        kilometer: 1000.0,
        inch: 0.0254,
        foot: 0.3048,
        yard: 0.9144
      }.freeze

      module_function

      def scale_factor(from:, to: :meter)
        from_scale = UNIT_TO_METERS.fetch(from) { raise ArgumentError, "Unsupported unit: #{from}" }
        to_scale = UNIT_TO_METERS.fetch(to) { raise ArgumentError, "Unsupported unit: #{to}" }
        from_scale / to_scale
      end

      def convert(value, from:, to: :meter)
        value * scale_factor(from: from, to: to)
      end

      def normalize_point(point, from:, to: :meter)
        point.map { |component| convert(component, from: from, to: to) }
      end
    end
  end
end
