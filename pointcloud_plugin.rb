# frozen_string_literal: true

begin
  require 'sketchup'
  require 'extensions'
rescue LoadError
  # Allow the code to be loaded outside of SketchUp for testing.
end

if defined?(SketchupExtension)
  extension = SketchupExtension.new('Point Cloud Importer', 'pointcloud_plugin/main')
  extension.description = 'Streams point cloud data with progressive LOD rendering.'
  extension.version = '0.1.0'
  extension.creator = 'PointCloudPlugin'
  Sketchup.register_extension(extension, true)
else
  require_relative 'pointcloud_plugin/main'
end
