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
        attr_reader :chunk_store

        def initialize(chunks)
          @chunks = chunks
          @chunk_store = Object.new
        end

        def next_chunks(frame_budget: 0)
          @chunks
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
