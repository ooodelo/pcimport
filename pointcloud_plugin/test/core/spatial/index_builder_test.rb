# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/spatial/index_builder'

module PointCloudPlugin
  module Core
    module Spatial
      class IndexBuilderTest < Minitest::Test
        ChunkStub = Struct.new(:metadata, :size)

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

          def fetch(key)
            entry = @entries.find { |stored_key, _| stored_key == key }
            entry&.last
          end
        end

        def test_build_creates_octree_with_chunk_refs
          chunk_a = chunk_stub(min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0], size: 100)
          chunk_b = chunk_stub(min: [2.0, 0.0, 0.0], max: [3.0, 1.0, 1.0], size: 50)

          store = FakeChunkStore.new([
            ['chunk_a', chunk_a],
            ['chunk_b', chunk_b]
          ])

          builder = IndexBuilder.new(store, max_chunks_per_node: 1)
          builder.build
          root = builder.root

          refute_nil root
          assert_in_delta 150, root.point_count, 1e-6
          assert_equal 2, root.visible_nodes(nil).sum { |node| node.chunk_refs.length }
        end

        def test_visible_nodes_filters_by_frustum
          near_chunk = chunk_stub(min: [0.0, 0.0, 0.0], max: [1.0, 1.0, 1.0], size: 10)
          far_chunk = chunk_stub(min: [10.0, 2.0, 2.0], max: [11.0, 3.0, 3.0], size: 10)

          store = FakeChunkStore.new([
            ['near', near_chunk],
            ['far', far_chunk]
          ])

          builder = IndexBuilder.new(store, max_chunks_per_node: 1)
          builder.build
          root = builder.root
          frustum = HalfSpaceFrustum.new(1.0)

          nodes = builder.visible_nodes(frustum)
          keys = nodes.flat_map { |node| node.chunk_refs.map { |ref| ref[:key] } }

          assert_includes keys, 'near'
          refute_includes keys, 'far'
        end

        private

        def chunk_stub(min:, max:, size:)
          metadata = { bounds: { min: min, max: max } }
          ChunkStub.new(metadata, size)
        end

        class HalfSpaceFrustum
          def initialize(max_x)
            @max_x = max_x
          end

          def intersects_bounds?(bounds)
            bounds[:min][0] <= @max_x
          end
        end
      end
    end
  end
end
