# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../../ui/tool_pointcloud'

module PointCloudPlugin
  module UI
    class ToolPointCloudTest < Minitest::Test
      FakeChunk = Struct.new(:metadata) do
        def size
          0
        end
      end

      class SampleChunk
        def initialize(points)
          @points = points
        end

        def metadata
          {}
        end

        def size
          @points.length
        end

        def point_at(index)
          @points[index]
        end
      end

      FakeCloud = Struct.new(:id, :pipeline, :prefetcher)

      class FakeManager
        def initialize(clouds)
          @clouds = clouds
        end

        def each_cloud
          return enum_for(:each_cloud) unless block_given?

          @clouds.each { |cloud| yield cloud }
        end
      end

      class FakePrefetcher
        attr_reader :frustums

        def initialize
          @frustums = []
        end

        def prefetch_for_view(frustum, budget: 0, camera_position: nil)
          @frustums << frustum
          @last_budget = budget
          @last_camera_position = camera_position
        end

        attr_reader :last_budget
        attr_reader :last_camera_position
      end

      class FakePipeline
        attr_reader :chunk_store, :reservoir

        def initialize(chunks, reservoir: nil)
          @chunks = chunks
          @chunk_store = Object.new
          @reservoir = reservoir || EmptyReservoir.new
        end

        def next_chunks(frame_budget: 0, frustum: nil, camera_position: nil)
          @chunks
        end

        class EmptyReservoir
          def sample_all(_limit = nil)
            []
          end
        end
      end

      class FakeCamera
        def initialize(modelview, projection, eye = [0.0, 0.0, 0.0])
          @modelview = modelview
          @projection = projection
          @eye = eye
        end

        def modelview_matrix
          @modelview
        end

        def projection_matrix
          @projection
        end

        def eye
          @eye
        end
      end

      class FakeView
        attr_reader :camera

        def initialize(modelview, projection, eye = [0.0, 0.0, 0.0])
          @camera = FakeCamera.new(modelview, projection, eye)
        end

        def pickray(_x, _y)
          [[0.0, 0.0, 10.0], [0.0, 0.0, -1.0]]
        end
      end

      def test_invisible_chunk_is_rejected
        projection = identity_matrix
        modelview = identity_matrix
        view = FakeView.new(modelview, projection)
        invisible_chunk = FakeChunk.new({ bounds: { min: [2.0, -0.5, -0.5], max: [3.0, 0.5, 0.5] } })
        pipeline = FakePipeline.new([['chunk', invisible_chunk]])
        prefetcher = FakePrefetcher.new
        cloud = FakeCloud.new(1, pipeline, prefetcher)
        manager = FakeManager.new([cloud])

        tool = ToolPointCloud.new(manager)
        tool.send(:gather_chunks, view)

        assert_empty tool.instance_variable_get(:@active_chunks)
        assert_equal 1, prefetcher.frustums.size
        assert_equal 6, prefetcher.frustums.first.planes.size
      end

      def test_update_snap_target_uses_reservoir_samples
        projection = identity_matrix
        modelview = identity_matrix
        view = FakeView.new(modelview, projection)

        sample_point = { position: [0.0, 0.0, 0.0] }
        reservoir = Class.new do
          def initialize(samples)
            @samples = samples
          end

          def sample_all(_limit = nil)
            @samples
          end
        end.new([sample_point])

        pipeline = FakePipeline.new([], reservoir: reservoir)
        cloud = FakeCloud.new(1, pipeline, Object.new)
        manager = FakeManager.new([cloud])

        tool = ToolPointCloud.new(manager)

        tool.send(:update_snap_target, view, 0, 0)

        assert_equal sample_point, tool.instance_variable_get(:@snap_target)
      end

      def test_preview_samples_fall_back_to_active_chunks
        reservoir_sample = { position: [0.0, 0.0, 0.0] }
        reservoir = Class.new do
          def initialize(samples)
            @samples = samples
          end

          def sample_all(limit = nil)
            limit && limit > 0 ? @samples.first(limit) : @samples
          end
        end.new([reservoir_sample])

        chunk_points = [
          { position: [1.0, 0.0, 0.0] },
          { position: [2.0, 0.0, 0.0] }
        ]
        chunk = SampleChunk.new(chunk_points)

        pipeline = FakePipeline.new([['chunk', chunk]], reservoir: reservoir)
        cloud = FakeCloud.new(1, pipeline, FakePrefetcher.new)
        manager = FakeManager.new([cloud])

        tool = ToolPointCloud.new(manager)
        tool.instance_variable_set(:@active_chunks, { 'chunk' => { chunk: chunk, store: Object.new } })
        tool.instance_variable_set(:@chunk_usage, ['chunk'])

        samples = tool.preview_samples(3)

        assert_equal [reservoir_sample, *chunk_points], samples
      end

      private

      def identity_matrix
        [
          [1.0, 0.0, 0.0, 0.0],
          [0.0, 1.0, 0.0, 0.0],
          [0.0, 0.0, 1.0, 0.0],
          [0.0, 0.0, 0.0, 1.0]
        ]
      end
    end
  end
end
