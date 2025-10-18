# frozen_string_literal: true

require_relative 'reader_base'

module PointCloudPlugin
  module Core
    module Readers
      # Streaming PLY reader that supports binary little-endian point data.
      class PlyReader < ReaderBase
        TYPE_LAYOUT = {
          'char' => { size: 1, directive: 'c' },
          'int8' => { size: 1, directive: 'c' },
          'uchar' => { size: 1, directive: 'C' },
          'uint8' => { size: 1, directive: 'C' },
          'short' => { size: 2, directive: 's<' },
          'int16' => { size: 2, directive: 's<' },
          'ushort' => { size: 2, directive: 'S<' },
          'uint16' => { size: 2, directive: 'S<' },
          'int' => { size: 4, directive: 'l<' },
          'int32' => { size: 4, directive: 'l<' },
          'uint' => { size: 4, directive: 'L<' },
          'uint32' => { size: 4, directive: 'L<' },
          'float' => { size: 4, directive: 'e' },
          'float32' => { size: 4, directive: 'e' },
          'double' => { size: 8, directive: 'E' },
          'float64' => { size: 8, directive: 'E' }
        }.freeze

        VERTEX_CHUNK_SIZE = 1_000_000

        def each_batch
          return enum_for(:each_batch) unless block_given?

          open_stream do |stream|
            header = parse_header(stream)

            case header[:format]
            when 'binary_little_endian'
              # supported
            when 'ascii'
              raise ArgumentError, 'PLY ASCII format is not supported.'
            when 'binary_big_endian'
              raise ArgumentError, 'PLY binary_big_endian format is not supported.'
            else
              raise ArgumentError, "Unsupported PLY format '#{header[:format] || 'unknown'}'."
            end

            vertex_count = header[:vertex_count]
            raise ArgumentError, 'PLY file does not declare a vertex element.' unless vertex_count

            stride = header[:stride]
            raise ArgumentError, 'PLY vertex properties are missing or unsupported.' if stride.to_i <= 0

            format_directive = header[:format_directive]
            position_indices = header[:position_indices]
            color_indices = header[:color_indices]
            intensity_index = header[:intensity_index]

            remaining = vertex_count
            buffer = []

            while remaining.positive?
              chunk_vertices = [remaining, VERTEX_CHUNK_SIZE].min
              chunk_bytes = chunk_vertices * stride
              chunk_data = read_exact(stream, chunk_bytes)

              chunk_vertices.times do |index|
                start = index * stride
                values = chunk_data.unpack("@#{start}#{format_directive}")
                point = extract_point(values, position_indices, color_indices, intensity_index)
                next unless point

                buffer << normalize(point)
                next unless buffer.size >= batch_size

                yield buffer
                buffer = []
              end

              remaining -= chunk_vertices
            end

            yield buffer unless buffer.empty?
          end
        end

        private

        def parse_header(stream)
          header = { properties: [] }
          current_element = nil
          end_header_found = false

          until stream.eof?
            line = stream.gets
            raise IOError, 'Unexpected end of PLY header.' unless line

            line = line.strip
            next if line.empty? || line.start_with?('comment') || line.start_with?('obj_info')

            case line
            when /^format\s+(\S+)\s+(\S+)/
              header[:format] = Regexp.last_match(1).downcase
              header[:version] = Regexp.last_match(2)
            when /^element\s+(\w+)\s+(\d+)/
              current_element = Regexp.last_match(1)
              header[:vertex_count] = Regexp.last_match(2).to_i if current_element == 'vertex'
            when /^property\s+list/
              raise ArgumentError, 'PLY list properties are not supported for vertex elements.' if current_element == 'vertex'
            when /^property\s+(\w+)\s+(\w+)/
              next unless current_element == 'vertex'

              type = Regexp.last_match(1).downcase
              name = Regexp.last_match(2)
              header[:properties] << { type: type, name: name }
            when 'end_header'
              end_header_found = true
              break
            end
          end

          raise IOError, 'PLY header is missing end_header marker.' unless end_header_found

          build_layout(header)
        end

        def build_layout(header)
          properties = header[:properties]
          raise ArgumentError, 'PLY vertex properties are missing.' if properties.empty?

          layout = []
          offset = 0

          properties.each do |property|
            type_info = TYPE_LAYOUT[property[:type]]
            raise ArgumentError, "Unsupported PLY property type '#{property[:type]}'." unless type_info

            layout << {
              name: property[:name],
              type: property[:type],
              offset: offset,
              size: type_info[:size],
              directive: type_info[:directive]
            }
            offset += type_info[:size]
          end

          stride = offset
          layout.each { |entry| entry[:stride] = stride }

          header[:properties] = layout
          header[:stride] = stride
          header[:format_directive] = layout.map { |entry| entry[:directive] }.join
          header[:indices] = layout.each_with_index.each_with_object({}) do |(property, index), indices|
            indices[property[:name]] = index
          end
          header[:position_indices] = %w[x y z].map { |name| header[:indices][name] }
          header[:color_indices] = %w[red green blue].map { |name| header[:indices][name] }
          header[:intensity_index] = header[:indices]['intensity']

          header
        end

        def read_exact(stream, length)
          return ''.b if length.zero?

          data = ''.b
          while data.bytesize < length
            chunk = stream.read(length - data.bytesize)
            raise IOError, 'Unexpected end of PLY vertex data.' unless chunk && !chunk.empty?

            data << chunk
          end
          data
        end

        def extract_point(values, position_indices, color_indices, intensity_index)
          x = fetch_value(values, position_indices[0])
          y = fetch_value(values, position_indices[1])
          z = fetch_value(values, position_indices[2])
          return unless x && y && z

          color_values = color_indices.map { |index| fetch_value(values, index) }
          intensity = fetch_value(values, intensity_index)

          {
            position: [x.to_f, y.to_f, z.to_f],
            color: color_values.compact.empty? ? nil : color_values.map { |value| value.to_i },
            intensity: intensity&.to_f
          }
        end

        def fetch_value(values, index)
          index.nil? ? nil : values[index]
        end
      end
    end
  end
end
