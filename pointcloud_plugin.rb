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

  unless respond_to?(:log)
    def self.log(message)
      Kernel.puts("[PointCloudPlugin] #{message}")
    rescue StandardError
      nil
    end

    def log(message)
      PointCloudPlugin.log(message)
    end

    module_function :log
  end
end

PointCloudPlugin.log('Loader executing')

if defined?(SketchupExtension)
  extension = SketchupExtension.new(PointCloudPlugin::EXTENSION_NAME, 'pointcloud_plugin/main')
  extension.description = 'Streams point cloud data with progressive LOD rendering.'
  extension.version = PointCloudPlugin::EXTENSION_VERSION
  extension.creator = 'PointCloudPlugin'
  extension.id = PointCloudPlugin::EXTENSION_ID if extension.respond_to?(:id=)
  begin
    Sketchup.register_extension(extension, true)
    PointCloudPlugin.log('Registered extension with SketchUp')
  rescue StandardError => e
    PointCloudPlugin.log("Failed to register extension: #{e.class}: #{e.message}")
    PointCloudPlugin.log(e.backtrace.join("\n")) if e.backtrace
    raise
  end
else
  PointCloudPlugin.log('SketchupExtension not available; requiring runtime directly')
  begin
    require_relative 'pointcloud_plugin/main'
    PointCloudPlugin.log('Runtime loaded outside SketchUp')
  rescue LoadError => e
    PointCloudPlugin.log("Failed to load runtime: #{e.class}: #{e.message}")
    PointCloudPlugin.log(e.backtrace.join("\n")) if e.backtrace
    raise
  end
end
