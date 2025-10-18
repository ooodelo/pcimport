# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/lod/pipeline'

module PointCloudPlugin
  module Core
    module Lod
      class PipelineTest < Minitest::Test
        FakeChunk = Struct.new(:size, :metadata, :scale) do
          def initialize(size:, center: [0.0, 0.0, 0.0], scale: 1.0)
            bounds = {
              min: center.map { |value| value - 0.5 },
              max: center.map { |value| value + 0.5 }
            }
            super(size, { bounds: bounds }, scale)
          end

          def each_point
            return enum_for(:each_point) unless block_given?

            size.times { yield({}) }
          end
        end

        class FakeStore
          def initialize
            @chunks = {}
          end

          def store(key, chunk)
            @chunks[key] = chunk
          end

          def fetch(key)
            @chunks.fetch(key)
          end
        end

        def setup
          @store = FakeStore.new
          @pipeline = Pipeline.new(chunk_store: @store)
        end

        def test_next_chunks_limits_by_point_budget
          submit_chunk('a', size: 3, center: [0, 0, 0])
          submit_chunk('b', size: 4, center: [10, 0, 0])
          submit_chunk('c', size: 2, center: [20, 0, 0])

          chunks = @pipeline.next_chunks(frame_budget: 5)

          assert_equal %w[a b], chunks.map(&:first)
        end

        def test_next_chunks_returns_single_chunk_when_larger_than_budget
          submit_chunk('oversized', size: 6, center: [0, 0, 0])

          chunks = @pipeline.next_chunks(frame_budget: 3)

          assert_equal ['oversized'], chunks.map(&:first)
        end

        private

        def submit_chunk(key, size:, center: [0, 0, 0])
          chunk = FakeChunk.new(size: size, center: center)
          @pipeline.submit_chunk(key, chunk)
        end
      end
    end
  end
end
