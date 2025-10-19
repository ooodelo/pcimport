# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

begin
  require 'sketchup.rb'
  require 'extensions.rb'
rescue LoadError
  # Allow the code to be loaded outside of SketchUp for testing.
end

module PointCloudPlugin
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

PointCloudPlugin.log('Loading runtime (pointcloud_plugin/main.rb)') if defined?(PointCloudPlugin)

require_relative 'core/units'
require_relative 'core/chunk'
require_relative 'core/chunk_store'
require_relative 'core/readers/reader_base'
require_relative 'core/readers/ply_reader'
require_relative 'core/readers/xyz_reader'
require_relative 'core/spatial/morton'
require_relative 'core/spatial/index_builder'
require_relative 'core/spatial/frustum'
require_relative 'core/spatial/knn'
require_relative 'core/lod/reservoir'
require_relative 'core/lod/budget_distributor'
require_relative 'core/lod/prefetcher'
require_relative 'core/lod/pipeline'
require_relative 'bridge/main_thread_queue'
require_relative 'bridge/import_job'
require_relative 'bridge/point_cloud_manager'
require_relative 'ui/tool_pointcloud'
require_relative 'ui/hud'
require_relative 'ui/dialog_settings'
require_relative 'ui/import_overlay'
require_relative 'ui/entry_points'

module PointCloudPlugin
  EXTENSION_ID ||= 'com.example.pointcloud'
  EXTENSION_NAME ||= 'Point Cloud Importer'
  EXTENSION_VERSION ||= '0.1.0'

  module_function

  def manager
    @manager ||= Bridge::PointCloudManager.new
  end

  def tool
    @tool ||= UI::ToolPointCloud.new(manager)
  end

  MENU_PARENT_LABELS = ['Extensions', 'Plugins'].freeze
  MENU_TITLE = 'Point Cloud Importer'
  IMPORT_COMMAND_TITLE = 'Import Point Cloud...'
  SETTINGS_COMMAND_TITLE = 'Point Cloud Settings'

  def setup_menu
    unless defined?(::UI) && ::UI.respond_to?(:menu)
      log('UI.menu is unavailable; skipping menu setup')
      return
    end

    return if @menu_created

    MENU_PARENT_LABELS.each do |parent_label|
      parent_menu = safe_menu(parent_label)
      next unless parent_menu

      submenu = parent_menu.add_submenu(MENU_TITLE)
      submenu.add_item(IMPORT_COMMAND_TITLE) { start_import }
      submenu.add_item(SETTINGS_COMMAND_TITLE) { tool.settings_dialog.show }
    end

    @menu_created = true
    log('Menu items registered')
  rescue StandardError => e
    @menu_created = false
    log("Failed to set up menu: #{e.class}: #{e.message}")
    log(e.backtrace.join("\n")) if e.backtrace
    raise
  end

  def setup_toolbar
    unless defined?(::UI) && ::UI.const_defined?(:Toolbar)
      log('UI::Toolbar is unavailable; skipping toolbar setup')
      return
    end

    return if @toolbar&.valid?

    command = ::UI::Command.new(IMPORT_COMMAND_TITLE) do
      start_import
    end
    command.tooltip = 'Import a point cloud file'
    command.status_bar_text = 'Open a point cloud file for viewing'

    toolbar = ::UI::Toolbar.new(MENU_TITLE)
    toolbar.add_item(command)
    toolbar.show
    @toolbar = toolbar
    @import_command = command
    log('Toolbar registered')
  rescue StandardError => e
    @toolbar = nil
    log("Failed to set up toolbar: #{e.class}: #{e.message}")
    log(e.backtrace.join("\n")) if e.backtrace
    raise
  end

  def safe_menu(label)
    ::UI.menu(label)
  rescue StandardError => e
    log("Failed to access '#{label}' menu: #{e.class}: #{e.message}")
    nil
  end

  def start_import
    path = if defined?(::UI)
             ::UI.openpanel('Import Point Cloud', nil, 'Point Clouds|*.ply;*.xyz||')
           end
    return unless path && !path.to_s.empty?

    if tool.respond_to?(:import_in_progress?) && tool.import_in_progress?
      tool.hud.update(load_status: 'Импорт уже выполняется')
      return
    end

    import_defaults = tool.settings_dialog.import_options

    if defined?(::UI) && ::UI.const_defined?(:HtmlDialog)
      tool.settings_dialog.show_import_dialog(import_defaults) do |options|
        begin_import(path, options)
      end
    else
      begin_import(path, import_defaults)
    end
  end

  def begin_import(path, options)
    options ||= {}
    unit = (options[:unit] || :meter).to_sym
    offset = options[:offset] || {}
    reader = build_reader(path, unit: unit, offset: offset)
    cache_root = File.join(Dir.tmpdir, 'pointcloud_cache')
    FileUtils.mkdir_p(cache_root)
    cache_path = File.join(cache_root, File.basename(path, '.*'))
    runtime_settings = tool.settings_dialog.settings || {}
    memory_limit = runtime_settings[:memory_limit]
    chunk_store = Core::ChunkStore.new(cache_path: cache_path, memory_limit_mb: memory_limit)
    pipeline = Core::Lod::Pipeline.new(chunk_store: chunk_store)
    job = Bridge::ImportJob.new(path: path, reader: reader, pipeline: pipeline, queue: manager.queue)

    activate_tool
    tool.hud.update(load_status: 'Загрузка: инициализация')

    chunk_store.on_memory_pressure do |freed_bytes, limit_bytes|
      manager.queue.push do
        if tool.respond_to?(:handle_memory_pressure)
          tool.handle_memory_pressure(limit_bytes, freed_bytes)
        end
      end
    end

    cloud_name = File.basename(path)
    id = manager.register_cloud(name: cloud_name, pipeline: pipeline, job: job)
    job.cloud_id = id if job.respond_to?(:cloud_id=)

    if tool.respond_to?(:begin_import_session)
      tool.begin_import_session(job: job, cloud_id: id, cloud_name: cloud_name)
    end
    tool.hud.update("cloud_#{id}" => cloud_name)

    begin
      apply_runtime_settings(runtime_settings)
    rescue StandardError => e
      log("Failed to apply runtime settings: #{e.class}: #{e.message}")
    end

    job.start do |completed_job|
      if tool.respond_to?(:handle_import_completion)
        tool.handle_import_completion(completed_job)
      else
        tool.hud.update(load_status: 'Import complete')
      end
    end
  end

  def build_reader(path, unit: :meter, offset: nil)
    ext = File.extname(path).downcase
    case ext
    when '.ply'
      Core::Readers::PlyReader.new(path, unit: unit, offset: offset)
    when '.xyz'
      Core::Readers::XyzReader.new(path, unit: unit, offset: offset)
    else
      raise ArgumentError, "Unsupported file type: #{ext}"
    end
  end

  def activate_tool
    return unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

    tools = Sketchup.active_model.tools
    tools.push_tool(tool) unless tools.active_tool?(tool)
  rescue NoMethodError
    tools.push_tool(tool)
  end

  def apply_runtime_settings(settings)
    return unless settings.is_a?(Hash)

    symbolized = settings.each_with_object({}) do |(key, value), memo|
      memo[key.to_sym] = value
    end

    memory_limit = symbolized[:memory_limit]
    if memory_limit
      manager.each_cloud do |cloud|
        store = cloud&.pipeline&.chunk_store
        next unless store && store.respond_to?(:memory_limit_mb=)

        begin
          store.memory_limit_mb = memory_limit
        rescue StandardError => e
          log("Failed to update memory limit for cloud #{cloud.id}: #{e.message}")
        end
      end
    end

    prefetch_limit = symbolized[:prefetch_limit]
    angle_weight = symbolized[:prefetch_angle_weight]
    distance_weight = symbolized[:prefetch_distance_weight]
    forward_threshold = symbolized[:prefetch_forward_threshold]
    preview_threshold = symbolized[:preview_threshold]

    manager.each_cloud do |cloud|
      if cloud.prefetcher&.respond_to?(:configure)
        begin
          cloud.prefetcher.configure(
            max_prefetch: prefetch_limit,
            angle_weight: angle_weight,
            distance_weight: distance_weight,
            forward_threshold: forward_threshold
          )
        rescue StandardError => e
          log("Failed to update prefetcher for cloud #{cloud.id}: #{e.message}")
        end
      end

      if preview_threshold && cloud.job&.respond_to?(:preview_activation_ratio=)
        begin
          cloud.job.preview_activation_ratio = preview_threshold
        rescue StandardError => e
          log("Failed to update preview threshold for cloud #{cloud.id}: #{e.message}")
        end
      end
    end

    invalidate_active_view
  end

  def invalidate_active_view
    return unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

    model = Sketchup.active_model
    view = model&.active_view
    return unless view && view.respond_to?(:invalidate)

    view.invalidate
  rescue StandardError => e
    log("Failed to invalidate view: #{e.message}")
  end

  def focus_camera_on_chunk(chunk)
    return unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

    bounds = chunk&.metadata&.fetch(:bounds, nil)
    return unless bounds

    mins = bounds[:min]
    maxs = bounds[:max]
    return unless mins && maxs

    view = Sketchup.active_model&.active_view
    return unless view && view.respond_to?(:zoom) && defined?(Geom)

    bounding_box = Geom::BoundingBox.new
    bounding_box.add(Geom::Point3d.new(*mins))
    bounding_box.add(Geom::Point3d.new(*maxs))
    view.zoom(bounding_box)
    view.invalidate if view.respond_to?(:invalidate)
    true
  rescue NoMethodError
    false
  end

end

PointCloudPlugin::UI::EntryPoints.setup if defined?(PointCloudPlugin::UI::EntryPoints)
PointCloudPlugin.log('Runtime load complete') if defined?(PointCloudPlugin)
