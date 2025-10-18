# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../../core/lod/pipeline'

module PointCloudPlugin
  module Core
    module Lod
      class PipelineTest < Minitest::Test
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

          def each_in_memory
            return enum_for(:each_in_memory) unless block_given?

            @chunks.each do |key, chunk|
              yield key, chunk
            end
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

          chunks = @pipeline.next_chunks(frame_budget: 5, camera_position: [0, 0, 0])

          total_points = chunks.map { |(_, chunk)| chunk.size }.sum
          assert_operator total_points, :<=, 5
          refute_empty chunks
        end

        def test_next_chunks_returns_single_chunk_when_larger_than_budget
          submit_chunk('oversized', size: 6, center: [0, 0, 0])

          chunks = @pipeline.next_chunks(frame_budget: 3, camera_position: [0, 0, 0])

          assert_equal ['oversized'], chunks.map(&:first)
          assert_equal 3, chunks.first.last.size
          assert_equal({ original_size: 6, sampled_size: 3 }, chunks.first.last.metadata[:lod])
        end

        def test_next_chunks_without_budget_returns_full_chunks
          submit_chunk('a', size: 2, center: [0, 0, 0])
          submit_chunk('b', size: 2, center: [5, 0, 0])

          chunks = @pipeline.next_chunks(frame_budget: 0)

          assert_equal %w[a b], chunks.map(&:first).sort
          assert_equal [2, 2], chunks.map { |(_, chunk)| chunk.size }.sort
        end

        private

        def submit_chunk(key, size:, center: [0, 0, 0])
          chunk = build_chunk(size: size, center: center)
          @pipeline.submit_chunk(key, chunk)
        end

        def build_chunk(size:, center: [0.0, 0.0, 0.0])
          bounds = {
            min: center.map { |value| value - 0.5 },
            max: center.map { |value| value + 0.5 }
          }

          positions = {
            x: Array.new(size, 0),
            y: Array.new(size, 0),
            z: Array.new(size, 0)
          }

          colors = {
            r: Array.new(size),
            g: Array.new(size),
            b: Array.new(size)
          }

          intensities = Array.new(size)

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
