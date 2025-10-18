# frozen_string_literal: true

begin
  require 'sketchup.rb'
  require 'extensions.rb'
rescue LoadError
  # Allow the code to be loaded outside of SketchUp for testing.
end

module PointCloudPlugin
  EXTENSION_ID ||= 'com.example.pointcloud'
  EXTENSION_NAME ||= 'Point Cloud Importer'
  EXTENSION_VERSION ||= '0.1.0'
end

if defined?(SketchupExtension)
  extension = SketchupExtension.new(PointCloudPlugin::EXTENSION_NAME, 'pointcloud_plugin/main')
  extension.description = 'Streams point cloud data with progressive LOD rendering.'
  extension.version = PointCloudPlugin::EXTENSION_VERSION
  extension.creator = 'PointCloudPlugin'
  extension.id = PointCloudPlugin::EXTENSION_ID if extension.respond_to?(:id=)
  Sketchup.register_extension(extension, true)
else
  require_relative 'pointcloud_plugin/main'
end
