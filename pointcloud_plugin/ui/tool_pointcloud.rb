# frozen_string_literal: true

require 'set'

require_relative '../bridge/point_cloud_manager'
require_relative '../core/lod/pipeline'
require_relative '../core/spatial/knn'
require_relative '../core/spatial/frustum'
require_relative 'hud'
require_relative 'dialog_settings'
require_relative 'import_overlay'
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

      attr_reader :manager, :hud, :settings_dialog, :import_overlay

      def initialize(manager)
        @manager = manager
        @hud = Hud.new
        @settings_dialog = DialogSettings.new
        @settings = @settings_dialog.settings
        @import_overlay = ImportOverlay.new
        @active_chunks = {}
        @chunk_usage = []
        @snap_target = nil
        @frame_times = []
        @last_draw_time = nil
        @active_import_job = nil
        @active_cloud_id = nil
        @preview_buffer = []
        @preview_ready = false
        @visualization_announced = false
        @auto_camera_active = true
        @camera_focused = false
        @memory_notice_expires_at = nil
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
          expire_memory_notice_if_needed
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
          handle_visualization_ready(points_drawn)
          PointCloud::UI::PreviewLayer.draw(view, self) if defined?(PointCloud::UI::PreviewLayer)
          hud.draw(view)
          import_overlay.draw(view) if import_overlay
        end
      end

      def onMouseMove(_flags, x, y, view)
        user_interaction!
        update_snap_target(view, x, y)
        view.invalidate if view.respond_to?(:invalidate)
      end

      def onLButtonDown(_flags, x, y, view)
        user_interaction!

        if import_overlay&.cancel_enabled? && import_overlay.cancel_hit?(x, y)
          cancel_active_import
          view.invalidate if view.respond_to?(:invalidate)
          return
        end

        update_snap_target(view, x, y)
        view.invalidate if view.respond_to?(:invalidate)
      end

      def last_drawn_point_count
        @last_drawn_point_count ||= 0
      end

      def preview_samples(limit = 2_000)
        limit = limit.to_i
        limit = 0 if limit.negative?

        samples = preview_buffer_samples(limit)
        remaining = limit.positive? ? [limit - samples.length, 0].max : nil

        reservoir_samples = gather_reservoir_samples(remaining || limit)
        samples.concat(reservoir_samples)
        remaining = limit.positive? ? [limit - samples.length, 0].max : nil

        if remaining.nil? || remaining.positive?
          samples.concat(gather_active_chunk_samples(remaining))
        end

        limit.positive? ? samples.first(limit) : samples
      end

      def preview_ready=(value)
        @preview_ready = !!value
      end

      def import_in_progress?
        !@active_import_job.nil?
      end

      def begin_import_session(job:, cloud_id:, cloud_name: nil)
        @active_import_job = job
        @active_cloud_id = cloud_id
        @preview_buffer.clear
        @preview_ready = false
        @visualization_announced = false
        @camera_focused = false
        @auto_camera_active = true
        import_overlay.show!
        update_import_state(:initializing)
        hud.update(load_status: "Загрузка: инициализация", memory_notice: nil)
        hud.update(points_on_screen: 0)
        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      def handle_import_state(job:, state:, stage_progress: nil)
        return unless job && job == @active_import_job

        update_import_state(state, stage_progress: stage_progress)
      end

      def handle_import_chunk(job:, key:, chunk:, info: {})
        return unless job && job == @active_import_job
        return unless chunk

        hud.update(points_on_screen: chunk.size)
        import_overlay.update_stage_progress(info[:stage_progress]) if info.is_a?(Hash)

        ingest_preview_points(Array(info[:preview_points])) if info.is_a?(Hash) && info[:preview_points]
        ingest_preview_chunk(chunk)

        if info.is_a?(Hash) && info[:first_chunk] && @auto_camera_active && !@camera_focused
          focused = PointCloudPlugin.focus_camera_on_chunk(chunk) if PointCloudPlugin.respond_to?(:focus_camera_on_chunk)
          @camera_focused = true if focused
        end

        if info.is_a?(Hash) && info[:preview_ready]
          @preview_ready = true
        end

        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      def handle_import_completion(job)
        return unless job && job == @active_import_job

        status = job.respond_to?(:completion_status) ? job.completion_status : :completed

        case status
        when :cancelled
          update_import_state(:cancelled)
          hud.update(load_status: 'Импорт отменён пользователем')
          if @active_cloud_id && PointCloudPlugin.respond_to?(:manager)
            PointCloudPlugin.manager.remove_cloud(@active_cloud_id)
          end
        when :failed
          update_import_state(:cancelled)
          if @active_cloud_id && PointCloudPlugin.respond_to?(:manager)
            PointCloudPlugin.manager.remove_cloud(@active_cloud_id)
          end
        else
          update_import_state(:navigating)
          hud.update(load_status: 'Первые точки готовы') unless @visualization_announced
        end

        @active_import_job = nil
        @active_cloud_id = nil
        @preview_buffer.clear
        @preview_ready = false
        @visualization_announced = false
        @memory_notice_expires_at = nil
        hud.update(memory_notice: nil)
        import_overlay.hide!
        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      def cancel_active_import
        return unless cancel_allowed?

        job = @active_import_job
        job.cancel if job.respond_to?(:cancel)
        update_import_state(:cancelled)
        hud.update(load_status: 'Отмена импорта…')
        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      def handle_memory_pressure(limit_bytes, freed_bytes)
        message = format_memory_notice(limit_bytes, freed_bytes)
        hud.update(memory_notice: message)
        @memory_notice_expires_at = current_time + 5.0
        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      private

      PREVIEW_BUFFER_LIMIT = 2_000

      def preview_buffer_samples(limit)
        return [] if limit.zero?

        samples = @preview_buffer.dup
        return samples if limit.negative? || limit.nil?

        samples.first(limit)
      end

      def update_import_state(new_state, stage_progress: nil)
        return unless import_overlay

        import_overlay.show!
        import_overlay.update_state(new_state)
        import_overlay.update_stage_progress(stage_progress) if stage_progress

        label = case new_state
                when :initializing then 'Загрузка: инициализация'
                when :reading then 'Загрузка: чтение'
                when :preparing then 'Загрузка: подготовка данных'
                when :visualizing then 'Загрузка: визуализация'
                when :navigating then 'Работа: навигация'
                when :cancelled then 'Загрузка отменена'
                else
                  'Загрузка облака…'
                end

        hud.update(load_status: label)
        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      def cancel_allowed?
        import_overlay&.cancel_enabled? && @active_import_job
      end

      def format_memory_notice(limit_bytes, freed_bytes)
        limit_mb = limit_bytes ? (limit_bytes.to_f / (1024.0 * 1024.0)).round : 0
        freed_mb = freed_bytes.to_f / (1024.0 * 1024.0)
        format('Ограничили память до %d МБ, освобождено %.1f МБ', limit_mb, freed_mb)
      end

      def current_time
        if Process.const_defined?(:CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        else
          Process.clock_gettime(:monotonic)
        end
      rescue Errno::EINVAL
        Time.now.to_f
      end

      def expire_memory_notice_if_needed
        return unless @memory_notice_expires_at

        if current_time >= @memory_notice_expires_at
          hud.update(memory_notice: nil)
          @memory_notice_expires_at = nil
        end
      end

      def ingest_preview_points(points)
        return if points.nil? || @preview_ready

        points.each do |point|
          break if @preview_buffer.length >= PREVIEW_BUFFER_LIMIT

          normalized = normalize_preview_point(point)
          @preview_buffer << normalized if normalized
        end
      end

      def normalize_preview_point(point)
        if point.is_a?(Hash)
          position = point[:position] || point['position']
          return unless position

          { position: Array(position)[0, 3] }
        elsif point.respond_to?(:position)
          { position: Array(point.position)[0, 3] }
        elsif point.respond_to?(:to_a)
          coords = point.to_a
          return unless coords.length >= 3

          { position: coords[0, 3] }
        end
      rescue StandardError
        nil
      end

      def ingest_preview_chunk(chunk)
        return if @preview_ready
        return unless chunk.respond_to?(:each_point)

        chunk.each_point do |point|
          break if @preview_buffer.length >= PREVIEW_BUFFER_LIMIT

          normalized = normalize_preview_point(point)
          @preview_buffer << normalized if normalized
        end
      end

      def handle_visualization_ready(points_drawn)
        return unless points_drawn.positive?
        return if @visualization_announced

        @visualization_announced = true
        hud.update(load_status: 'Первые точки готовы')
        @preview_buffer.clear
        if defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:invalidate_active_view)
          PointCloudPlugin.invalidate_active_view
        end
      end

      def user_interaction!
        @auto_camera_active = false
      end

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

        visible_data_by_cloud = manager.each_cloud.each_with_object({}) do |cloud, hash|
          hash[cloud.id] = visible_chunk_data_for(cloud, frustum, view)
        end

        manager.each_cloud do |cloud|
          visible_data = visible_data_by_cloud[cloud.id] || {}
          visible_entries = Array(visible_data[:entries]).compact
          visible_nodes = Array(visible_data[:nodes]).compact
          visible_chunk_keys = visible_entries.map { |entry| entry[:key] }.compact

          cloud.prefetcher.prefetch_for_view(
            visible_entries,
            budget: @settings[:budget],
            camera_position: camera_position
          )
          cloud.pipeline.next_chunks(
            frame_budget: @settings[:budget],
            frustum: frustum,
            camera_position: camera_position,
            visible_chunk_keys: visible_chunk_keys,
            visible_nodes: visible_nodes
          ).each do |key, chunk|
            next unless chunk

            next unless chunk_visible?(chunk, frustum, view)

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

          next unless chunk_visible?(entry[:chunk], frustum, view)

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
        return unless view

        epsilon = Core::Spatial::Frustum::DEFAULT_EPSILON
        camera = view.respond_to?(:camera) ? view.camera : nil

        modelview = extract_matrix(camera, :modelview_matrix) || extract_matrix(view, :modelview_matrix, :modelview)
        projection = extract_matrix(camera, :projection_matrix) || extract_matrix(view, :projection_matrix, :projection)

        return unless modelview && projection

        Core::Spatial::Frustum.from_view_matrices(modelview, projection, epsilon: epsilon)
      rescue ArgumentError
        nil
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

      SCREEN_MARGIN = 32

      def empty_metadata?(metadata)
        return false unless metadata.is_a?(Hash)

        metadata[:empty] || metadata['empty'] ? true : false
      end

      def extract_bounds(source)
        return unless source

        bounds =
          if source.is_a?(Hash) && (source.key?(:min) || source.key?('min'))
            source
          elsif source.is_a?(Hash)
            source[:bounds] || source['bounds']
          end

        return unless bounds_valid?(bounds)

        bounds
      end

      def chunk_visible?(chunk, frustum, view)
        return false if chunk.respond_to?(:empty?) && chunk.empty?

        metadata = chunk.respond_to?(:metadata) ? chunk.metadata : nil
        return false if empty_metadata?(metadata)

        bounds = extract_bounds(metadata)
        return false unless bounds

        visible_bounds?(bounds, frustum, view)
      end

      def visible_chunk_data_for(cloud, frustum, view)
        nodes = cloud.pipeline.visible_nodes_for(frustum)
        return { entries: [], nodes: [] } unless nodes

        visible_nodes = []

        entries = Array(nodes).flat_map do |node|
          next [] unless node.respond_to?(:chunk_refs)

          chunk_entries = Array(node.chunk_refs).filter_map do |ref|
            key = ref[:key] || ref['key']
            next unless key

            bounds = extract_bounds(ref)
            next unless bounds
            next unless visible_bounds?(bounds, frustum, view)

            { key: key, bounds: bounds }
          end

          visible_nodes << node if chunk_entries.any?
          chunk_entries
        end

        {
          entries: entries.uniq { |entry| entry[:key] },
          nodes: visible_nodes.uniq
        }
      rescue StandardError
        { entries: [], nodes: [] }
      end

      def visible_bounds?(bounds, frustum, view)
        return false unless bounds_valid?(bounds)

        visible = screen_culling_visibility(view, bounds)
        return visible unless visible.nil?

        return false unless frustum

        frustum.intersects_bounds?(bounds)
      end

      def screen_culling_visibility(view, bounds)
        return nil unless view&.respond_to?(:screen_coords)

        viewport = viewport_rect(view, SCREEN_MARGIN)
        return nil unless viewport

        corners = bounds_corners(bounds)
        return nil unless corners.any?

        corners.any? do |corner|
          screen_point = view.screen_coords(corner)
          screen_point_visible?(screen_point, viewport)
        end
      rescue StandardError
        nil
      end

      def viewport_rect(view, margin)
        return unless view.respond_to?(:vpwidth) && view.respond_to?(:vpheight)

        width = view.vpwidth
        height = view.vpheight
        return nil unless width && height

        {
          min_x: -margin,
          max_x: width + margin,
          min_y: -margin,
          max_y: height + margin
        }
      end

      AXIS_INDEX = { x: 0, y: 1, z: 2 }.freeze

      def bounds_valid?(bounds)
        return false unless bounds.is_a?(Hash)

        min = bounds[:min] || bounds['min']
        max = bounds[:max] || bounds['max']
        return false unless min.is_a?(Array) && max.is_a?(Array)
        return false unless min.length >= 3 && max.length >= 3

        (0..2).all? do |axis|
          mn = min[axis]
          mx = max[axis]
          next false if mn.nil? || mx.nil?

          numeric?(mn) && numeric?(mx)
        end
      end

      def screen_point_visible?(screen_point, viewport)
        return false unless screen_point && viewport

        z = component_from_point(screen_point, :z)
        return false unless z && z.to_f.positive?

        x = component_from_point(screen_point, :x)
        y = component_from_point(screen_point, :y)
        return false unless x && y

        x.between?(viewport[:min_x], viewport[:max_x]) &&
          y.between?(viewport[:min_y], viewport[:max_y])
      end

      def bounds_corners(bounds)
        min_coords = to_coordinates(bounds[:min] || bounds['min'])
        max_coords = to_coordinates(bounds[:max] || bounds['max'])
        return [] unless min_coords && max_coords

        xs = [min_coords[0].to_f, max_coords[0].to_f]
        ys = [min_coords[1].to_f, max_coords[1].to_f]
        zs = [min_coords[2].to_f, max_coords[2].to_f]

        xs.flat_map do |x|
          ys.flat_map do |y|
            zs.map { |z| build_point3d(x, y, z) }
          end
        end
      end

      def numeric?(value)
        value.respond_to?(:to_f)
      end

      def build_point3d(x, y, z)
        if defined?(Geom::Point3d)
          Geom::Point3d.new(x, y, z)
        else
          [x, y, z]
        end
      end

      def component_from_point(point, axis)
        return unless point

        method_name = axis
        return point.public_send(method_name) if point.respond_to?(method_name)

        index = AXIS_INDEX.fetch(axis)

        if point.is_a?(Array)
          point[index]
        elsif point.respond_to?(:to_a)
          array = point.to_a
          array[index] if array.length > index
        elsif point.respond_to?(:[])
          point[index]
        end
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
