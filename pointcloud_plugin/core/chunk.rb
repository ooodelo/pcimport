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

      def count
        size
      end

      def has_rgb?
        return false unless colors

        %i[r g b].all? { |channel| colors[channel]&.compact&.any? }
      end

      def has_intensity?
        intensities&.compact&.any?
      end

      def byte_size
        per_point = 6
        per_point += 3 if has_rgb?
        per_point += 2 if has_intensity?
        header = 64

        header + per_point * count
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

      def initialize(quantization_bits: DEFAULT_BITS, input_unit: :meter)
        @quantization_bits = quantization_bits
        @input_unit = input_unit
      end

      def pack(points)
        return Chunk.new(origin: [0.0, 0.0, 0.0], scale: 1.0, positions: { x: [], y: [], z: [] }) if points.empty?

        normalized_points = points.map do |point|
          normalized_position = Core::Units.normalize_point(point[:position], from: @input_unit)
          point.merge(position: normalized_position)
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
          else
            colors[:r] << nil
            colors[:g] << nil
            colors[:b] << nil
          end

          intensities << (point.key?(:intensity) ? point[:intensity] : nil)
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
    end
  end
end
