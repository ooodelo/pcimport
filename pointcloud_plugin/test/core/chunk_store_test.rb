# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../../core/chunk_store'
require_relative '../../core/chunk_serializer'
require_relative '../../core/manifest'
require_relative '../../core/chunk'

module PointCloudPlugin
  module Core
    class ChunkStoreTest < Minitest::Test
      class FakeChunk
        attr_reader :memory_bytes

        def initialize(memory_bytes)
          @memory_bytes = memory_bytes
        end
      end

      def setup
        @cache_dir = Dir.mktmpdir('chunk-store-test')
        @manifest = Manifest.new(cache_path: @cache_dir)
      end

      def teardown
        FileUtils.remove_entry(@cache_dir) if @cache_dir && Dir.exist?(@cache_dir)
      end

      def test_applies_memory_limit_during_initialization
        store = ChunkStore.new(cache_path: @cache_dir, memory_limit_mb: 1, manifest: @manifest)

        store.stub(:persist_to_disk, nil) do
          store.store('first', FakeChunk.new(800_000))
          store.store('second', FakeChunk.new(800_000))
        end

        keys_in_memory = store.each_in_memory.map { |key, _chunk| key }

        assert_equal ['second'], keys_in_memory
      end

      def test_notifies_on_memory_pressure_once
        store = ChunkStore.new(cache_path: @cache_dir, memory_limit_mb: 1, manifest: @manifest)
        notifications = []

        store.on_memory_pressure do |freed_bytes, limit_bytes|
          notifications << [freed_bytes, limit_bytes]
        end

        store.stub(:persist_to_disk, nil) do
          store.store('first', FakeChunk.new(800_000))
          store.store('second', FakeChunk.new(800_000))
          store.store('third', FakeChunk.new(400_000))
        end

        assert_equal 1, notifications.length
        freed_bytes, limit_bytes = notifications.first
        assert_in_delta 800_000, freed_bytes, 1_000
        assert_equal store.memory_limit_bytes, limit_bytes
      end

      def test_persist_and_fetch_round_trip
        store = ChunkStore.new(cache_path: @cache_dir, manifest: @manifest)
        chunk = build_chunk('round', point_count: 4, with_rgb: true, with_intensity: true)

        store.store('round', chunk)
        store.release('round')

        fetched = store.fetch('round')

        refute_nil fetched
        assert_equal chunk.count, fetched.count
        assert_equal chunk.positions[:x], fetched.positions[:x]
        assert_includes @manifest.chunks, 'round.pccb'
        assert_equal ChunkSerializer::VERSION, @manifest.chunk_format_version
      end

      def test_fetch_rebuilds_legacy_chunks
        chunk = build_chunk('legacy', point_count: 3)
        legacy_path = File.join(@cache_dir, 'legacy.chunk')
        File.binwrite(legacy_path, Marshal.dump(chunk))
        @manifest.chunks = ['legacy.chunk']

        store = ChunkStore.new(cache_path: @cache_dir, manifest: @manifest)

        fetched = store.fetch('legacy')

        refute_nil fetched
        refute File.exist?(legacy_path)
        assert File.exist?(File.join(@cache_dir, 'legacy.pccb'))
        assert_equal ['legacy.pccb'], @manifest.chunks
        assert_equal ChunkSerializer::VERSION, @manifest.chunk_format_version
      end

      def test_corrupted_chunk_is_rebuilt_from_legacy
        chunk = build_chunk('corrupt', point_count: 2)
        serializer = ChunkSerializer.new
        pccb_path = File.join(@cache_dir, 'corrupt.pccb')
        serializer.write(pccb_path, chunk)
        corrupt_bytes = File.binread(pccb_path)
        File.binwrite(pccb_path, corrupt_bytes.reverse)
        legacy_path = File.join(@cache_dir, 'corrupt.chunk')
        File.binwrite(legacy_path, Marshal.dump(chunk))
        @manifest.chunks = ['corrupt.pccb', 'corrupt.chunk']

        store = ChunkStore.new(cache_path: @cache_dir, manifest: @manifest)

        fetched = store.fetch('corrupt')

        refute_nil fetched
        assert File.exist?(pccb_path)
        refute File.exist?(legacy_path)
        assert_equal ['corrupt.pccb'], @manifest.chunks
      end

      def test_corrupted_chunk_without_legacy_is_deleted
        chunk = build_chunk('orphan', point_count: 2)
        serializer = ChunkSerializer.new
        pccb_path = File.join(@cache_dir, 'orphan.pccb')
        serializer.write(pccb_path, chunk)
        File.open(pccb_path, 'rb+') { |io| io.write('BAD!') }
        @manifest.chunks = ['orphan.pccb']

        store = ChunkStore.new(cache_path: @cache_dir, manifest: @manifest)

        result = store.fetch('orphan')

        assert_nil result
        refute File.exist?(pccb_path)
        assert_empty @manifest.chunks
      end

      private

      def build_chunk(key, point_count:, with_rgb: false, with_intensity: false)
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
        metadata[:key] = key

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
