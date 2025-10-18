# frozen_string_literal: true

require_relative 'morton'

module PointCloudPlugin
  module Core
    module Spatial
      # Builds a spatial index for chunks using Morton ordering.
      class IndexBuilder
        def initialize(chunk_store)
          @chunk_store = chunk_store
        end

        DEFAULT_QUANTIZATION_BITS = 16

        AXIS_KEYS = %i[x y z].freeze

        def build
          entries = []
          @chunk_store.each_in_memory do |key, chunk|
            center = chunk.metadata[:bounds][:min]
                          .zip(chunk.metadata[:bounds][:max])
                          .map { |min, max| (min + max) * 0.5 }

            quantization_bits = chunk.metadata[:quantization_bits] || DEFAULT_QUANTIZATION_BITS
            max_value = (1 << quantization_bits) - 1
            origin = chunk.origin || [0.0, 0.0, 0.0]
            scales = axis_scales(chunk.scale)

            quantized_center = center.each_with_index.map do |component, axis|
              axis_origin = origin[axis] || 0.0
              axis_scale = scales[axis]
              relative = component - axis_origin
              quantized = axis_scale.zero? ? 0.0 : relative / axis_scale
              quantized.round.clamp(0, max_value)
            end

            code = Morton.encode(*quantized_center)
            entries << [key, code]
          end

          entries.sort_by { |entry| entry[1] }.map(&:first)
        end

        private

        def axis_scales(scale)
          case scale
          when Hash
            default = scale.values.compact.first || 1.0
            AXIS_KEYS.map { |axis| fetch_axis_scale(scale, axis, default) }
          when Array
            expand_array_scale(scale)
          else
            value = scale || 1.0
            [value, value, value]
          end.map { |value| sanitize_scale(value) }
        end

        def fetch_axis_scale(scale, axis, default)
          scale[axis] || scale[axis.to_s] || default
        end

        def expand_array_scale(scale)
          return [1.0, 1.0, 1.0] if scale.empty?

          if scale.length >= 3
            scale.first(3)
          else
            Array.new(3, scale.first)
          end
        end

        def sanitize_scale(value)
          value = value.to_f
          value.zero? ? 1.0 : value
        end
      end
    end
  end
end
