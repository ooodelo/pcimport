# frozen_string_literal: true

require 'json'

module PointCloudPlugin
  module UI
    # Settings dialog for adjusting runtime parameters.
    class DialogSettings
      DEFAULTS = {
        budget: 2_000_000,
        point_size: 2,
        snap_radius: 5.0,
        memory_limit: 512,
        monochrome: false
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
      end

      def show
        return unless defined?(::UI) && ::UI.const_defined?(:HtmlDialog)

        @dialog ||= build_dialog
        @dialog.show
      end

      def on_change(&block)
        @on_change = block
      end

      private

      def build_dialog
        dialog = ::UI::HtmlDialog.new(dialog_title: 'Point Cloud Settings', width: 360, height: 360)
        budget_millions = (settings[:budget].to_f / 1_000_000.0)
        budget_display = format('%.1f', budget_millions)
        monochrome_checked = settings[:monochrome] ? 'checked' : ''

        html = <<~HTML
          <html>
            <head>
              <style>
                body { font-family: sans-serif; margin: 16px; }
                label { display: block; margin-bottom: 12px; }
                .section { margin-bottom: 24px; }
                .slider-row { display: flex; align-items: center; gap: 12px; }
                .slider-row span { min-width: 110px; font-weight: bold; }
                .buttons { display: flex; gap: 12px; }
              </style>
            </head>
            <body>
              <div class="section">
                <label>Frame budget</label>
                <div class="slider-row">
                  <input id="budget_slider" type="range" min="0.5" max="5" step="0.1" value="#{budget_display}">
                  <span id="budget_value">#{budget_display} M points</span>
                </div>
                <button id="panic_button" type="button">Panic</button>
              </div>
              <div class="section">
                <label>Point size: <input id="point_size" type="number" min="1" value="#{settings[:point_size]}"></label>
                <label>Snap radius: <input id="snap_radius" type="number" step="0.1" value="#{settings[:snap_radius]}"></label>
                <label>Memory limit (MB): <input id="memory_limit" type="number" min="128" value="#{settings[:memory_limit]}"></label>
                <label><input id="monochrome" type="checkbox" #{monochrome_checked}> Monochrome</label>
              </div>
              <div class="buttons">
                <button id="apply_button" type="button">Apply</button>
                <button id="cancel_button" type="button">Cancel</button>
              </div>
              <script>
                (function() {
                  const slider = document.getElementById('budget_slider');
                  const display = document.getElementById('budget_value');
                  const panicButton = document.getElementById('panic_button');
                  const applyButton = document.getElementById('apply_button');
                  const cancelButton = document.getElementById('cancel_button');

                  function updateDisplay() {
                    const value = parseFloat(slider.value);
                    display.textContent = value.toFixed(1) + ' M points';
                  }

                  slider.addEventListener('input', updateDisplay);
                  updateDisplay();

                  panicButton.addEventListener('click', function() {
                    const min = parseFloat(slider.min);
                    const current = parseFloat(slider.value);
                    const next = Math.max(min, current / 2);
                    slider.value = next.toFixed(1);
                    slider.dispatchEvent(new Event('input'));
                  });

                  applyButton.addEventListener('click', function() {
                    const payload = {
                      budget: Math.round(parseFloat(slider.value) * 1000000),
                      point_size: parseInt(document.getElementById('point_size').value, 10),
                      snap_radius: parseFloat(document.getElementById('snap_radius').value),
                      memory_limit: parseInt(document.getElementById('memory_limit').value, 10),
                      monochrome: document.getElementById('monochrome').checked
                    };
                    if (window.sketchup && typeof window.sketchup.apply === 'function') {
                      window.sketchup.apply(JSON.stringify(payload));
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

      def notify_runtime_change
        snapshot = @settings.dup
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

        {
          budget: clamp_integer(fetch_numeric(data, :budget, settings[:budget]), 100_000, 10_000_000),
          point_size: clamp_integer(fetch_numeric(data, :point_size, settings[:point_size]), 1, 9),
          snap_radius: clamp_float(fetch_numeric(data, :snap_radius, settings[:snap_radius]), 0.1, 1000.0),
          memory_limit: clamp_integer(fetch_numeric(data, :memory_limit, settings[:memory_limit]), 128, 65_536),
          monochrome: fetch_boolean(data, :monochrome, settings[:monochrome])
        }
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
