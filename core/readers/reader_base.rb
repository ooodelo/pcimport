# frozen_string_literal: true

require_relative '../units'

module PointCloudPlugin
  module Core
    module Readers
      # Base class for streaming point cloud readers.
      class ReaderBase
        attr_reader :path, :batch_size, :unit

        def initialize(path, batch_size: 10_000, unit: :meter)
          @path = path
          @batch_size = batch_size
          @unit = unit
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
          point[:position] = Core::Units.normalize_point(point[:position], from: unit)
          point
        end
      end
    end
  end
end
