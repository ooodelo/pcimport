# frozen_string_literal: true

require 'set'

require_relative '../bridge/point_cloud_manager'
require_relative '../core/lod/pipeline'
require_relative '../core/spatial/knn'
require_relative '../core/spatial/frustum'
require_relative 'hud'
require_relative 'dialog_settings'

module PointCloudPlugin
  module UI
    # SketchUp tool responsible for rendering imported point clouds and handling snapping.
    class ToolPointCloud
      attr_reader :manager, :hud, :settings_dialog

      def initialize(manager)
        @manager = manager
        @hud = Hud.new
        @settings_dialog = DialogSettings.new
        @settings = @settings_dialog.settings
        @active_chunks = {}
        @chunk_usage = []
        @snap_target = nil
        hook_settings
      end

      def activate
        settings_dialog.show
      end

      def deactivate(view)
        view.invalidate if view.respond_to?(:invalidate)
      end

      def draw(view)
        gather_chunks(view)
        points = []

        @chunk_usage.each do |key|
          entry = @active_chunks[key]
          next unless entry

          chunk = entry[:chunk]
          chunk.size.times do |index|
            point = chunk.point_at(index)
            points << point[:position]
          end
        end

        if view.respond_to?(:draw_points)
          sketchup_points = points.map { |pos| Geom::Point3d.new(*pos) }
          view.draw_points(sketchup_points, @settings[:point_size], 1, 'black')
          draw_snap(view)
          hud.draw(view)
        end
      end

      def onMouseMove(_flags, x, y, view)
        update_snap_target(view, x, y)
        view.invalidate if view.respond_to?(:invalidate)
      end

      private

      def hook_settings
        settings_dialog.on_change do |new_settings|
          @settings = new_settings
        end
      end

      def gather_chunks(view)
        frustum = current_frustum(view)
        visible_keys = Set.new

        manager.each_cloud do |cloud|
          cloud.prefetcher.prefetch_for_view(frustum, budget: @settings[:budget])
          cloud.pipeline.next_chunks(frame_budget: @settings[:budget]).each do |key, chunk|
            next unless chunk

            next unless chunk_visible?(chunk, frustum)

            store_active_chunk(key, chunk, cloud.pipeline.chunk_store)
            visible_keys << key
            hud.update("cloud_#{cloud.id}_points" => chunk.size)
          end
        end

        @active_chunks.each do |key, entry|
          next if visible_keys.include?(key)

          if chunk_visible?(entry[:chunk], frustum)
            touch_chunk(key)
            visible_keys << key
          end
        end

        evict_stale_chunks(visible_keys)
      end

      def current_frustum(view)
        epsilon = Core::Spatial::Frustum::DEFAULT_EPSILON
        return Core::Spatial::Frustum.new([], epsilon: epsilon) unless view

        camera = view.respond_to?(:camera) ? view.camera : nil

        modelview = extract_matrix(camera, :modelview_matrix) || extract_matrix(view, :modelview_matrix, :modelview)
        projection = extract_matrix(camera, :projection_matrix) || extract_matrix(view, :projection_matrix, :projection)

        if modelview && projection
          Core::Spatial::Frustum.from_view_matrices(modelview, projection, epsilon: epsilon)
        else
          Core::Spatial::Frustum.new([], epsilon: epsilon)
        end
      rescue ArgumentError
        Core::Spatial::Frustum.new([], epsilon: epsilon)
      end

      def chunk_visible?(chunk, frustum)
        bounds = chunk.metadata[:bounds]
        return true unless bounds

        frustum.intersects_bounds?(bounds)
      end

      def extract_matrix(source, *candidates)
        return unless source

        candidates.each do |method_name|
          next unless source.respond_to?(method_name)

          matrix = source.public_send(method_name)
          return matrix if matrix
        end

        nil
      end

      def store_active_chunk(key, chunk, store)
        @active_chunks[key] = { chunk: chunk, store: store }
        touch_chunk(key)
      end

      def touch_chunk(key)
        @chunk_usage.delete(key)
        @chunk_usage.unshift(key)
      end

      def evict_stale_chunks(visible_keys)
        (@active_chunks.keys - visible_keys.to_a).each do |stale_key|
          evict_chunk(stale_key)
        end

        while @chunk_usage.size > @settings[:budget]
          evict_chunk(@chunk_usage.last)
        end
      end

      def evict_chunk(key)
        entry = @active_chunks.delete(key)
        return unless entry

        @chunk_usage.delete(key)
        store = entry[:store]
        store.release(key) if store.respond_to?(:release)
      end

      def update_snap_target(view, x, y)
        return unless view.respond_to?(:pick_helper)

        samples = []
        manager.each_cloud do |cloud|
          samples.concat(cloud.pipeline.reservoir.samples)
        end
        return if samples.empty?

        pick_helper = view.pick_helper
        pick_helper.do_pick(x, y)
        picked = pick_helper.best_picked
        return unless picked&.respond_to?(:position)

        target_point = picked.position.to_a
        knn = Core::Spatial::Knn.new(samples)
        nearest = knn.nearest(target_point, 1).first
        @snap_target = nearest&.first
      end

      def draw_snap(view)
        return unless @snap_target
        return unless view.respond_to?(:draw_points)

        view.draw_points([@snap_target[:position]], @settings[:point_size] * 2)
      end
    end
  end
end
