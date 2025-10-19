# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/chunk'
require_relative '../../../core/lod/prefetcher'

module PointCloudPlugin
  module Core
    module Lod
      class PrefetcherTest < Minitest::Test
        class FakeStore
          attr_reader :prefetch_calls

          def initialize
            @chunks = {}
            @prefetch_calls = []
          end

          def store(key, chunk)
            @chunks[key] = chunk
          end

          def fetch(key)
            @chunks[key]
          end

          def release(key)
            @chunks.delete(key)
          end

          def prefetch(keys)
            @prefetch_calls << keys
          end

          def each_in_memory
            return enum_for(:each_in_memory) unless block_given?

            @chunks.each do |key, chunk|
              yield key, chunk
            end
          end
        end

        class CountingIndexBuilder < Spatial::IndexBuilder
          attr_reader :build_calls

          def initialize(*args)
            @build_calls = 0
            super
          end

          def build
            @build_calls += 1
            super
          end
        end

        def setup
          @store = FakeStore.new
          @index_builder = CountingIndexBuilder.new(@store)
          @prefetcher = Prefetcher.new(@store, index_builder: @index_builder)
        end

        def test_rebuild_occurs_only_when_store_changes
          store_chunk('a', center: [0, 0, 0])
          store_chunk('b', center: [2, 0, 0])
          store_chunk('c', center: [4, 0, 0])

          @prefetcher.prefetch_for_view([])

          assert_equal 1, @index_builder.build_calls

          store_chunk('d', center: [1, 0, 0])

          @prefetcher.prefetch_for_view([])

          assert_equal 1, @index_builder.build_calls

          @store.release('b')

          @prefetcher.prefetch_for_view([])

          assert_equal 2, @index_builder.build_calls
        end

        def test_configure_updates_internal_weights
          @prefetcher.configure(max_prefetch: 12, angle_weight: 5.5, distance_weight: 2.5, forward_threshold: 0.2)

          assert_equal 12, @prefetcher.max_prefetch
          assert_in_delta 5.5, @prefetcher.angle_weight
          assert_in_delta 2.5, @prefetcher.distance_weight
          assert_in_delta 0.2, @prefetcher.forward_cosine_threshold
        end

        private

        def store_chunk(key, center: [0, 0, 0])
          chunk = build_chunk(center: center)
          @store.store(key, chunk)
        end

        def build_chunk(center: [0.0, 0.0, 0.0])
          bounds = {
            min: center.map { |value| value - 0.5 },
            max: center.map { |value| value + 0.5 }
          }

          positions = {
            x: [0],
            y: [0],
            z: [0]
          }

          colors = {
            r: [0],
            g: [0],
            b: [0]
          }

          intensities = [0]

          Core::Chunk.new(
            origin: [0.0, 0.0, 0.0],
            scale: 1.0,
            positions: positions,
            colors: colors,
            intensities: intensities,
            metadata: { bounds: bounds }
          )
        end
      end
    end
  end
end
