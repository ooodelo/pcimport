# frozen_string_literal: true

require 'json'

module PointCloudPlugin
  module UI
    # Settings dialog for adjusting runtime parameters.
    class DialogSettings
      DEFAULT_MODE = :navigation

      PRESETS = {
        navigation: {
          label: 'Наведение',
          hint: 'Наведение: плавность выше, точек меньше, точки крупнее.',
          budget: 1_200_000,
          point_size: 3,
          prefetch_limit: 16,
          prefetch_angle_weight: 6.0,
          prefetch_distance_weight: 1.0,
          prefetch_forward_threshold: 0.3,
          preview_threshold: 0.05
        },
        detail: {
          label: 'Детализация',
          hint: 'Детализация: деталей больше, FPS может снизиться, точки мельче.',
          budget: 3_000_000,
          point_size: 1,
          prefetch_limit: 40,
          prefetch_angle_weight: 14.0,
          prefetch_distance_weight: 1.0,
          prefetch_forward_threshold: -0.1,
          preview_threshold: 0.18
        }
      }.freeze

      DEFAULTS = {
        mode: DEFAULT_MODE,
        preset_customized: false,
        budget: PRESETS[DEFAULT_MODE][:budget],
        point_size: PRESETS[DEFAULT_MODE][:point_size],
        snap_radius: 5.0,
        memory_limit: 512,
        monochrome: false,
        prefetch_limit: PRESETS[DEFAULT_MODE][:prefetch_limit],
        prefetch_angle_weight: PRESETS[DEFAULT_MODE][:prefetch_angle_weight],
        prefetch_distance_weight: PRESETS[DEFAULT_MODE][:prefetch_distance_weight],
        prefetch_forward_threshold: PRESETS[DEFAULT_MODE][:prefetch_forward_threshold],
        preview_threshold: PRESETS[DEFAULT_MODE][:preview_threshold],
        preview_show_points: false,
        preview_anchor_only: false
      }.freeze

      IMPORT_UNITS = [
        [:meter, 'Meters'],
        [:millimeter, 'Millimeters'],
        [:centimeter, 'Centimeters'],
        [:foot, 'Feet'],
        [:inch, 'Inches']
      ].freeze

      attr_reader :settings

      def initialize
        @settings = DEFAULTS.dup
        @dialog = nil
        @preview_controls_state = default_preview_controls_state
      end

      def show
        return unless defined?(::UI) && ::UI.const_defined?(:HtmlDialog)

        @dialog ||= build_dialog
        @dialog.show
      end

      def on_change(&block)
        @on_change = block
      end

      def update_preview_controls(available:, show_points: nil, anchors_only: nil)
        state = preview_controls_state.dup
        state[:available] = !!available unless available.nil?
        state[:show_points] = !!show_points unless show_points.nil?
        state[:anchors_only] = !!anchors_only unless anchors_only.nil?
        state[:anchors_only] = false unless state[:show_points]
        @preview_controls_state = state
        push_preview_state_to_dialog
      end

      private

      def build_dialog
        dialog = ::UI::HtmlDialog.new(dialog_title: 'Point Cloud Settings', width: 380, height: 420)
        budget_millions = (settings[:budget].to_f / 1_000_000.0)
        budget_display = format('%.1f', budget_millions)
        monochrome_checked = settings[:monochrome] ? 'checked' : ''
        mode_symbol = normalize_mode(settings[:mode])
        current_mode = mode_symbol.to_s
        preset = preset_for(mode_symbol)
        presets_json = JSON.generate(serializable_presets)
        current_prefetch = {
          limit: settings[:prefetch_limit] || preset[:prefetch_limit],
          angleWeight: settings[:prefetch_angle_weight] || preset[:prefetch_angle_weight],
          distanceWeight: settings[:prefetch_distance_weight] || preset[:prefetch_distance_weight],
          forwardThreshold: settings[:prefetch_forward_threshold] || preset[:prefetch_forward_threshold],
          previewThreshold: settings[:preview_threshold] || preset[:preview_threshold]
        }
        current_prefetch_json = JSON.generate(current_prefetch)
        customized_flag = settings[:preset_customized] ? 'true' : 'false'
        preview_state = preview_controls_state
        preview_state_json = JSON.generate(preview_state)
        preview_checked = preview_state[:show_points] ? 'checked' : ''
        preview_disabled = preview_state[:available] ? '' : 'disabled'
        anchors_checked = preview_state[:anchors_only] ? 'checked' : ''
        anchors_disabled = (!preview_state[:available] || !preview_state[:show_points]) ? 'disabled' : ''

        html = <<~HTML
          <html>
            <head>
              <style>
                body { font-family: sans-serif; margin: 16px; }
                label { display: block; margin-bottom: 12px; }
                .section { margin-bottom: 24px; }
                .slider-row { display: flex; align-items: center; gap: 12px; }
                .slider-row span { min-width: 140px; font-weight: bold; }
                .buttons { display: flex; gap: 12px; }
                .mode-toggle { display: inline-flex; border: 1px solid #889; border-radius: 18px; overflow: hidden; }
                .mode-button { border: none; background: transparent; padding: 6px 16px; cursor: pointer; font-weight: 600; font-size: 13px; }
                .mode-button.active { background: #2f74ff; color: #fff; }
                .mode-button:not(.active):hover { background: rgba(47, 116, 255, 0.12); }
                .mode-hint { margin-top: 8px; font-size: 12px; color: #333; line-height: 1.4; }
                .mode-custom { margin-top: 6px; font-size: 11px; color: #aa5500; display: none; }
                #panic_button { margin-top: 8px; }
                .preview-controls { border-top: 1px solid #d0d0d0; padding-top: 12px; margin-top: 12px; }
                .preview-controls label { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
                .preview-controls label.nested { margin-left: 20px; font-weight: normal; }
                .preview-controls .hint { font-size: 11px; color: #555; margin-top: 4px; }
              </style>
            </head>
            <body>
              <div class="section">
                <label>Режим просмотра</label>
                <div class="mode-toggle" role="group" aria-label="Режим просмотра">
                  <button class="mode-button" type="button" data-mode="navigation">Наведение</button>
                  <button class="mode-button" type="button" data-mode="detail">Детализация</button>
                </div>
                <div class="mode-hint" id="mode_hint"></div>
                <div class="mode-custom" id="mode_custom_hint"></div>
              </div>
              <div class="section">
                <label>Бюджет точек на кадр</label>
                <div class="slider-row">
                  <input id="budget_slider" type="range" min="0.5" max="5" step="0.1" value="#{budget_display}">
                  <span id="budget_value">#{budget_display} M точек</span>
                </div>
                <button id="panic_button" type="button">Паника</button>
              </div>
              <div class="section">
                <label>Размер точки: <input id="point_size" type="number" min="1" max="9" value="#{settings[:point_size]}"></label>
                <label>Радиус привязки: <input id="snap_radius" type="number" step="0.1" value="#{settings[:snap_radius]}"></label>
                <label>Лимит памяти (МБ): <input id="memory_limit" type="number" min="128" value="#{settings[:memory_limit]}"></label>
                <label><input id="monochrome" type="checkbox" #{monochrome_checked}> Монохром</label>
              </div>
              <div class="section preview-controls">
                <label><input id="preview_points_toggle" type="checkbox" #{preview_checked} #{preview_disabled}> Показать точки предпросмотра</label>
                <label class="nested"><input id="preview_anchor_toggle" type="checkbox" #{anchors_checked} #{anchors_disabled}> Только опорные точки</label>
                <div class="hint" id="preview_hint">Точки появятся после подготовки выборки.</div>
              </div>
              <div class="buttons">
                <button id="apply_button" type="button">Применить</button>
                <button id="cancel_button" type="button">Закрыть</button>
              </div>
              <script>
                (function() {
                  const PRESETS = #{presets_json};
                  let currentMode = '#{current_mode}';
                  let presetCustomized = #{customized_flag};
                  let currentPrefetch = #{current_prefetch_json};
                  let isApplyingPreset = false;
                  let previewState = #{preview_state_json};

                  const slider = document.getElementById('budget_slider');
                  const display = document.getElementById('budget_value');
                  const panicButton = document.getElementById('panic_button');
                  const applyButton = document.getElementById('apply_button');
                  const cancelButton = document.getElementById('cancel_button');
                  const pointSizeInput = document.getElementById('point_size');
                  const snapRadiusInput = document.getElementById('snap_radius');
                  const memoryLimitInput = document.getElementById('memory_limit');
                  const monochromeInput = document.getElementById('monochrome');
                  const modeHint = document.getElementById('mode_hint');
                  const customHint = document.getElementById('mode_custom_hint');
                  const modeButtons = Array.prototype.slice.call(document.querySelectorAll('.mode-button'));
                  const previewToggle = document.getElementById('preview_points_toggle');
                  const anchorToggle = document.getElementById('preview_anchor_toggle');
                  const previewHint = document.getElementById('preview_hint');

                  function updateDisplay() {
                    const value = parseFloat(slider.value);
                    display.textContent = value.toFixed(1) + ' M точек';
                  }

                  function updateModeButtons() {
                    modeButtons.forEach((button) => {
                      const active = button.dataset.mode === currentMode;
                      button.classList.toggle('active', active);
                    });
                  }

                  function updateHints() {
                    const preset = PRESETS[currentMode];
                    if (preset && modeHint) {
                      modeHint.textContent = preset.hint || '';
                    }
                    if (customHint) {
                      if (presetCustomized) {
                        customHint.textContent = 'Ручная корректировка активна — переключите режим, чтобы вернуть базовые значения.';
                        customHint.style.display = 'block';
                      } else {
                        customHint.textContent = '';
                        customHint.style.display = 'none';
                      }
                    }
                  }

                  function applyPreviewState(state) {
                    if (!state) {
                      return;
                    }
                    if (typeof state.available === 'boolean') {
                      previewState.available = state.available;
                    }
                    if (typeof state.show_points === 'boolean') {
                      previewState.show_points = state.show_points;
                    }
                    if (typeof state.anchors_only === 'boolean') {
                      previewState.anchors_only = state.anchors_only;
                    }
                    if (!previewState.show_points) {
                      previewState.anchors_only = false;
                    }
                    if (previewToggle) {
                      previewToggle.disabled = !previewState.available;
                      previewToggle.checked = !!previewState.show_points;
                    }
                    if (anchorToggle) {
                      anchorToggle.disabled = !previewState.available || !previewState.show_points;
                      anchorToggle.checked = !!previewState.show_points && !!previewState.anchors_only;
                    }
                    if (previewHint) {
                      previewHint.textContent = previewState.available ? 'Переключение работает без повторного импорта.' : 'Точки появятся после подготовки выборки.';
                    }
                  }

                  function submitSettings() {
                    const payload = {
                      mode: currentMode,
                      preset_customized: presetCustomized,
                      budget: Math.round(parseFloat(slider.value) * 1000000),
                      point_size: parseInt(pointSizeInput.value, 10),
                      snap_radius: parseFloat(snapRadiusInput.value),
                      memory_limit: parseInt(memoryLimitInput.value, 10),
                      monochrome: monochromeInput.checked,
                      prefetch_limit: currentPrefetch.limit,
                      prefetch_angle_weight: currentPrefetch.angleWeight,
                      prefetch_distance_weight: currentPrefetch.distanceWeight,
                      prefetch_forward_threshold: currentPrefetch.forwardThreshold,
                      preview_threshold: currentPrefetch.previewThreshold,
                      preview_show_points: previewState.available ? !!previewState.show_points : false,
                      preview_anchor_only: previewState.available ? !!previewState.anchors_only : false
                    };

                    if (window.sketchup && typeof window.sketchup.apply === 'function') {
                      window.sketchup.apply(JSON.stringify(payload));
                    }
                  }

                  function applyPreset(mode) {
                    const preset = PRESETS[mode];
                    if (!preset) {
                      return;
                    }
                    currentMode = mode;
                    isApplyingPreset = true;
                    slider.value = (preset.budget / 1000000).toFixed(1);
                    updateDisplay();
                    pointSizeInput.value = preset.point_size;
                    isApplyingPreset = false;
                    currentPrefetch = {
                      limit: preset.prefetch_limit,
                      angleWeight: preset.prefetch_angle_weight,
                      distanceWeight: preset.prefetch_distance_weight,
                      forwardThreshold: preset.prefetch_forward_threshold,
                      previewThreshold: preset.preview_threshold
                    };
                    presetCustomized = false;
                    updateModeButtons();
                    updateHints();
                    submitSettings();
                  }

                  function markCustomized() {
                    presetCustomized = true;
                    updateHints();
                  }

                  slider.addEventListener('input', () => {
                    updateDisplay();
                    if (!isApplyingPreset) {
                      markCustomized();
                    }
                  });

                  pointSizeInput.addEventListener('input', () => {
                    if (!isApplyingPreset) {
                      markCustomized();
                    }
                  });

                  panicButton.addEventListener('click', () => {
                    const min = parseFloat(slider.min);
                    const current = parseFloat(slider.value);
                    const next = Math.max(min, current / 2);
                    slider.value = next.toFixed(1);
                    slider.dispatchEvent(new Event('input'));
                  });

                  modeButtons.forEach((button) => {
                    button.addEventListener('click', () => {
                      const mode = button.dataset.mode;
                      if (mode && mode !== currentMode) {
                        applyPreset(mode);
                      }
                    });
                  });

                  if (previewToggle) {
                    previewToggle.addEventListener('change', () => {
                      if (!previewState.available) {
                        previewToggle.checked = false;
                        return;
                      }
                      previewState.show_points = previewToggle.checked;
                      if (!previewToggle.checked) {
                        previewState.anchors_only = false;
                        if (anchorToggle) {
                          anchorToggle.checked = false;
                        }
                      }
                      if (anchorToggle) {
                        anchorToggle.disabled = !previewToggle.checked;
                      }
                    });
                  }

                  if (anchorToggle) {
                    anchorToggle.addEventListener('change', () => {
                      previewState.anchors_only = anchorToggle.checked;
                    });
                  }

                  window.sketchup = window.sketchup || {};
                  window.sketchup.previewControls = function(payload) {
                    try {
                      const parsed = (typeof payload === 'string') ? JSON.parse(payload) : payload;
                      applyPreviewState(parsed || {});
                    } catch (error) {
                      console.warn('Failed to parse preview state', error);
                    }
                  };

                  applyButton.addEventListener('click', submitSettings);

                  cancelButton.addEventListener('click', () => {
                    window.close();
                  });

                  updateDisplay();
                  updateModeButtons();
                  updateHints();
                  applyPreviewState(previewState);
                })();
              </script>
            </body>
          </html>
        HTML
        dialog.set_html(html)
        dialog.add_action_callback('apply') do |_context, payload|
          raw = safe_parse_json(payload)
          normalized = normalize_runtime_settings(raw)
          @settings.merge!(normalized)
          notify_runtime_change
        end
        dialog
      end
      def show_import_dialog(initial_options = {})
        overrides = initial_options || {}
        defaults = merge_import_defaults(import_options.merge(overrides))

        unless defined?(::UI) && ::UI.const_defined?(:HtmlDialog)
          yield defaults if block_given?
          @last_import_options = defaults
          return nil
        end

        dialog = ::UI::HtmlDialog.new(dialog_title: 'Import Options', width: 360, height: 320)
        options_markup = IMPORT_UNITS.map do |value, label|
          selected = value.to_s == defaults[:unit].to_s ? ' selected' : ''
          "<option value=\"#{value}\"#{selected}>#{label}</option>"
        end.join
        offset = defaults[:offset]

        html = <<~HTML
          <html>
            <head>
              <style>
                body { font-family: sans-serif; margin: 16px; }
                label { display: block; margin-bottom: 12px; }
                .offset-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
                .buttons { display: flex; gap: 12px; }
              </style>
            </head>
            <body>
              <label for="import_unit">Units:
                <select id="import_unit">
                  #{options_markup}
                </select>
              </label>
              <div class="offset-grid">
                <label>X offset: <input id="offset_x" type="number" step="0.01" value="#{offset[:x]}"></label>
                <label>Y offset: <input id="offset_y" type="number" step="0.01" value="#{offset[:y]}"></label>
                <label>Z offset: <input id="offset_z" type="number" step="0.01" value="#{offset[:z]}"></label>
              </div>
              <div class="buttons">
                <button id="apply_button" type="button">Apply</button>
                <button id="cancel_button" type="button">Cancel</button>
              </div>
              <script>
                (function() {
                  const applyButton = document.getElementById('apply_button');
                  const cancelButton = document.getElementById('cancel_button');

                  applyButton.addEventListener('click', function() {
                    const payload = {
                      unit: document.getElementById('import_unit').value,
                      offset_x: parseFloat(document.getElementById('offset_x').value || 0),
                      offset_y: parseFloat(document.getElementById('offset_y').value || 0),
                      offset_z: parseFloat(document.getElementById('offset_z').value || 0)
                    };
                    if (window.sketchup && typeof window.sketchup.import_options === 'function') {
                      window.sketchup.import_options(JSON.stringify(payload));
                    }
                  });

                  cancelButton.addEventListener('click', function() {
                    window.close();
                  });
                })();
              </script>
            </body>
          </html>
        HTML
        dialog.set_html(html)
        dialog.add_action_callback('import_options') do |_context, payload|
          options = normalize_import_options(JSON.parse(payload))
          @last_import_options = options
          yield options if block_given?
          dialog.close
        end
        dialog.show
        @import_dialog = dialog
      end

      def import_options
        stored = @last_import_options ||= merge_import_defaults({})
        {
          unit: stored[:unit],
          offset: stored[:offset].dup
        }
      end

      def merge_import_defaults(overrides)
        defaults = { unit: :meter, offset: { x: 0.0, y: 0.0, z: 0.0 } }
        overrides = overrides.transform_keys(&:to_sym) if overrides.respond_to?(:transform_keys)

        unit = overrides && overrides[:unit] ? overrides[:unit].to_sym : defaults[:unit]
        offset_source = extract_offset_source(overrides)

        offset = defaults[:offset].merge({
                                       x: fetch_offset_value(offset_source, :x),
                                       y: fetch_offset_value(offset_source, :y),
                                       z: fetch_offset_value(offset_source, :z)
                                     })

        { unit: unit, offset: offset }
      end

      def extract_offset_source(overrides)
        return {} unless overrides

        if overrides[:offset]
          source = overrides[:offset]
          source.respond_to?(:transform_keys) ? source.transform_keys(&:to_sym) : source
        else
          {
            x: overrides[:offset_x],
            y: overrides[:offset_y],
            z: overrides[:offset_z]
          }
        end
      end

      def fetch_offset_value(source, key)
        value = source[key]
        value = source[key.to_s] if value.nil? && source.respond_to?(:[])
        value.nil? ? 0.0 : value.to_f
      end

      def normalize_import_options(options)
        merged = merge_import_defaults(options)
        {
          unit: merged[:unit],
          offset: merged[:offset]
        }
      end

      public :show_import_dialog, :import_options

      private

      def serializable_presets
        PRESETS.transform_values do |preset|
          {
            label: preset[:label],
            hint: preset[:hint],
            budget: preset[:budget],
            point_size: preset[:point_size],
            prefetch_limit: preset[:prefetch_limit],
            prefetch_angle_weight: preset[:prefetch_angle_weight],
            prefetch_distance_weight: preset[:prefetch_distance_weight],
            prefetch_forward_threshold: preset[:prefetch_forward_threshold],
            preview_threshold: preset[:preview_threshold]
          }
        end
      end

      def preset_for(mode)
        PRESETS[normalize_mode(mode)]
      end

      def normalize_mode(value, fallback = DEFAULT_MODE)
        symbol =
          case value
          when Symbol then value
          when String then value.to_s.strip.downcase.to_sym
          else
            fallback || DEFAULT_MODE
          end

        PRESETS.key?(symbol) ? symbol : fallback || DEFAULT_MODE
      end

      def notify_runtime_change
        snapshot = @settings.dup
        sync_preview_state_from_settings
        @on_change&.call(snapshot)

        return unless defined?(PointCloudPlugin) && PointCloudPlugin.respond_to?(:apply_runtime_settings)

        PointCloudPlugin.apply_runtime_settings(snapshot)
      rescue StandardError
        # Ignore errors to keep dialog responsive.
      end

      def safe_parse_json(payload)
        return {} if payload.nil? || payload.to_s.empty?

        JSON.parse(payload)
      rescue JSON::ParserError
        {}
      end

      def normalize_runtime_settings(raw)
        data = raw.is_a?(Hash) ? raw : {}
        data = data.transform_keys { |key| key.to_s.downcase.to_sym }

        mode = normalize_mode(data[:mode], settings[:mode] || DEFAULT_MODE)
        preset = preset_for(mode)
        customized = fetch_boolean(data, :preset_customized, settings[:preset_customized])

        budget_fallback = settings[:budget] || preset[:budget]
        point_size_fallback = settings[:point_size] || preset[:point_size]
        prefetch_limit_fallback = settings[:prefetch_limit] || preset[:prefetch_limit]
        angle_fallback = settings[:prefetch_angle_weight] || preset[:prefetch_angle_weight]
        distance_fallback = settings[:prefetch_distance_weight] || preset[:prefetch_distance_weight]
        forward_fallback = settings[:prefetch_forward_threshold] || preset[:prefetch_forward_threshold]
        preview_fallback = settings[:preview_threshold] || preset[:preview_threshold]

        normalized = {
          mode: mode,
          preset_customized: customized,
          budget: clamp_integer(fetch_numeric(data, :budget, customized ? budget_fallback : preset[:budget]), 100_000, 10_000_000),
          point_size: clamp_integer(fetch_numeric(data, :point_size, customized ? point_size_fallback : preset[:point_size]), 1, 9),
          snap_radius: clamp_float(fetch_numeric(data, :snap_radius, settings[:snap_radius]), 0.1, 1000.0),
          memory_limit: clamp_integer(fetch_numeric(data, :memory_limit, settings[:memory_limit]), 128, 65_536),
          monochrome: fetch_boolean(data, :monochrome, settings[:monochrome]),
          prefetch_limit: clamp_integer(fetch_numeric(data, :prefetch_limit, customized ? prefetch_limit_fallback : preset[:prefetch_limit]), 4, 128),
          prefetch_angle_weight: clamp_float(fetch_numeric(data, :prefetch_angle_weight, customized ? angle_fallback : preset[:prefetch_angle_weight]), 0.1, 50.0),
          prefetch_distance_weight: clamp_float(fetch_numeric(data, :prefetch_distance_weight, customized ? distance_fallback : preset[:prefetch_distance_weight]), 0.1, 10.0),
          prefetch_forward_threshold: clamp_float(fetch_numeric(data, :prefetch_forward_threshold, customized ? forward_fallback : preset[:prefetch_forward_threshold]), -1.0, 1.0),
          preview_threshold: clamp_float(fetch_numeric(data, :preview_threshold, customized ? preview_fallback : preset[:preview_threshold]), 0.0, 1.0),
          preview_show_points: fetch_boolean(data, :preview_show_points, settings[:preview_show_points]),
          preview_anchor_only: fetch_boolean(data, :preview_anchor_only, settings[:preview_anchor_only])
        }

        normalized[:preview_anchor_only] = false unless normalized[:preview_show_points]

        unless customized
          normalized[:budget] = preset[:budget]
          normalized[:point_size] = preset[:point_size]
          normalized[:prefetch_limit] = preset[:prefetch_limit]
          normalized[:prefetch_angle_weight] = preset[:prefetch_angle_weight]
          normalized[:prefetch_distance_weight] = preset[:prefetch_distance_weight]
          normalized[:prefetch_forward_threshold] = preset[:prefetch_forward_threshold]
          normalized[:preview_threshold] = preset[:preview_threshold]
        end

        normalized
      end

      def preview_controls_state
        @preview_controls_state ||= default_preview_controls_state
      end

      def default_preview_controls_state
        {
          available: false,
          show_points: !!@settings[:preview_show_points],
          anchors_only: !!@settings[:preview_anchor_only]
        }
      end

      def push_preview_state_to_dialog
        return unless @dialog && @dialog.respond_to?(:execute_script)

        payload = JSON.generate(preview_controls_state)
        script = "window.sketchup && window.sketchup.previewControls && window.sketchup.previewControls(#{payload})"
        @dialog.execute_script(script)
      rescue StandardError
        nil
      end

      def sync_preview_state_from_settings
        state = preview_controls_state
        state[:show_points] = !!@settings[:preview_show_points]
        state[:anchors_only] = state[:show_points] && !!@settings[:preview_anchor_only]
        @preview_controls_state = state
      end

      def fetch_numeric(data, key, default)
        value = extract_scalar(data[key])
        return default if value.nil?

        if value.is_a?(Numeric)
          value
        elsif value.respond_to?(:to_s)
          text = value.to_s.strip
          return default if text.empty?

          begin
            Float(text)
          rescue ArgumentError
            default
          end
        else
          default
        end
      end

      def fetch_boolean(data, key, default)
        value = extract_scalar(data[key])
        case value
        when true, 'true', '1', 1 then true
        when false, 'false', '0', 0 then false
        else
          default
        end
      end

      def clamp_integer(value, min, max)
        coerced = value.to_i
        coerced = min if coerced < min
        coerced = max if coerced > max
        coerced
      end

      def clamp_float(value, min, max)
        coerced = value.to_f
        coerced = min if coerced < min
        coerced = max if coerced > max
        coerced
      end

      def extract_scalar(value)
        case value
        when Array
          extract_scalar(value.first)
        when Hash
          value[:value] || value['value']
        else
          value
        end
      end
    end
  end
end
