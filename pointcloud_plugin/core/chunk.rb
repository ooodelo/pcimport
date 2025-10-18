# frozen_string_literal: true

require_relative 'units'

module PointCloudPlugin
  module Core
    # Represents a quantized chunk of point cloud data stored as structure of arrays.
    class Chunk
      attr_reader :origin, :scale, :positions, :colors, :intensities, :metadata

      def initialize(origin:, scale:, positions:, colors: nil, intensities: nil, metadata: {})
        @origin = origin
        @scale = scale
        @positions = positions
        @colors = colors || { r: [], g: [], b: [] }
        @intensities = intensities || []
        @metadata = metadata
      end

      def size
        positions[:x].size
      end

      def each_point
        return enum_for(:each_point) unless block_given?

        size.times do |index|
          yield point_at(index)
        end
      end

      def point_at(index)
        position = [
          positions[:x][index] * scale + origin[0],
          positions[:y][index] * scale + origin[1],
          positions[:z][index] * scale + origin[2]
        ]

        color = if colors[:r][index]
                  [colors[:r][index], colors[:g][index], colors[:b][index]]
                end

        intensity = intensities[index]

        { position: position, color: color, intensity: intensity }
      end
    end

    # Converts raw points into quantized chunk representation.
    class ChunkPacker
      DEFAULT_BITS = 16

      def initialize(quantization_bits: DEFAULT_BITS, input_unit: :meter, offset: { x: 0.0, y: 0.0, z: 0.0 })
        @quantization_bits = quantization_bits
        @input_unit = input_unit.to_sym
        @offset = normalize_offset(offset)
      end

      def pack(points)
        return Chunk.new(origin: [0.0, 0.0, 0.0], scale: 1.0, positions: { x: [], y: [], z: [] }) if points.empty?

        normalized_points = points.map do |point|
          normalized_position = Core::Units.normalize_point(point[:position], from: @input_unit)
          adjusted_position = normalized_position.each_with_index.map do |component, axis|
            component - @offset[axis]
          end
          point.merge(position: adjusted_position)
        end

        bounds = compute_bounds(normalized_points)
        origin = bounds[:min]
        scale = compute_scale(bounds[:max], origin)

        positions = { x: [], y: [], z: [] }
        colors = { r: [], g: [], b: [] }
        intensities = []

        normalized_points.each do |point|
          quantized = quantize(point[:position], origin, scale)
          positions[:x] << quantized[0]
          positions[:y] << quantized[1]
          positions[:z] << quantized[2]

          if point[:color]
            colors[:r] << point[:color][0]
            colors[:g] << point[:color][1]
            colors[:b] << point[:color][2]
          end

          intensities << point[:intensity] if point.key?(:intensity)
        end

        metadata = { bounds: bounds, quantization_bits: @quantization_bits }
        Chunk.new(origin: origin, scale: scale, positions: positions, colors: colors, intensities: intensities, metadata: metadata)
      end

      private

      def compute_bounds(points)
        mins = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
        maxs = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]

        points.each do |point|
          3.times do |axis|
            value = point[:position][axis]
            mins[axis] = value if value < mins[axis]
            maxs[axis] = value if value > maxs[axis]
          end
        end

        { min: mins, max: maxs }
      end

      def compute_scale(maxs, origin)
        range = maxs.each_with_index.map { |value, axis| value - origin[axis] }
        max_range = range.max
        max_range.zero? ? 1.0 : max_range / ((1 << @quantization_bits) - 1)
      end

      def quantize(position, origin, scale)
        position.each_with_index.map do |value, axis|
          ((value - origin[axis]) / scale).clamp(0, (1 << @quantization_bits) - 1).round
        end
      end

      def normalize_offset(offset)
        components = case offset
                     when Hash
                       %i[x y z].map { |axis| offset[axis] || offset[axis.to_s] || 0.0 }
                     when Array
                       offset.first(3)
                     when Numeric
                       [offset, offset, offset]
                     else
                       [0.0, 0.0, 0.0]
                     end

        components = components.map(&:to_f)
        components << 0.0 while components.length < 3
        components = components.first(3)

        components.map do |value|
          Core::Units.convert(value, from: @input_unit)
        end
      end
    end
  end
end
