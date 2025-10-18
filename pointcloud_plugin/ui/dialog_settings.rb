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
        memory_limit: 512
      }.freeze

      IMPORT_DEFAULTS = {
        unit: :meter,
        offset: { x: 0.0, y: 0.0, z: 0.0 }
      }.freeze

      attr_reader :settings
      attr_reader :import_options

      def initialize
        @settings = DEFAULTS.dup
        @import_options = normalized_import_options
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
        dialog = ::UI::HtmlDialog.new(dialog_title: 'Point Cloud Settings', width: 360, height: 400)
        budget_millions = format('%.2f', settings[:budget] / 1_000_000.0)
        html = <<~HTML
          <html>
            <head>
              <style>
                body { font-family: sans-serif; margin: 16px; }
                label { display: block; margin-bottom: 12px; }
                .inline { display: flex; align-items: center; gap: 8px; }
                .actions { margin-top: 16px; display: flex; gap: 8px; }
                input[type=range] { width: 220px; }
              </style>
            </head>
            <body>
              <label>Frame budget
                <div class="inline">
                  <input id="budget" type="range" min="0.5" max="5" step="0.1" value="#{budget_millions}">
                  <span id="budget_display"></span>
                </div>
              </label>
              <div class="actions">
                <button id="panic" type="button">Panic</button>
              </div>
              <label>Point size: <input id="point_size" type="number" min="1" value="#{settings[:point_size]}"></label>
              <label>Snap radius: <input id="snap_radius" type="number" step="0.1" value="#{settings[:snap_radius]}"></label>
              <label>Memory limit (MB): <input id="memory_limit" type="number" min="128" value="#{settings[:memory_limit]}"></label>
              <div class="actions">
                <button id="apply" type="button">Apply</button>
              </div>
              <script>
                const budget = document.getElementById('budget');
                const display = document.getElementById('budget_display');
                const panic = document.getElementById('panic');
                const apply = document.getElementById('apply');
                const pointSize = document.getElementById('point_size');
                const snapRadius = document.getElementById('snap_radius');
                const memoryLimit = document.getElementById('memory_limit');

                function updateDisplay() {
                  const value = parseFloat(budget.value);
                  display.textContent = value.toFixed(1) + ' M points';
                }

                function submit() {
                  const payload = {
                    budget: Math.round(parseFloat(budget.value) * 1000000),
                    point_size: parseInt(pointSize.value, 10),
                    snap_radius: parseFloat(snapRadius.value),
                    memory_limit: parseInt(memoryLimit.value, 10)
                  };
                  sketchup.apply(JSON.stringify(payload));
                }

                panic.addEventListener('click', function() {
                  const current = parseFloat(budget.value);
                  const min = parseFloat(budget.min);
                  const max = parseFloat(budget.max);
                  const step = parseFloat(budget.step || '0.1');
                  const halved = Math.min(Math.max(current / 2, min), max);
                  const snapped = Math.round(halved / step) * step;
                  budget.value = snapped.toFixed(2);
                  updateDisplay();
                });

                budget.addEventListener('input', updateDisplay);
                apply.addEventListener('click', submit);

                updateDisplay();
              </script>
            </body>
          </html>
        HTML
        dialog.set_html(html)
        dialog.add_action_callback('apply') do |_context, payload|
          data = JSON.parse(payload)
          @settings.merge!(data.transform_keys(&:to_sym))
          @on_change&.call(@settings)
        end
        dialog
      end

      def show_import_dialog(defaults = nil, &block)
        options = normalized_import_options(@import_options, defaults)

        unless defined?(::UI) && ::UI.const_defined?(:HtmlDialog)
          @import_options = options
          block&.call(@import_options)
          return nil
        end

        unit_options = %w[meter millimeter centimeter foot inch]
        select_options = unit_options.map do |unit|
          selected = unit == options[:unit].to_s ? ' selected' : ''
          "<option value=\"#{unit}\"#{selected}>#{unit.capitalize}</option>"
        end.join

        offset = options[:offset]
        html = <<~HTML
          <html>
            <head>
              <style>
                body { font-family: sans-serif; margin: 16px; }
                label { display: block; margin-bottom: 12px; }
                fieldset { margin: 0; margin-top: 12px; padding: 12px; }
                legend { font-weight: bold; }
                .offset-inputs { display: flex; gap: 12px; }
                .actions { margin-top: 16px; display: flex; gap: 8px; }
              </style>
            </head>
            <body>
              <h2>Import Options</h2>
              <label>Units
                <select id="unit">#{select_options}</select>
              </label>
              <fieldset>
                <legend>Offset</legend>
                <div class="offset-inputs">
                  <label>X<br><input id="offset_x" type="number" step="0.01" value="#{format('%.3f', offset[:x])}"></label>
                  <label>Y<br><input id="offset_y" type="number" step="0.01" value="#{format('%.3f', offset[:y])}"></label>
                  <label>Z<br><input id="offset_z" type="number" step="0.01" value="#{format('%.3f', offset[:z])}"></label>
                </div>
              </fieldset>
              <div class="actions">
                <button id="cancel" type="button">Cancel</button>
                <button id="submit" type="button">Import</button>
              </div>
              <script>
                const submit = document.getElementById('submit');
                const cancel = document.getElementById('cancel');
                const unit = document.getElementById('unit');
                const offsetX = document.getElementById('offset_x');
                const offsetY = document.getElementById('offset_y');
                const offsetZ = document.getElementById('offset_z');

                function payload() {
                  return JSON.stringify({
                    unit: unit.value,
                    offset_x: parseFloat(offsetX.value || 0),
                    offset_y: parseFloat(offsetY.value || 0),
                    offset_z: parseFloat(offsetZ.value || 0)
                  });
                }

                submit.addEventListener('click', function() {
                  sketchup.submitImport(payload());
                });

                cancel.addEventListener('click', function() {
                  sketchup.cancelImport('');
                });
              </script>
            </body>
          </html>
        HTML

        dialog = ::UI::HtmlDialog.new(dialog_title: 'Import Point Cloud', width: 360, height: 360)
        dialog.set_html(html)
        dialog.add_action_callback('submitImport') do |_context, payload|
          data = JSON.parse(payload)
          @import_options = normalized_import_options(
            unit: data['unit'],
            offset: { x: data['offset_x'], y: data['offset_y'], z: data['offset_z'] }
          )
          dialog.close
          block&.call(@import_options)
        end
        dialog.add_action_callback('cancelImport') do |_context, _payload|
          dialog.close
        end
        dialog.show
        dialog
      end

      def normalized_import_options(*sources)
        base = {
          unit: IMPORT_DEFAULTS[:unit],
          offset: IMPORT_DEFAULTS[:offset].dup
        }

        sources.compact.each do |source|
          next unless source.respond_to?(:[])

          unit = source[:unit] || source['unit']
          base[:unit] = unit.to_sym if unit

          offset_source = source[:offset] || source['offset']
          next unless offset_source

          %i[x y z].each do |axis|
            value = offset_source[axis] || offset_source[axis.to_s]
            base[:offset][axis] = value.to_f if value
          end
        end

        base
      end
    end
  end
end
