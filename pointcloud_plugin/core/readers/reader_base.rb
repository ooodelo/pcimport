# frozen_string_literal: true

require_relative '../units'

module PointCloudPlugin
  module Core
    module Readers
      # Base class for streaming point cloud readers.
      class ReaderBase
        attr_reader :path, :batch_size, :unit, :offset

        def initialize(path, batch_size: 10_000, unit: :meter, offset: nil)
          @path = path
          @batch_size = batch_size
          @unit = unit.to_sym
          @offset = normalize_offset(offset)
          @offset_in_meters = Core::Units.normalize_point(@offset, from: @unit)
        end

        def each_batch
          return enum_for(:each_batch) unless block_given?

          open_stream do |stream|
            buffer = []

            stream.each_line do |line|
              point = parse_line(line)
              next unless point

              buffer << normalize(point)
              if buffer.size >= batch_size
                yield buffer
                buffer = []
              end
            end

            yield buffer unless buffer.empty?
          end
        end

        private

        def open_stream
          File.open(path, 'rb') do |file|
            yield file
          end
        end

        def parse_line(_line)
          raise NotImplementedError
        end

        def normalize(point)
          normalized = Core::Units.normalize_point(point[:position], from: unit)
          adjusted = normalized.each_with_index.map do |value, index|
            value - @offset_in_meters[index]
          end
          point[:position] = adjusted
          point
        end

        def normalize_offset(offset)
          values = case offset
                   when Hash
                     extract_offset_from_hash(offset)
                   when Array
                     offset.first(3)
                   else
                     []
                   end

          [values[0] || 0.0, values[1] || 0.0, values[2] || 0.0].map(&:to_f)
        end

        def extract_offset_from_hash(offset)
          keys = %i[x y z]
          keys.map do |axis|
            value = offset[axis]
            value = offset[axis.to_s] if value.nil?
            value
          end
        end
      end
    end
  end
end
