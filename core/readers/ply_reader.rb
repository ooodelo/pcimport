# frozen_string_literal: true

require_relative 'reader_base'

module PointCloudPlugin
  module Core
    module Readers
      # Minimal PLY ASCII reader suitable for streaming previews.
      class PlyReader < ReaderBase
        def each_batch
          return enum_for(:each_batch) unless block_given?

          open_stream do |stream|
            header = parse_header(stream)
            vertex_count = header[:vertex_count]
            properties = header[:properties]

            buffer = []
            vertex_count.times do
              line = stream.gets
              break unless line

              values = line.split.map { |value| Float(value) rescue value }
              point = extract_point(values, properties)
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

        def parse_header(stream)
          header = { properties: [] }
          until stream.eof?
            line = stream.gets.strip
            case line
            when /^element\s+vertex\s+(\d+)/
              header[:vertex_count] = Regexp.last_match(1).to_i
            when /^property\s+(\w+)\s+(\w+)/
              header[:properties] << { type: Regexp.last_match(1), name: Regexp.last_match(2) }
            when 'end_header'
              break
            end
          end
          header
        end

        def extract_point(values, properties)
          x = fetch_property(values, properties, 'x')
          y = fetch_property(values, properties, 'y')
          z = fetch_property(values, properties, 'z')
          return unless x && y && z

          color = %w[red green blue].map { |prop| fetch_property(values, properties, prop) }
          intensity = fetch_property(values, properties, 'intensity')

          {
            position: [x.to_f, y.to_f, z.to_f],
            color: color.compact.empty? ? nil : color.map(&:to_i),
            intensity: intensity&.to_f
          }
        end

        def fetch_property(values, properties, name)
          index = properties.index { |property| property[:name] == name }
          index ? values[index] : nil
        end
      end
    end
  end
end
