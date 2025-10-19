# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../../core/chunk_serializer'
require_relative '../../core/chunk'

module PointCloudPlugin
  module Core
    class ChunkSerializerTest < Minitest::Test
      def setup
        @tmpdir = Dir.mktmpdir('chunk-serializer-test')
        @serializer = ChunkSerializer.new
      end

      def teardown
        FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
      end

      def test_round_trip_preserves_chunk_data
        chunk = build_chunk(point_count: 5, with_rgb: true, with_intensity: true)
        path = File.join(@tmpdir, 'chunk.pccb')

        @serializer.write(path, chunk)
        loaded = @serializer.read(path)

        assert_equal chunk.count, loaded.count
        assert_equal chunk.positions[:x], loaded.positions[:x]
        assert_equal chunk.colors[:r], loaded.colors[:r]
        assert_equal chunk.intensities, loaded.intensities
        assert_equal chunk.metadata[:bounds], loaded.metadata[:bounds]
      end

      def test_payload_is_aligned_to_eight_bytes
        chunk = build_chunk(point_count: 3, with_rgb: true, with_intensity: true)
        path = File.join(@tmpdir, 'aligned.pccb')

        @serializer.write(path, chunk)

        size = File.size(path) - ChunkSerializer::HEADER_SIZE
        assert_equal 0, size % 8
      end

      def test_crc_validation_detects_corruption
        chunk = build_chunk(point_count: 4)
        path = File.join(@tmpdir, 'corrupt.pccb')
        @serializer.write(path, chunk)

        File.open(path, 'rb+') do |io|
          io.seek(ChunkSerializer::HEADER_SIZE)
          byte = io.read(1).ord
          io.seek(ChunkSerializer::HEADER_SIZE)
          io.write([(byte ^ 0xFF)].pack('C'))
        end

        assert_raises(ChunkSerializer::CorruptedData) { @serializer.read(path) }
      end

      private

      def build_chunk(point_count:, with_rgb: false, with_intensity: false)
        positions = {
          x: Array.new(point_count) { |i| i },
          y: Array.new(point_count) { |i| i * 2 },
          z: Array.new(point_count) { |i| i * 3 }
        }

        colors = if with_rgb
                   {
                     r: Array.new(point_count) { |i| (i * 10) % 256 },
                     g: Array.new(point_count) { |i| (i * 20) % 256 },
                     b: Array.new(point_count) { |i| (i * 30) % 256 }
                   }
                 else
                   { r: [], g: [], b: [] }
                 end

        intensities = with_intensity ? Array.new(point_count) { |i| (i * 5) % 256 } : []

        bounds = {
          min: [0.0, 0.0, 0.0],
          max: [point_count.to_f, (point_count * 2).to_f, (point_count * 3).to_f]
        }

        metadata = { bounds: bounds, quantization_bits: 16 }

        Chunk.new(
          origin: [0.0, 0.0, 0.0],
          scale: 0.001,
          positions: positions,
          colors: colors,
          intensities: intensities,
          metadata: metadata
        )
      end
    end
  end
end
