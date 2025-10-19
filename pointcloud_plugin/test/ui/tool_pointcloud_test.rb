# frozen_string_literal: true

require 'minitest/autorun'
require 'set'

require_relative '../../ui/tool_pointcloud'

module PointCloudPlugin
  module UI
    class ToolPointCloudTest < Minitest::Test
      FakeChunk = Struct.new(:metadata) do
        def size
          0
        end

        def empty?
          false
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
        attr_reader :visible_calls

        def initialize
          @visible_calls = []
        end

        def prefetch_for_view(visible_chunks, budget: 0, camera_position: nil, max_prefetch: nil)
          @visible_calls << visible_chunks
          @last_budget = budget
          @last_camera_position = camera_position
          @last_max_prefetch = max_prefetch
        end

        attr_reader :last_budget
        attr_reader :last_camera_position
        attr_reader :last_max_prefetch
      end

      class FakePipeline
        attr_reader :chunk_store, :reservoir

        def initialize(chunks, reservoir: nil)
          @chunks = chunks
          @chunk_store = Object.new
          @reservoir = reservoir || EmptyReservoir.new
          refs = chunks.map do |key, chunk|
            {
              key: key,
              bounds: chunk.respond_to?(:metadata) ? chunk.metadata[:bounds] : nil,
              point_count: chunk.respond_to?(:size) ? chunk.size : 0
            }
          end
          @visible_nodes = [Node.new(refs)]
        end

        def next_chunks(frame_budget: 0, frustum: nil, camera_position: nil, visible_chunk_keys: nil, visible_nodes: nil, **_ignored)
          return @chunks if visible_chunk_keys.nil? || visible_chunk_keys.empty?

          keys = visible_chunk_keys.to_set
          @chunks.select { |key, _| keys.include?(key) }
        end

        def visible_nodes_for(_frustum = nil, visible_chunk_keys: nil)
          return [] if visible_chunk_keys&.empty?

          @visible_nodes
        end

        class EmptyReservoir
          def sample_all(_limit = nil)
            []
          end
        end

        Node = Struct.new(:chunk_refs)
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
        ScreenPoint = Struct.new(:x, :y, :z)

        attr_reader :camera, :vpwidth, :vpheight

        def initialize(modelview, projection, eye = [0.0, 0.0, 0.0])
          @camera = FakeCamera.new(modelview, projection, eye)
          @vpwidth = 800
          @vpheight = 600
        end

        def pickray(_x, _y)
          [[0.0, 0.0, 10.0], [0.0, 0.0, -1.0]]
        end

        def screen_coords(point)
          coords =
            if point.is_a?(Array)
              point
            elsif point.respond_to?(:to_a)
              point.to_a
            elsif point.respond_to?(:x) && point.respond_to?(:y) && point.respond_to?(:z)
              [point.x, point.y, point.z]
            end

          return ScreenPoint.new(0, 0, -1) unless coords && coords.length >= 3

          x, y, z = coords
          ScreenPoint.new(@vpwidth / 2.0 + x * 100.0, @vpheight / 2.0 - y * 100.0, -z)
        end
      end

      def test_invisible_chunk_is_rejected
        projection = identity_matrix
        modelview = identity_matrix
        view = FakeView.new(modelview, projection)
        invisible_chunk = FakeChunk.new({ bounds: { min: [-0.5, -0.5, 1.0], max: [0.5, 0.5, 2.0] } })
        pipeline = FakePipeline.new([['chunk', invisible_chunk]])
        prefetcher = FakePrefetcher.new
        cloud = FakeCloud.new(1, pipeline, prefetcher)
        manager = FakeManager.new([cloud])

        tool = ToolPointCloud.new(manager)
        tool.stub(:current_frustum, nil) do
          tool.send(:gather_chunks, view)
        end

        assert_empty tool.instance_variable_get(:@active_chunks)
        assert_equal 1, prefetcher.visible_calls.size
        assert_empty prefetcher.visible_calls.first
      end

      def test_chunk_without_bounds_is_ignored
        projection = identity_matrix
        modelview = identity_matrix
        view = FakeView.new(modelview, projection)
        missing_bounds_chunk = FakeChunk.new({})
        pipeline = FakePipeline.new([['chunk', missing_bounds_chunk]])
        prefetcher = FakePrefetcher.new
        cloud = FakeCloud.new(1, pipeline, prefetcher)
        manager = FakeManager.new([cloud])

        tool = ToolPointCloud.new(manager)
        tool.send(:gather_chunks, view)

        assert_empty tool.instance_variable_get(:@active_chunks)
        assert_equal 1, prefetcher.visible_calls.size
        assert_empty prefetcher.visible_calls.first
      end

      def test_visible_chunk_is_rendered
        projection = identity_matrix
        modelview = identity_matrix
        view = FakeView.new(modelview, projection)
        visible_chunk = FakeChunk.new({ bounds: { min: [-0.5, -0.5, -2.0], max: [0.5, 0.5, -1.0] } })
        pipeline = FakePipeline.new([['chunk', visible_chunk]])
        prefetcher = FakePrefetcher.new
        cloud = FakeCloud.new(1, pipeline, prefetcher)
        manager = FakeManager.new([cloud])

        tool = ToolPointCloud.new(manager)
        tool.send(:gather_chunks, view)

        refute_empty tool.instance_variable_get(:@active_chunks)
        assert_equal visible_chunk, tool.instance_variable_get(:@active_chunks)['chunk'][:chunk]
        assert_equal [{ key: 'chunk', bounds: visible_chunk.metadata[:bounds] }], prefetcher.visible_calls.first
        assert_equal tool.instance_variable_get(:@settings)[:prefetch_limit], prefetcher.last_max_prefetch
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

      def test_screen_culling_false_uses_frustum
        tool = ToolPointCloud.new(FakeManager.new([]))
        bounds = { min: [-1.0, -1.0, -1.0], max: [1.0, 1.0, 1.0] }
        frustum = Struct.new(:result) do
          def intersects_bounds?(_bounds)
            result
          end
        end.new(true)

        tool.stub(:screen_culling_visibility, false) do
          assert tool.send(:visible_bounds?, bounds, frustum, nil)
        end
      end

      def test_screen_and_frustum_missing_defaults_to_visible
        tool = ToolPointCloud.new(FakeManager.new([]))
        bounds = { min: [-1.0, -1.0, -1.0], max: [1.0, 1.0, 1.0] }

        tool.stub(:screen_culling_visibility, nil) do
          assert tool.send(:visible_bounds?, bounds, nil, nil)
        end
      end

      def test_screen_false_without_frustum_is_invisible
        tool = ToolPointCloud.new(FakeManager.new([]))
        bounds = { min: [-1.0, -1.0, -1.0], max: [1.0, 1.0, 1.0] }

        tool.stub(:screen_culling_visibility, false) do
          refute tool.send(:visible_bounds?, bounds, nil, nil)
        end
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
