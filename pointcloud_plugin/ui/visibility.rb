module PointCloud
  module UI
    module Visibility
      module_function

      def chunk_visible?(view, bbox, margin = 20)
        w = view.vpwidth
        h = view.vpheight

        corners_of(bbox).any? do |point|
          screen_point = view.screen_coords(point)
          screen_point.z > 0 &&
            screen_point.x.between?(-margin, w + margin) &&
            screen_point.y.between?(-margin, h + margin)
        end
      end

      def corners_of(bbox)
        min = bbox.min
        max = bbox.max

        xs = [min.x, max.x]
        ys = [min.y, max.y]
        zs = [min.z, max.z]

        xs.flat_map do |x|
          ys.flat_map do |y|
            zs.map { |z| Geom::Point3d.new(x, y, z) }
          end
        end
      end
    end
  end
end
