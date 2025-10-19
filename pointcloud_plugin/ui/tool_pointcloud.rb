# frozen_string_literal: true

require 'set'

require_relative '../bridge/point_cloud_manager'
require_relative '../core/lod/pipeline'
require_relative '../core/spatial/knn'
require_relative '../core/spatial/frustum'
require_relative 'hud'
require_relative 'dialog_settings'
require_relative 'visibility' rescue nil
require_relative 'preview_layer' rescue nil

module PointCloudPlugin
  module UI
    # SketchUp tool responsible for rendering imported point clouds and handling snapping.
    class ToolPointCloud
      unless const_defined?(:ColorShim)
        # Minimal color stand-in for non-SketchUp environments.
        class ColorShim
          attr_reader :red, :green, :blue, :alpha

          def initialize(red, green, blue, alpha = 255)
            @red = red
            @green = green
            @blue = blue
            @alpha = alpha
          end
        end
      end

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
        points_drawn = 0
        point_size = safe_point_size
        default_color = default_point_color

        begin
          update_fps
          gather_chunks(view)
          points_by_color = Hash.new { |hash, key| hash[key] = [] }
          color_lookup = {}

          @chunk_usage.each do |key|
            entry = @active_chunks[key]
            next unless entry

            chunk = entry[:chunk]
            chunk.size.times do |index|
              point = chunk.point_at(index)
              bucket_key, color_value = color_bucket_for(point)
              color_lookup[bucket_key] ||= color_value
              points_by_color[bucket_key] << point[:position]
            end
          end

          if view.respond_to?(:draw_points)
            points_by_color.each do |color_key, positions|
              color = color_for(color_key, color_lookup[color_key], default_color)

              positions.each_slice(max_points_per_batch) do |batch|
                sketchup_points = convert_positions_to_points(batch)
                next if sketchup_points.empty?

                points_drawn += sketchup_points.length
                view.draw_points(sketchup_points, point_size, 1, color)
              end
            end
          end
        rescue => e
          Kernel.puts("[PointCloudPlugin:draw] #{e.class}: #{e.message}\n  #{e.backtrace&.first}")
        ensure
          @last_drawn_point_count = points_drawn
          draw_snap(view, point_size)
          PointCloud::UI::PreviewLayer.draw(view, self) if defined?(PointCloud::UI::PreviewLayer)
          hud.draw(view)
        end
      end

      def onMouseMove(_flags, x, y, view)
        update_snap_target(view, x, y)
        view.invalidate if view.respond_to?(:invalidate)
      end

      def last_drawn_point_count
        @last_drawn_point_count ||= 0
      end

      def preview_samples(limit = 2_000)
        limit = limit.to_i
        limit = 0 if limit.negative?

        samples = gather_reservoir_samples(limit)
        remaining = limit.positive? ? [limit - samples.length, 0].max : nil

        if remaining.nil? || remaining.positive?
          samples.concat(gather_active_chunk_samples(remaining))
        end

        limit.positive? ? samples.first(limit) : samples
      end

      private

      def hook_settings
        settings_dialog.on_change do |new_settings|
          @settings = new_settings
        end
      end

      def gather_reservoir_samples(limit)
        samples = []
        manager.each_cloud do |cloud|
          reservoir = cloud.pipeline&.reservoir
          next unless reservoir

          reservoir_samples = reservoir.sample_all(limit)
          next if reservoir_samples.empty?

          samples.concat(reservoir_samples)
          break if limit.positive? && samples.length >= limit
        end
        samples
      end

      def gather_active_chunk_samples(limit)
        return [] if limit&.zero?

        samples = []
        each_active_chunk do |chunk|
          chunk.size.times do |index|
            samples << chunk.point_at(index)
            if limit && samples.length >= limit
              return samples
            end
          end
        end

        samples
      end

      def each_active_chunk
        return enum_for(:each_active_chunk) unless block_given?

        @chunk_usage.each do |key|
          entry = @active_chunks[key]
          next unless entry

          yield entry[:chunk]
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

      def color_bucket_for(point)
        color = point[:color]

        if color.is_a?(Array) && color.length >= 3
          quantized = color.first(3).map { |component| quantize_color_component(component) }
          [[:rgb, *quantized], quantized]
        elsif point.key?(:intensity) && !point[:intensity].nil?
          grayscale = quantize_intensity(point[:intensity])
          [[:intensity, grayscale], [grayscale, grayscale, grayscale]]
        else
          [:default, nil]
        end
      end

      def quantize_color_component(value)
        component = value.to_f
        component *= 255.0 if component <= 1.0
        step = 256 / 32
        quantized = (component.clamp(0.0, 255.0) / step).floor * step
        quantized.to_i
      end

      def quantize_intensity(value)
        intensity = value.to_f
        intensity *= 255.0 if intensity <= 1.0
        quantize_color_component(intensity)
      end

      def color_for(key, rgb_values, default_color)
        return default_color if key == :default || rgb_values.nil?

        rgb_array = Array(rgb_values)[0, 3]
        return default_color if rgb_array.compact.length < 3

        r, g, b = rgb_array.map { |component| component.to_f.round }
        build_color(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255))
      rescue StandardError
        default_color
      end

      def safe_point_size
        raw = @settings && @settings[:point_size]
        value = case raw
                when Integer then raw
                when Float then raw.to_i
                else
                  begin
                    Integer(raw)
                  rescue ArgumentError, TypeError
                    raw.respond_to?(:to_i) ? raw.to_i : 0
                  end
                end

        value = 1 if value < 1
        value = 9 if value > 9
        value
      end

      def gather_chunks(view)
        frustum = current_frustum(view)
        camera_position = current_camera_position(view)
        visible_keys = Set.new
        budget = @settings[:budget].to_i
        points_accumulated = 0

        manager.each_cloud do |cloud|
          cloud.prefetcher.prefetch_for_view(
            frustum,
            budget: @settings[:budget],
            camera_position: camera_position
          )
          cloud.pipeline.next_chunks(
            frame_budget: @settings[:budget],
            frustum: frustum,
            camera_position: camera_position
          ).each do |key, chunk|
            next unless chunk

            next unless chunk_visible?(chunk, frustum)

            break if budget.positive? && points_accumulated >= budget

            chunk_points = chunk.size
            if budget.positive? && points_accumulated.positive? && points_accumulated + chunk_points > budget
              next
            end

            store_active_chunk(key, chunk, cloud.pipeline.chunk_store)
            visible_keys << key
            points_accumulated += chunk_points
            hud.update("cloud_#{cloud.id}_points" => chunk.size)
          end

          break if budget.positive? && points_accumulated >= budget
        end

        @active_chunks.each do |key, entry|
          next if visible_keys.include?(key)

          next unless chunk_visible?(entry[:chunk], frustum)

          break if budget.positive? && points_accumulated >= budget

          chunk_points = entry[:chunk].size
          if budget.positive? && points_accumulated.positive? && points_accumulated + chunk_points > budget
            next
          end

          touch_chunk(key)
          visible_keys << key
          points_accumulated += chunk_points
        end

        evict_stale_chunks(visible_keys, budget)
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

      def current_camera_position(view)
        return unless view

        camera = view.respond_to?(:camera) ? view.camera : nil
        return unless camera

        position = if camera.respond_to?(:eye)
                     camera.eye
                   elsif camera.respond_to?(:position)
                     camera.position
                   end

        to_coordinates(position)
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

      def evict_stale_chunks(visible_keys, budget)
        (@active_chunks.keys - visible_keys.to_a).each do |stale_key|
          evict_chunk(stale_key)
        end

        return unless budget.positive?

        points = total_points_for(@chunk_usage)
        while points > budget && @chunk_usage.any?
          key = @chunk_usage.last
          points -= chunk_size_for(key)
          evict_chunk(key)
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

        samples = preview_samples
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

      def draw_snap(view, point_size = safe_point_size)
        return unless @snap_target
        return unless view.respond_to?(:draw_points)

        snap_points = convert_positions_to_points([@snap_target[:position]])
        return if snap_points.empty?

        color = build_color(255, 0, 0)

        view.draw_points(snap_points, (point_size * 2).clamp(2, 18), 2, color)
      end

      def max_points_per_batch
        100_000
      end

      def default_point_color
        build_color(0, 0, 0)
      end

      def build_color(r, g, b)
        if defined?(Sketchup::Color)
          Sketchup::Color.new(r, g, b)
        else
          self.class::ColorShim.new(r, g, b)
        end
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

      def total_points_for(keys)
        keys.sum { |key| chunk_size_for(key) }
      end

      def chunk_size_for(key)
        entry = @active_chunks[key]
        entry ? entry[:chunk].size : 0
      end
    end
  end
end
