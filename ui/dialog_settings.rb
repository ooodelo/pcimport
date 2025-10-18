# frozen_string_literal: true

require 'json'

module PointCloudPlugin
  module UI
    # Settings dialog for adjusting runtime parameters.
    class DialogSettings
      DEFAULTS = {
        budget: 8,
        point_size: 2,
        snap_radius: 5.0,
        memory_limit: 512
      }.freeze

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
        dialog = ::UI::HtmlDialog.new(dialog_title: 'Point Cloud Settings', width: 360, height: 400)
        html = <<~HTML
          <html>
            <body>
              <label>Frame budget: <input id="budget" type="number" min="1" value="#{settings[:budget]}"></label><br>
              <label>Point size: <input id="point_size" type="number" min="1" value="#{settings[:point_size]}"></label><br>
              <label>Snap radius: <input id="snap_radius" type="number" step="0.1" value="#{settings[:snap_radius]}"></label><br>
              <label>Memory limit (MB): <input id="memory_limit" type="number" min="128" value="#{settings[:memory_limit]}"></label><br>
              <button onclick="sketchup.apply(JSON.stringify({ budget: parseInt(budget.value), point_size: parseInt(point_size.value), snap_radius: parseFloat(snap_radius.value), memory_limit: parseInt(memory_limit.value) }))">Apply</button>
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
    end
  end
end
