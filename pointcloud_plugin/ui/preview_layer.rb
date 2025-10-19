module PointCloud
  module UI
    module PreviewLayer
      module_function

      def draw(view, tool)
        return unless tool.respond_to?(:reservoir_samples)

        samples = tool.reservoir_samples
        return if samples.nil? || samples.empty?

        pts = samples.first(50_000).map { |p| Geom::Point3d.new(p.x, p.y, p.z) }
        view.draw_points(pts, 2, 1, Sketchup::Color.new(0, 0, 0))
      end
    end
  end
end
