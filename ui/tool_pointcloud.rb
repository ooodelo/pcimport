# frozen_string_literal: true

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

        @active_chunks.each_value do |chunk|
          chunk.size.times do |index|
            point = chunk.point_at(index)
            points << point[:position]
          end
        end

        if view.respond_to?(:draw_points)
          view.draw_points(points, @settings[:point_size])
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
        manager.each_cloud do |cloud|
          cloud.prefetcher.prefetch_for_view(frustum, budget: @settings[:budget])
          cloud.pipeline.next_chunks(frame_budget: @settings[:budget]).each do |key, chunk|
            next unless chunk

            @active_chunks[key] = chunk
            hud.update("cloud_#{cloud.id}_points" => chunk.size)
          end
        end
      end

      def current_frustum(_view)
        planes = []
        Core::Spatial::Frustum.new(planes)
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
