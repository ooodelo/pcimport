# frozen_string_literal: true

module PointCloudPlugin
  module UI
    # Renders import progress overlay with stage indicators and cancel affordance.
    class ImportOverlay
      attr_reader :state

      STEP_LABELS = {
        hash_check: 'Проверка источника',
        sampling: 'Выборка точек',
        cache_write: 'Запись кэша',
        build: 'Построение модели'
      }.freeze

      STATE_TITLES = {
        initializing: 'Загрузка облака…',
        hash_check: 'Загрузка облака…',
        sampling: 'Загрузка облака…',
        cache_write: 'Загрузка облака…',
        build: 'Загрузка облака…',
        navigating: 'Работа: навигация',
        cancelled: 'Загрузка отменена'
      }.freeze

      BUTTON_LABEL = 'Отмена'
      DEFAULT_FONT_SIZE = 18
      TITLE_FONT_SIZE = 28
      BUTTON_PADDING = 12
      PANEL_PADDING = 24
      SPACING = 12

      def initialize
        @state = :idle
        @visible = false
        @stage_status = default_stage_status
        @stage_progress = default_stage_progress
        @cancel_hit_region = nil
      end

      def show!
        @visible = true
      end

      def hide!
        @visible = false
        @cancel_hit_region = nil
      end

      def visible?
        @visible
      end

      def update_state(new_state)
        new_state = new_state.to_sym
        return if @state == new_state

        @state = new_state
        update_stage_status_for(new_state)
      end

      def update_stage_progress(progress_hash)
        return unless progress_hash.is_a?(Hash)

        progress_hash.each do |key, value|
          next unless @stage_progress.key?(key)

          @stage_progress[key] = value.to_f.clamp(0.0, 1.0)
        end
      end

      def draw(view)
        return unless visible?
        return unless view.respond_to?(:draw_text)

        ensure_geometry_dependencies

        text_col = text_color
        options = { size: DEFAULT_FONT_SIZE, align: 1, color: text_col }
        title_options = options.merge(size: TITLE_FONT_SIZE)

        lines = overlay_lines
        text = lines.join("\n")
        title = STATE_TITLES.fetch(state, STATE_TITLES[:initializing])

        title_extent = safe_text_extent(view, title, title_options)
        body_extent = safe_text_extent(view, text, options)

        panel_width = [title_extent[0], body_extent[0], button_width(view, options)].max + PANEL_PADDING * 2
        panel_height = title_extent[1] + body_extent[1] + button_height(view, options) + PANEL_PADDING * 3 + SPACING * 2

        origin = panel_origin(view, panel_width, panel_height)

        draw_panel_background(view, origin, panel_width, panel_height)

        title_point = build_point(origin.x + PANEL_PADDING, origin.y + PANEL_PADDING)
        view.draw_text(title_point, title, title_options)

        body_point = build_point(origin.x + PANEL_PADDING, title_point.y + title_extent[1] + SPACING)
        view.draw_text(body_point, text, options)

        draw_cancel_button(view, origin, panel_width, body_point.y + body_extent[1] + SPACING, options)
      end

      def cancel_hit?(x, y)
        return false unless @cancel_hit_region

        x >= @cancel_hit_region[:min_x] &&
          x <= @cancel_hit_region[:max_x] &&
          y >= @cancel_hit_region[:min_y] &&
          y <= @cancel_hit_region[:max_y]
      end

      def cancel_enabled?
        visible? && !%i[navigating cancelled idle].include?(state)
      end

      private

      def overlay_lines
        STEP_LABELS.map do |key, label|
          status = @stage_status[key]
          progress = (@stage_progress[key] * 100).round
          indicator = case status
                      when :complete then '▰'
                      when :active then '▣'
                      else '▱'
                      end
          format('%s: %s %d%%', label, indicator, progress)
        end
      end

      def default_stage_status
        {
          hash_check: :pending,
          sampling: :pending,
          cache_write: :pending,
          build: :pending
        }
      end

      def default_stage_progress
        {
          hash_check: 0.0,
          sampling: 0.0,
          cache_write: 0.0,
          build: 0.0
        }
      end

      def update_stage_status_for(new_state)
        @stage_status = default_stage_status

        case new_state
        when :initializing
          @stage_status[:hash_check] = :active
        when :hash_check
          @stage_status[:hash_check] = :active
        when :sampling
          @stage_status[:hash_check] = :complete
          @stage_status[:sampling] = :active
        when :cache_write
          @stage_status[:hash_check] = :complete
          @stage_status[:sampling] = :complete
          @stage_status[:cache_write] = :active
        when :build
          @stage_status[:hash_check] = :complete
          @stage_status[:sampling] = :complete
          @stage_status[:cache_write] = :complete
          @stage_status[:build] = :active
        when :navigating
          @stage_status.transform_values! { |_value| :complete }
        when :cancelled
          @stage_status.transform_values! { |_value| :pending }
        end
      end

      def ensure_geometry_dependencies
        return if defined?(Geom)

        Object.const_set(:Geom, Module.new) unless defined?(Geom)
        Geom.const_set(:Point3d, Struct.new(:x, :y, :z)) unless Geom.const_defined?(:Point3d)
      end

      def safe_text_extent(view, text, options)
        extent = if view.respond_to?(:text_extent)
                   begin
                     view.text_extent(text, options)
                   rescue ArgumentError
                     view.text_extent(text)
                   end
                 end

        width = extent && extent[0] ? extent[0] : 0
        height = extent && extent[1] ? extent[1] : 0
        [width, height]
      end

      def panel_origin(view, panel_width, panel_height)
        vp_width = view.respond_to?(:vpwidth) ? view.vpwidth : 0
        vp_height = view.respond_to?(:vpheight) ? view.vpheight : 0

        x = (vp_width - panel_width) / 2.0
        y = (vp_height - panel_height) / 2.0
        build_point(x, y)
      end

      def draw_panel_background(view, origin, width, height)
        return unless view.respond_to?(:draw2d)
        return unless defined?(GL_QUADS)

        view.drawing_color = [240, 240, 240, 230] if view.respond_to?(:drawing_color=)

        top_left = build_point(origin.x, origin.y)
        top_right = build_point(origin.x + width, origin.y)
        bottom_right = build_point(origin.x + width, origin.y + height)
        bottom_left = build_point(origin.x, origin.y + height)

        view.draw2d(GL_QUADS, [
          top_left,
          top_right,
          bottom_right,
          bottom_left
        ])
      rescue NameError => e
        PointCloudPlugin.log("GL constants unavailable: #{e.message}") if defined?(PointCloudPlugin)
      rescue StandardError => e
        PointCloudPlugin.log("Failed to draw panel background: #{e.message}") if defined?(PointCloudPlugin)
      end

      def button_width(view, options)
        safe_text_extent(view, BUTTON_LABEL, options)[0] + BUTTON_PADDING * 2
      end

      def button_height(view, options)
        safe_text_extent(view, BUTTON_LABEL, options)[1] + BUTTON_PADDING * 2
      end

      def draw_cancel_button(view, origin, panel_width, baseline_y, options)
        unless cancel_enabled?
          @cancel_hit_region = nil
          return
        end

        button_w = button_width(view, options)
        button_h = button_height(view, options)

        x = origin.x + (panel_width - button_w) / 2.0
        y = baseline_y
        button_origin = build_point(x, y)

        if view.respond_to?(:draw2d)
          draw_button_background(view, button_origin, button_w, button_h)
        end

        text_origin = build_point(button_origin.x + BUTTON_PADDING, button_origin.y + BUTTON_PADDING)
        view.draw_text(text_origin, BUTTON_LABEL, options)

        @cancel_hit_region = {
          min_x: x,
          max_x: x + button_w,
          min_y: y,
          max_y: y + button_h
        }
      end

      def draw_button_background(view, origin, width, height)
        top_left = build_point(origin.x, origin.y)
        top_right = build_point(origin.x + width, origin.y)
        bottom_right = build_point(origin.x + width, origin.y + height)
        bottom_left = build_point(origin.x, origin.y + height)

        view.draw2d(GL_LINE_LOOP, [top_left, top_right, bottom_right, bottom_left])
      rescue NameError
        nil
      end

      def build_point(x, y, z = 0)
        if defined?(Geom::Point3d)
          Geom::Point3d.new(x, y, z)
        else
          Struct.new(:x, :y, :z).new(x, y, z)
        end
      end

      def text_color
        if defined?(Sketchup::Color)
          Sketchup::Color.new(0, 0, 0)
        else
          [0, 0, 0]
        end
      end
    end
  end
end
