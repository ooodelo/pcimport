# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../../core/chunk_store'

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
      end

      def teardown
        FileUtils.remove_entry(@cache_dir) if @cache_dir && Dir.exist?(@cache_dir)
      end

      def test_applies_memory_limit_during_initialization
        store = ChunkStore.new(cache_path: @cache_dir, memory_limit_mb: 1)

        store.store('first', FakeChunk.new(800_000))
        store.store('second', FakeChunk.new(800_000))

        keys_in_memory = store.each_in_memory.map { |key, _chunk| key }

        assert_equal ['second'], keys_in_memory
      end
    end
  end
end
