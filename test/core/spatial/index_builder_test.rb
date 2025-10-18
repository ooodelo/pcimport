# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/spatial/index_builder'
require_relative '../../../core/spatial/morton'

module PointCloudPlugin
  module Core
    module Spatial
      class IndexBuilderTest < Minitest::Test
        ChunkStub = Struct.new(:origin, :scale, :metadata)

        class FakeChunkStore
          def initialize(entries)
            @entries = entries
          end

          def each_in_memory
            return enum_for(:each_in_memory) unless block_given?

            @entries.each do |key, chunk|
              yield key, chunk
            end
          end
        end

        def test_morton_order_respects_translated_chunks
          chunk_a = build_chunk(
            origin: [1_000_000.0, 0.0, 0.0],
            scale: { x: 0.01, y: 0.01, z: 0.01 },
            bounds_max: [1_000_002.0, 2.0, 2.0]
          )
          chunk_b = build_chunk(
            origin: [2_000_000.0, 0.0, 0.0],
            scale: { x: 0.01, y: 0.01, z: 0.01 },
            bounds_max: [2_000_003.0, 2.0, 2.0]
          )
          chunk_c = build_chunk(
            origin: [3_000_000.0, 0.0, 0.0],
            scale: { x: 0.01, y: 0.01, z: 0.01 },
            bounds_max: [3_000_004.0, 2.0, 2.0]
          )

          store = FakeChunkStore.new([
            ['chunk_a', chunk_a],
            ['chunk_b', chunk_b],
            ['chunk_c', chunk_c]
          ])

          builder = IndexBuilder.new(store)
          morton_order = builder.build

          expected_order = expected_order_for(
            'chunk_a' => chunk_a,
            'chunk_b' => chunk_b,
            'chunk_c' => chunk_c
          )

          assert_equal expected_order, morton_order
          assert_equal expected_order, spatial_x_order_for(
            'chunk_a' => chunk_a,
            'chunk_b' => chunk_b,
            'chunk_c' => chunk_c
          )
        end

        private

        def build_chunk(origin:, scale:, bounds_max:, bits: 16)
          metadata = {
            bounds: {
              min: origin,
              max: bounds_max
            },
            quantization_bits: bits
          }

          ChunkStub.new(origin, scale, metadata)
        end

        def expected_order_for(chunks)
          chunks
            .map { |key, chunk| [key, expected_code_for(chunk)] }
            .sort_by { |(_, code)| code }
            .map(&:first)
        end

        def expected_code_for(chunk)
          center = chunk.metadata[:bounds][:min]
                          .zip(chunk.metadata[:bounds][:max])
                          .map { |min, max| (min + max) * 0.5 }
          quantization_bits = chunk.metadata[:quantization_bits] || 16
          max_value = (1 << quantization_bits) - 1
          origin = chunk.origin || [0.0, 0.0, 0.0]
          scales = [chunk.scale[:x], chunk.scale[:y], chunk.scale[:z]]
          fallback_scale = scales.compact.first || 1.0

          quantized = center.each_with_index.map do |component, axis|
            relative = component - origin[axis]
            scale = scales[axis] || fallback_scale
            ((relative / scale).round).clamp(0, max_value)
          end

          Morton.encode(*quantized)
        end

        def spatial_x_order_for(chunks)
          chunks
            .map { |key, chunk| [key, chunk_center(chunk)[0]] }
            .sort_by { |(_, x_center)| x_center }
            .map(&:first)
        end

        def chunk_center(chunk)
          chunk.metadata[:bounds][:min]
               .zip(chunk.metadata[:bounds][:max])
               .map { |min, max| (min + max) * 0.5 }
        end
      end
    end
  end
end
