# frozen_string_literal: true

require 'zlib'
require 'stringio'

require_relative 'chunk'

module PointCloudPlugin
  module Core
    # Serializes chunk data to the PCCB (Point Cloud Chunk Binary) format.
    class ChunkSerializer
      MAGIC = 'PCCB'
      VERSION = 1
      HEADER_SIZE = 64

      FLAG_HAS_RGB = 0x01
      FLAG_HAS_INTENSITY = 0x02
      FLAG_EMPTY = 0x04
      FLAG_QUANT_BITS_SHIFT = 8
      FLAG_QUANT_BITS_MASK = 0xFF << FLAG_QUANT_BITS_SHIFT

      class Error < StandardError; end
      class InvalidHeader < Error; end
      class CorruptedData < Error; end

      def write(path, chunk)
        header, payload = serialize(chunk)
        File.binwrite(path, header + payload)
      end

      def read(path)
        File.open(path, 'rb') do |io|
          header_bytes = io.read(HEADER_SIZE)
          raise InvalidHeader, 'header truncated' unless header_bytes&.bytesize == HEADER_SIZE

          magic, version, header_size, count, payload_length, flags, *floats, crc =
            header_bytes.unpack('a4 S< S< L< L< L< e10 L<')

          raise InvalidHeader, "unexpected magic #{magic.inspect}" unless magic == MAGIC
          raise InvalidHeader, "unsupported version #{version}" unless version == VERSION
          raise InvalidHeader, "unexpected header size #{header_size}" unless header_size == HEADER_SIZE

          payload = io.read(payload_length.to_i)
          raise CorruptedData, 'payload truncated' unless payload&.bytesize == payload_length.to_i

          computed_crc = Zlib.crc32(payload)
          raise CorruptedData, 'CRC mismatch' unless computed_crc == crc

          bbox_min = floats[0, 3]
          bbox_max = floats[3, 3]
          origin = floats[6, 3]
          scale = floats[9]

          quant_bits = ((flags & FLAG_QUANT_BITS_MASK) >> FLAG_QUANT_BITS_SHIFT)
          has_rgb = (flags & FLAG_HAS_RGB).positive?
          has_intensity = (flags & FLAG_HAS_INTENSITY).positive?
          empty = (flags & FLAG_EMPTY).positive?

          chunk = build_chunk(count, payload, has_rgb, has_intensity, origin, scale, bbox_min, bbox_max, quant_bits, empty)
          chunk
        end
      end

      private

      def serialize(chunk)
        count = chunk.count
        origin = Array(chunk.origin || [0.0, 0.0, 0.0])
        scale = chunk.scale || 1.0
        quant_bits = quantization_bits(chunk)
        has_rgb = chunk.has_rgb?
        has_intensity = chunk.has_intensity?
        empty = chunk.respond_to?(:empty?) ? chunk.empty? : false

        flags = 0
        flags |= FLAG_HAS_RGB if has_rgb
        flags |= FLAG_HAS_INTENSITY if has_intensity
        flags |= FLAG_EMPTY if empty
        flags |= (quant_bits << FLAG_QUANT_BITS_SHIFT)

        bbox = bounds(chunk)
        bbox_min = bbox[:min]
        bbox_max = bbox[:max]

        payload = build_payload(chunk, count, has_rgb, has_intensity)
        crc = Zlib.crc32(payload)

        header = [
          MAGIC,
          VERSION,
          HEADER_SIZE,
          count,
          payload.bytesize,
          flags,
          *bbox_min,
          *bbox_max,
          *origin,
          scale,
          crc
        ].pack('a4 S< S< L< L< L< e10 L<')

        [header, payload]
      end

      def build_payload(chunk, count, has_rgb, has_intensity)
        payload = String.new(encoding: Encoding::BINARY)
        payload << pack_coordinates(chunk, :x, count)
        payload << pack_coordinates(chunk, :y, count)
        payload << pack_coordinates(chunk, :z, count)

        if has_rgb
          payload << pack_bytes(chunk.colors[:r], count)
          payload << pack_bytes(chunk.colors[:g], count)
          payload << pack_bytes(chunk.colors[:b], count)
        end

        payload << pack_bytes(chunk.intensities, count) if has_intensity

        padding = (8 - (payload.bytesize % 8)) % 8
        payload << ("\x00".b * padding) if padding.positive?
        payload
      end

      def pack_coordinates(chunk, axis, count)
        values = Array.new(count) do |index|
          (chunk.positions[axis][index] || 0).to_f
        end
        values.pack("e#{count}")
      end

      def pack_bytes(values, count)
        array = Array.new(count) do |index|
          value = values && values[index]
          value.nil? ? 0 : value.to_i & 0xFF
        end
        array.pack("C#{count}")
      end

      def quantization_bits(chunk)
        metadata = chunk.metadata if chunk.respond_to?(:metadata)
        return metadata[:quantization_bits] if metadata.is_a?(Hash) && metadata[:quantization_bits]
        return metadata['quantization_bits'] if metadata.is_a?(Hash) && metadata['quantization_bits']

        0
      rescue StandardError
        0
      end

      def bounds(chunk)
        metadata = chunk.metadata if chunk.respond_to?(:metadata)
        if metadata.is_a?(Hash)
          bounds = metadata[:bounds] || metadata['bounds']
          if bounds.is_a?(Hash)
            min = bounds[:min] || bounds['min']
            max = bounds[:max] || bounds['max']
            if valid_bounds?(min, max)
              return { min: min.first(3), max: max.first(3) }
            end
          end
        end

        compute_bounds(chunk)
      end

      def valid_bounds?(min, max)
        min.is_a?(Array) && max.is_a?(Array) && min.length >= 3 && max.length >= 3
      end

      def compute_bounds(chunk)
        origin = Array(chunk.origin || [0.0, 0.0, 0.0])
        scale = chunk.scale || 1.0

        min = [Float::INFINITY, Float::INFINITY, Float::INFINITY]
        max = [-Float::INFINITY, -Float::INFINITY, -Float::INFINITY]

        count = chunk.count
        count.times do |index|
          px = origin[0] + scale * (chunk.positions[:x][index] || 0)
          py = origin[1] + scale * (chunk.positions[:y][index] || 0)
          pz = origin[2] + scale * (chunk.positions[:z][index] || 0)

          min[0] = px if px < min[0]
          min[1] = py if py < min[1]
          min[2] = pz if pz < min[2]
          max[0] = px if px > max[0]
          max[1] = py if py > max[1]
          max[2] = pz if pz > max[2]
        end

        if count.zero?
          min = origin.first(3)
          max = origin.first(3)
        end

        { min: min, max: max }
      end

      def build_chunk(count, payload, has_rgb, has_intensity, origin, scale, bbox_min, bbox_max, quant_bits, empty)
        io = StringIO.new(payload)
        positions = {
          x: unpack_floats(io, count).map { |value| value.round.to_i },
          y: unpack_floats(io, count).map { |value| value.round.to_i },
          z: unpack_floats(io, count).map { |value| value.round.to_i }
        }

        colors = { r: [], g: [], b: [] }
        if has_rgb
          colors[:r] = unpack_bytes(io, count)
          colors[:g] = unpack_bytes(io, count)
          colors[:b] = unpack_bytes(io, count)
        end

        intensities = has_intensity ? unpack_bytes(io, count) : []

        metadata = {
          bounds: { min: bbox_min, max: bbox_max },
          quantization_bits: quant_bits
        }
        metadata[:empty] = true if empty

        Chunk.new(
          origin: origin,
          scale: scale,
          positions: positions,
          colors: colors,
          intensities: intensities,
          metadata: metadata
        )
      end

      def unpack_floats(io, count)
        return [] if count.to_i.zero?

        bytes = io.read(count * 4)
        raise CorruptedData, 'coordinate payload truncated' unless bytes&.bytesize == count * 4

        bytes.unpack("e#{count}")
      end

      def unpack_bytes(io, count)
        return [] if count.to_i.zero?

        bytes = io.read(count)
        raise CorruptedData, 'attribute payload truncated' unless bytes&.bytesize == count

        bytes.unpack("C#{count}")
      end
    end
  end
end
