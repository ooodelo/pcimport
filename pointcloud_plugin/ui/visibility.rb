module PointCloud
  module UI
    module Visibility
      module_function

      def chunk_visible?(view, bbox, margin = 20)
        viewport = viewport_rect(view, margin)

        corners_of(bbox).any? do |point|
          screen_point = view.screen_coords(point)
          visible_depth?(screen_point) &&
            within_viewport?(screen_point, viewport)
        end
      end

      def viewport_rect(view, margin)
        [
          -margin,
          view.vpwidth + margin,
          -margin,
          view.vpheight + margin
        ]
      end

      def visible_depth?(screen_point)
        screen_point.z.positive?
      end

      def within_viewport?(screen_point, viewport)
        min_x, max_x, min_y, max_y = viewport
        screen_point.x.between?(min_x, max_x) &&
          screen_point.y.between?(min_y, max_y)
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
