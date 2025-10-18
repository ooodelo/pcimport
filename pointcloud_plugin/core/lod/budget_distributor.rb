# frozen_string_literal: true

module PointCloudPlugin
  module Core
    module Lod
      # Distributes the point budget across visible octree nodes based on importance.
      class BudgetDistributor
        MIN_QUOTA = 50

        def distribute(visible_nodes, total_budget, camera_position)
          total_budget = total_budget.to_i
          return {} if visible_nodes.empty? || total_budget <= 0

          importances = compute_importances(visible_nodes, camera_position)
          total_importance = importances.values.sum

          allocations = {}

          visible_nodes.each do |node|
            importance = importances[node]
            quota = if total_importance.zero?
                      total_budget / visible_nodes.length
                    else
                      ((total_budget * importance) / total_importance).floor
                    end
            allocations[node] = quota
          end

          ensure_minimum_allocations!(allocations, total_budget)
          balance_allocations!(allocations, total_budget, importances)
          allocations
        end

        private

        def compute_importances(nodes, camera_position)
          camera_position = (camera_position || [0.0, 0.0, 0.0]).map(&:to_f)

          nodes.each_with_object({}) do |node, importance|
            center = node.center
            distance = Math.sqrt(center.zip(camera_position).sum { |component, camera| (component - camera)**2 })
            distance = [distance, 1e-3].max
            size_estimate = node.diagonal_length
            score = size_estimate / (distance**2)
            importance[node] = score.positive? ? score : 0.0
          end
        end

        def ensure_minimum_allocations!(allocations, total_budget)
          return if total_budget <= 0

          minimum = [MIN_QUOTA, total_budget].min
          allocations.keys.each do |node|
            allocations[node] = [allocations[node], minimum].max
          end
        end

        def balance_allocations!(allocations, total_budget, importances)
          current_total = allocations.values.sum

          if current_total > total_budget
            reduce_allocations!(allocations, current_total - total_budget)
            current_total = allocations.values.sum
            trim_evenly!(allocations, current_total - total_budget) if current_total > total_budget
          elsif current_total < total_budget
            grow_allocations!(allocations, total_budget - current_total, importances)
          end
        end

        def reduce_allocations!(allocations, excess)
          return if excess <= 0

          adjustable = allocations.select { |_, quota| quota > MIN_QUOTA }
          return if adjustable.empty?

          sorted = adjustable.sort_by { |_, quota| quota }.reverse

          sorted.each do |node, quota|
            break if excess <= 0

            reducible = quota - MIN_QUOTA
            next if reducible <= 0

            reduction = [reducible, excess].min
            allocations[node] -= reduction
            excess -= reduction
          end
        end

        def grow_allocations!(allocations, deficit, importances)
          return if deficit <= 0

          sorted = importances.sort_by { |_, importance| importance }.reverse

          while deficit.positive? && sorted.any?
            sorted.each do |node, _|
              break if deficit <= 0

              allocations[node] += 1
              deficit -= 1
            end
          end
        end

        def trim_evenly!(allocations, excess)
          return if excess <= 0

          keys = allocations.keys
          return if keys.empty?

          index = 0
          while excess.positive?
            node = keys[index % keys.length]
            if allocations[node] > 0
              allocations[node] -= 1
              excess -= 1
            end
            index += 1
            break if keys.all? { |key| allocations[key].zero? }
          end
        end
      end
    end
  end
end
