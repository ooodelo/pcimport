# frozen_string_literal: true

module PointCloudPlugin
  module UI
    # Builds construction point previews for sampled point clouds.
    class CPointsBuilder
      ATTRIBUTE_DICTIONARY = 'pcimport'.freeze
      ATTRIBUTE_KEY_TYPE = 'type'.freeze
      ATTRIBUTE_VALUE_PREVIEW = 'preview'.freeze
      ATTRIBUTE_KEY_CLOUD_ID = 'cloud_id'.freeze

      TAG_PARENT = 'Cloud-Preview'.freeze
      TAG_ALL = 'Cloud-Preview:All'.freeze
      TAG_ANCHORS = 'Cloud-Preview:Anchors'.freeze

      MAX_POINTS_PER_BATCH = 100_000

      def initialize(model = default_model)
        @model = model
      end

      def build(cloud_id:, samples:, logger: nil)
        return unless valid_environment?

        logging_active = false
        if logger&.respond_to?(:start_stage)
          logger.start_stage(:preview_build)
          logging_active = true
        end

        model.start_operation(operation_name(cloud_id), true)
        begin
          remove_existing_preview_group(cloud_id)

          partitioned = partition_samples(Array(samples))
          total_points = partitioned[:all].length + partitioned[:anchors].length
          logger.record_points(:preview_build, total_points) if logger&.respond_to?(:record_points)
          if logger&.respond_to?(:set_metadata)
            logger.set_metadata('preview_total_points', total_points)
            logger.set_metadata('preview_anchor_points', partitioned[:anchors].length)
          end
          if partitioned[:all].empty? && partitioned[:anchors].empty?
            commit_operation
            return nil
          end

          group = create_preview_group(cloud_id)
          build_points(group, partitioned)
          commit_operation
          group
        rescue StandardError
          abort_operation
          raise
        ensure
          logger.finish_stage(:preview_build) if logging_active && logger&.respond_to?(:finish_stage)
        end
      end

      private

      attr_reader :model

      def default_model
        return unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

        Sketchup.active_model
      rescue StandardError
        nil
      end

      def valid_environment?
        model && model.respond_to?(:start_operation) && model.respond_to?(:entities)
      end

      def operation_name(cloud_id)
        suffix = cloud_id ? " ##{cloud_id}" : ''
        "Build Cloud Preview#{suffix}"
      end

      def remove_existing_preview_group(cloud_id)
        return unless model.respond_to?(:entities)

        cloud_token = cloud_id.to_s
        matching_groups = model.entities.grep(group_class).select do |entity|
          preview_group?(entity) && entity.get_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_KEY_CLOUD_ID).to_s == cloud_token
        end
        matching_groups.each do |group|
          group.erase! if group.respond_to?(:erase!) && (!group.respond_to?(:deleted?) || !group.deleted?)
        end
      rescue StandardError
        nil
      end

      def group_class
        defined?(Sketchup::Group) ? Sketchup::Group : Object
      end

      def preview_group?(entity)
        return false unless entity.respond_to?(:get_attribute)

        type = entity.get_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_KEY_TYPE)
        type.to_s == ATTRIBUTE_VALUE_PREVIEW
      rescue StandardError
        false
      end

      def partition_samples(samples)
        buckets = { all: [], anchors: [] }

        samples.each do |sample|
          coords = extract_coordinates(sample)
          next unless coords

          if anchor_sample?(sample)
            buckets[:anchors] << coords
          else
            buckets[:all] << coords
          end
        end

        buckets
      end

      def extract_coordinates(sample)
        position = nil

        if sample.respond_to?(:position)
          position = sample.position
        elsif sample.respond_to?(:[])
          position = sample[:position] if sample.respond_to?(:key?) && sample.key?(:position)
          position ||= sample['position'] if sample.respond_to?(:key?) && sample.key?('position')
          position ||= safe_lookup(sample, :position)
        elsif sample.respond_to?(:to_a)
          position = sample.to_a
        end

        coords = Array(position).first(3)
        return nil if coords.length < 3

        coords = coords.map { |value| numeric_value(value) }
        coords.length >= 3 ? coords[0, 3] : nil
      rescue StandardError
        nil
      end

      def anchor_sample?(sample)
        if sample.respond_to?(:anchor)
          !!sample.anchor
        elsif sample.respond_to?(:[])
          value = safe_lookup(sample, :anchor)
          value = safe_lookup(sample, 'anchor') if value.nil?
          !!value
        else
          false
        end
      rescue StandardError
        false
      end

      def safe_lookup(sample, key)
        sample[key]
      rescue StandardError, NameError
        nil
      end

      def numeric_value(value)
        return 0.0 if value.nil?
        return value.to_f if value.respond_to?(:to_f)

        Float(value)
      rescue StandardError
        0.0
      end

      def create_preview_group(cloud_id)
        entities = model.entities
        group = entities.add_group
        group.set_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_KEY_TYPE, ATTRIBUTE_VALUE_PREVIEW)
        group.set_attribute(ATTRIBUTE_DICTIONARY, ATTRIBUTE_KEY_CLOUD_ID, cloud_id.to_s)
        group.layer = ensure_tag(TAG_PARENT) if group.respond_to?(:layer=)
        group.name = preview_group_name(cloud_id) if group.respond_to?(:name=)
        group
      rescue StandardError
        nil
      end

      def preview_group_name(cloud_id)
        cloud_id ? "Cloud Preview ##{cloud_id}" : 'Cloud Preview'
      end

      def build_points(group, partitioned)
        return unless group && group.respond_to?(:entities)

        entities = group.entities

        build_bucket(entities, partitioned[:all], TAG_ALL, 'All Points')
        build_bucket(entities, partitioned[:anchors], TAG_ANCHORS, 'Anchor Points')
      end

      def build_bucket(parent_entities, points, tag_name, label)
        return if points.nil? || points.empty?

        subgroup = parent_entities.add_group
        subgroup.layer = ensure_tag(tag_name) if subgroup.respond_to?(:layer=)
        subgroup.name = label if subgroup.respond_to?(:name=)

        add_points_in_batches(subgroup.entities, points)
      end

      def add_points_in_batches(entities, points)
        points.each_slice(MAX_POINTS_PER_BATCH) do |batch|
          started = start_sub_operation("Preview batch (#{batch.length})")
          begin
            batch.each do |coords|
              point = to_point3d(coords)
              entities.add_cpoint(point) if point && entities.respond_to?(:add_cpoint)
            end
            commit_sub_operation(started)
          rescue StandardError
            abort_sub_operation(started)
            raise
          end
        end
      end

      def start_sub_operation(name)
        return false unless model.respond_to?(:start_operation)

        model.start_operation(name, true)
        true
      rescue StandardError
        false
      end

      def commit_sub_operation(started)
        return unless started
        return unless model.respond_to?(:commit_operation)

        model.commit_operation
      rescue StandardError
        nil
      end

      def abort_sub_operation(started)
        return unless started
        return unless model.respond_to?(:abort_operation)

        model.abort_operation
      rescue StandardError
        nil
      end

      def ensure_tag(name)
        return unless model.respond_to?(:layers)

        layers = model.layers
        tag = begin
          layers[name]
        rescue StandardError
          nil
        end
        tag ||= layers.add(name) if layers.respond_to?(:add)
        tag
      rescue StandardError
        nil
      end

      def to_point3d(coords)
        return unless coords && coords.length >= 3

        if defined?(Geom::Point3d)
          Geom::Point3d.new(coords[0], coords[1], coords[2])
        else
          coords[0, 3]
        end
      rescue StandardError
        nil
      end

      def commit_operation
        return unless model.respond_to?(:commit_operation)

        model.commit_operation
      rescue StandardError
        nil
      end

      def abort_operation
        return unless model.respond_to?(:abort_operation)

        model.abort_operation
      rescue StandardError
        nil
      end
    end
  end
end
