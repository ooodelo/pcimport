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
        @frame_times = []
        @last_draw_time = nil
        hook_settings
      end

      def activate
        settings_dialog.show
      end

      def deactivate(view)
        view.invalidate if view.respond_to?(:invalidate)
      end

      def draw(view)
        update_fps
        gather_chunks(view)
        points_by_color = Hash.new { |hash, key| hash[key] = [] }

        @chunk_usage.each do |key|
          entry = @active_chunks[key]
          next unless entry

          chunk = entry[:chunk]
          chunk.size.times do |index|
            point = chunk.point_at(index)
            points_by_color[group_key_for(point[:color])] << point[:position]
          end
        end

        if view.respond_to?(:draw_points)
          default_color = if defined?(Sketchup::Color)
                            Sketchup::Color.new(0, 0, 0)
                          else
                            'black'
                          end

          points_by_color.each do |color_key, positions|
            color = if color_key == :default
                      default_color
                    elsif defined?(Sketchup::Color)
                      Sketchup::Color.new(*color_key)
                    else
                      r, g, b = color_key
                      format('#%02X%02X%02X', r, g, b)
                    end

            positions.each_slice(max_points_per_batch) do |batch|
              sketchup_points = convert_positions_to_points(batch)
              next if sketchup_points.empty?

              view.draw_points(sketchup_points, @settings[:point_size], 1, color)
            end
          end
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

      def update_fps
        clock = Process.const_defined?(:CLOCK_MONOTONIC) ? Process::CLOCK_MONOTONIC : :monotonic
        now = Process.clock_gettime(clock)
        if @last_draw_time
          frame_time = now - @last_draw_time
          @frame_times << frame_time
          @frame_times.shift while @frame_times.length > 30

          average_frame_time = @frame_times.sum / @frame_times.length
          fps = average_frame_time.positive? ? (1.0 / average_frame_time) : 0.0
          hud.update('fps' => format('%.1f', fps))
        end
        @last_draw_time = now
      rescue Errno::EINVAL
        # Fallback for systems where CLOCK_MONOTONIC is unavailable
        @last_draw_time = nil
      end

      def convert_positions_to_points(positions)
        positions.each_with_object([]) do |pos, collection|
          if pos.is_a?(Geom::Point3d)
            collection << pos
            next
          end

          coordinates = pos.respond_to?(:to_a) ? pos.to_a : pos
          next unless coordinates.is_a?(Array) && coordinates.length >= 3

          collection << Geom::Point3d.new(*coordinates)
        end
      end

      def group_key_for(color)
        return :default unless color.is_a?(Array) && color.length >= 3

        [color[0], color[1], color[2]].map(&:to_i).freeze
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
        return unless view.respond_to?(:pickray)

        samples = []
        manager.each_cloud do |cloud|
          samples.concat(cloud.pipeline.reservoir.samples)
        end
        return if samples.empty?

        origin, direction = view.pickray(x, y)
        origin = to_coordinates(origin)
        direction = normalize_vector(to_coordinates(direction))
        return unless origin && direction

        knn = Core::Spatial::Knn.new(samples)
        nearest = knn.nearest_to_ray(origin, direction, 1).first

        radius = @settings[:snap_radius].to_f
        @snap_target = if nearest && nearest[1] <= radius**2
                         nearest.first
                       else
                         nil
                       end
      end

      def draw_snap(view)
        return unless @snap_target
        return unless view.respond_to?(:draw_points)

        snap_points = convert_positions_to_points([@snap_target[:position]])
        view.draw_points(snap_points, @settings[:point_size] * 2) unless snap_points.empty?
      end

      def max_points_per_batch
        100_000
      end

      def to_coordinates(value)
        if value.respond_to?(:to_a)
          coords = value.to_a
          return coords[0, 3] if coords.length >= 3
        elsif value.is_a?(Array)
          return value[0, 3]
        end

        nil
      end

      def normalize_vector(vector)
        return unless vector

        magnitude = Math.sqrt(vector.sum { |component| component * component })
        return if magnitude.zero?

        vector.map { |component| component / magnitude }
      end
    end
  end
end
