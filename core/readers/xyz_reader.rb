# frozen_string_literal: true

require_relative 'reader_base'

module PointCloudPlugin
  module Core
    module Readers
      # Simple XYZ reader supporting optional RGB and intensity columns.
      class XyzReader < ReaderBase
        def parse_line(line)
          tokens = line.strip.split
          return if tokens.size < 3

          position = tokens[0, 3].map(&:to_f)
          color_tokens = tokens[3, 3]
          color = if color_tokens && color_tokens.size == 3
                    values = color_tokens.map { |value| Integer(value) rescue nil }
                    values.compact.size == 3 ? values : nil
                  end
          intensity = tokens[6]&.to_f if tokens.size > 6

          point = { position: position }
          point[:color] = color if color
          point[:intensity] = intensity if intensity
          point
        end

        private

        def normalize(point)
          normalized = super
          normalized[:color] = normalized[:color]&.map { |component| component.clamp(0, 255) }
          normalized
        end
      end
    end
  end
end
