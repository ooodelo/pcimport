# frozen_string_literal: true

require 'json'

require_relative 'import_overlay'

module PointCloudPlugin
  module UI
    # Progress dialog backed by HtmlDialog with a cache manager panel.
    # Falls back to ImportOverlay for environments without HtmlDialog support.
    class DialogProgress
      STEP_SEQUENCE = %i[hash parsing sampling cache build].freeze

      STEP_LABELS = {
        hash: 'Проверка источника',
        parsing: 'Разбор данных',
        sampling: 'Выборка точек',
        cache: 'Запись кэша',
        build: 'Построение'
      }.freeze

      STATE_TITLES = {
        idle: 'Загрузка облака…',
        initializing: 'Загрузка облака…',
        hash_check: 'Загрузка облака…',
        sampling: 'Загрузка облака…',
        cache_write: 'Загрузка облака…',
        build: 'Загрузка облака…',
        navigating: 'Работа: навигация',
        cancelled: 'Загрузка отменена'
      }.freeze

      FALLBACK_CANCEL_DISABLED_STATES = %i[navigating cancelled idle].freeze

      attr_reader :state

      def initialize(manager:, cache_loader: nil, settings: nil)
        @manager = manager
        @cache_loader = cache_loader || -> { {} }
        @settings = settings || {}
        @state = :idle
        @stage_progress = default_stage_progress
        @visibility_state = build_visibility_state(settings)
        @preview_available = false
        @anchors_available = false
        @cloud_records = []
        @pending_scripts = []
        @manager_visible = false
        @html_ready = false
        @visible = false
        @on_cancel = nil
        @on_visibility_change = nil
        @on_manager_visibility_change = nil
        @cache_hit = false
        @latest_error_info = nil
        @latest_timings = {
          total: 0.0,
          total_points: 0,
          cache_hit: false,
          status: nil,
          stages: default_stage_timings,
          metadata: {}
        }

        if html_dialog_available?
          refresh_cached_clouds
        else
          @fallback_overlay = ImportOverlay.new
        end
      end

      def show!
        if using_fallback?
          @fallback_overlay.show!
          return
        end

        ensure_dialog
        refresh_cached_clouds
        push_full_state
        @dialog.show
        @visible = true
      end

      def hide!
        if using_fallback?
          @fallback_overlay.hide!
          return
        end

        @visible = false
        close_dialog
      end

      def visible?
        if using_fallback?
          @fallback_overlay.visible?
        else
          @visible
        end
      end

      def draw(view)
        return unless using_fallback?

        @fallback_overlay.draw(view)
      end

      def cancel_hit?(x, y)
        return false unless using_fallback?

        @fallback_overlay.cancel_hit?(x, y)
      end

      def cancel_enabled?
        if using_fallback?
          @fallback_overlay.cancel_enabled?
        else
          !FALLBACK_CANCEL_DISABLED_STATES.include?(state)
        end
      end

      def update_state(new_state)
        new_state = (new_state || :idle).to_sym
        @state = new_state

        if using_fallback?
          @fallback_overlay.update_state(new_state)
          return
        end

        push_progress_update
        auto_close_if_complete
      end

      def update_stage_progress(progress_hash)
        progress_hash = safe_hash(progress_hash)

        if using_fallback?
          @fallback_overlay.update_stage_progress(progress_hash)
          return
        end

        @stage_progress.merge!(progress_hash) do |_key, _old, new_value|
          new_value.to_f.clamp(0.0, 1.0)
        end
        push_progress_update
      end

      def update_from_payload(payload)
        data = safe_hash(payload)

        stage_value = data[:stage] || data['stage']
        update_state(stage_value) if stage_value

        progress = data[:stage_progress] || data['stage_progress']
        update_stage_progress(progress) if progress

        @cache_hit = !!(data[:cache_hit] || data['cache_hit']) if data.key?(:cache_hit) || data.key?('cache_hit')

        sample_ready = extract_optional_boolean(data, :sample_ready)
        anchors_ready = extract_optional_boolean(data, :anchors_ready)

        @preview_available = sample_ready unless sample_ready.nil?
        @anchors_available = anchors_ready unless anchors_ready.nil?

        @latest_timings = normalize_timings(data[:timings] || data['timings'])
        @latest_error_info = normalize_error(data[:error] || data['error'])

        update_preview_state(
          available: @preview_available,
          anchors_available: @anchors_available
        ) unless using_fallback?

        push_progress_update unless using_fallback?
      end

      def update_settings(settings)
        return if using_fallback?

        @settings = settings || {}
        push_settings
      end

      def update_preview_state(available:, show_points: nil, show_anchors: nil, anchors_available: nil)
        return if using_fallback?

        @preview_available = !!available
        @anchors_available = !!anchors_available unless anchors_available.nil?

        points = show_points.nil? ? !!@visibility_state[:points] : !!show_points
        anchors = show_anchors.nil? ? !!@visibility_state[:anchors] : !!show_anchors

        points &&= @preview_available
        anchors &&= @preview_available && @anchors_available && points

        @visibility_state = {
          points: points,
          anchors: anchors
        }
        push_preview_state
      end

      def refresh_cached_clouds
        return if using_fallback?

        @cloud_records = normalize_clouds(load_cached_clouds)
        push_clouds
      end

      def set_manager_visibility(visible)
        return if using_fallback?

        @manager_visible = !!visible
        dispatch_script("window.dialogProgress && window.dialogProgress.setManagerVisible(#{@manager_visible ? 'true' : 'false'})")
      end

      def using_fallback?
        !html_dialog_available?
      end

      def using_html_dialog?
        html_dialog_available?
      end

      def on_cancel(&block)
        @on_cancel = block
      end

      def on_visibility_change(&block)
        @on_visibility_change = block
      end

      def on_manager_visibility_change(&block)
        @on_manager_visibility_change = block
      end

      private

      attr_reader :dialog
      def html_dialog_available?
        defined?(::UI) && ::UI.const_defined?(:HtmlDialog)
      end

      def ensure_dialog
        return if @dialog

        @dialog = build_dialog
      end

      def close_dialog
        return unless @dialog

        begin
          @dialog.close
        rescue StandardError
          # swallow close errors
        end
        @dialog = nil
        @html_ready = false
        @pending_scripts.clear
      end

      def build_dialog
        dialog = ::UI::HtmlDialog.new(dialog_title: 'Point Cloud Import', width: 420, height: 520)
        dialog.set_html(html_markup)
        dialog.add_action_callback('ready') do |_context, _payload|
          @html_ready = true
          push_full_state
          flush_pending_scripts
        end
        dialog.add_action_callback('cancel') do |_context, _payload|
          @on_cancel&.call
        end
        dialog.add_action_callback('toggleVisibility') do |_context, payload|
          handle_visibility_request(payload)
        end
        dialog.add_action_callback('toggleManager') do |_context, payload|
          handle_manager_toggle(payload)
        end
        dialog
      end

      def html_markup
        steps_markup = STEP_SEQUENCE.map do |key|
          label = STEP_LABELS[key]
          "<li data-key=\"#{key}\"><span class=\"label\">#{label}</span><span class=\"status\"></span></li>"
        end.join

        <<~HTML
          <html>
            <head>
              <meta charset="utf-8">
              <style>
                body { font-family: sans-serif; margin: 0; padding: 16px; background: #f8f9fb; color: #1d2a3a; }
                h1 { margin: 0 0 16px; font-size: 20px; }
                h2 { margin-top: 24px; font-size: 16px; }
                .section { background: #fff; border-radius: 12px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
                .section + .section { margin-top: 16px; }
                .progress-steps { list-style: none; padding: 0; margin: 0; }
                .progress-steps li { display: flex; justify-content: space-between; align-items: center; padding: 8px 0; border-bottom: 1px solid #e4e7ee; font-size: 13px; }
                .progress-steps li:last-child { border-bottom: none; }
                .progress-steps .status { font-weight: 600; color: #4a6578; }
                .progress-steps li.complete .status { color: #1b8a3a; }
                .progress-steps li.active .status { color: #2f74ff; }
                .progress-steps li.pending .status { color: #a0a8b8; }
                .progress-controls { display: flex; justify-content: flex-end; margin-top: 16px; }
                button { font-family: inherit; font-size: 13px; border-radius: 8px; border: none; padding: 8px 14px; cursor: pointer; }
                #cancel_button { background: #d64541; color: #fff; }
                #cancel_button:disabled { background: #e0e4eb; color: #7a8596; cursor: default; }
                #manager_button { background: #2f74ff; color: #fff; margin-left: auto; }
                #manager_button.toggle { background: #8894a6; }
                .manager-panel.hidden { display: none; }
                .manager-panel { display: flex; flex-direction: column; gap: 16px; }
                .cloud-list { display: flex; flex-direction: column; gap: 8px; max-height: 160px; overflow: auto; }
                .cloud { padding: 10px 12px; border: 1px solid #d5dbe7; border-radius: 10px; background: #f9fbff; }
                .cloud.active { border-color: #2f74ff; background: rgba(47, 116, 255, 0.08); }
                .cloud .name { font-weight: 600; margin-bottom: 4px; font-size: 13px; }
                .cloud .meta { font-size: 11px; color: #657085; line-height: 1.4; }
                .empty { font-size: 12px; color: #768398; }
                .toggle-group { display: flex; flex-direction: column; gap: 6px; }
                .toggle-group label { display: flex; align-items: center; gap: 8px; font-size: 13px; }
                .toggle-group input[type="checkbox"] { transform: scale(1.1); }
                .toggle-group .hint { font-size: 11px; color: #7a8596; margin-left: 24px; }
                .toggle-group label.disabled { opacity: 0.5; cursor: default; }
                .status-panel { margin-top: 12px; padding: 12px; border: 1px solid #d5dbe7; border-radius: 10px; background: #f4f6fb; display: flex; flex-direction: column; gap: 6px; }
                .status-row { display: flex; justify-content: space-between; font-size: 12px; }
                .status-row .label { color: #657085; font-weight: 600; }
                .status-row .value { color: #2f3b4c; }
                .status-row .value.cache-hit { color: #2f8f4b; font-weight: 600; }
                .status-row .value.cache-miss { color: #d64541; font-weight: 600; }
                .status-row .value.pending { color: #7a8596; }
                .status-row.error .value { color: #d64541; }
                .status-row.hidden { display: none; }
                dl { margin: 0; }
                dt { font-weight: 600; font-size: 12px; margin-top: 6px; }
                dd { margin: 0; font-size: 12px; color: #44525f; }
              </style>
            </head>
            <body>
              <div class="section" id="progress_section">
                <h1 id="progress_title">Загрузка облака…</h1>
                <ul class="progress-steps" id="progress_steps">#{steps_markup}</ul>
                <div class="status-panel" id="status_panel">
                  <div class="status-row"><span class="label">Стадия</span><span class="value" id="status_stage">—</span></div>
                  <div class="status-row"><span class="label">Источник</span><span class="value" id="status_cache">Новый импорт</span></div>
                  <div class="status-row"><span class="label">Предпросмотр</span><span class="value" id="status_sample">Готовится…</span></div>
                  <div class="status-row"><span class="label">Опорные точки</span><span class="value" id="status_anchors">Нет данных</span></div>
                  <div class="status-row"><span class="label">Время</span><span class="value" id="status_timings">—</span></div>
                  <div class="status-row error hidden" id="status_error_row"><span class="label">Ошибка</span><span class="value" id="status_error">—</span></div>
                </div>
                <div class="progress-controls">
                  <button id="manager_button" type="button">Менеджер кэша</button>
                  <button id="cancel_button" type="button">Отмена</button>
                </div>
              </div>
              <div class="section manager-panel hidden" id="manager_section">
                <div class="toggle-group">
                  <label><input id="toggle_points" type="checkbox"> Показать точки</label>
                  <label><input id="toggle_anchors" type="checkbox"> Показать опорные точки</label>
                  <div class="hint" id="preview_hint">Точки появятся после подготовки выборки.</div>
                </div>
                <div>
                  <h2>Кэшированные облака</h2>
                  <div class="cloud-list" id="cloud_list"><div class="empty">Кэш не найден.</div></div>
                </div>
                <div>
                  <h2>Настройки импорта</h2>
                  <dl id="settings_list"></dl>
                </div>
              </div>
              <script>
                (function() {
                  const progressTitle = document.getElementById('progress_title');
                  const progressSteps = Array.prototype.slice.call(document.querySelectorAll('#progress_steps li'));
                  const cancelButton = document.getElementById('cancel_button');
                  const managerButton = document.getElementById('manager_button');
                  const managerSection = document.getElementById('manager_section');
                  const cloudList = document.getElementById('cloud_list');
                  const togglePoints = document.getElementById('toggle_points');
                  const toggleAnchors = document.getElementById('toggle_anchors');
                  const previewHint = document.getElementById('preview_hint');
                  const togglePointsLabel = togglePoints.parentElement;
                  const toggleAnchorsLabel = toggleAnchors.parentElement;
                  const statusStage = document.getElementById('status_stage');
                  const statusCache = document.getElementById('status_cache');
                  const statusSample = document.getElementById('status_sample');
                  const statusAnchors = document.getElementById('status_anchors');
                  const statusTimings = document.getElementById('status_timings');
                  const statusErrorRow = document.getElementById('status_error_row');
                  const statusError = document.getElementById('status_error');

                  const STAGE_LABELS = {
                    initializing: 'Инициализация',
                    hash_check: 'Проверка источника',
                    sampling: 'Выборка точек',
                    cache_write: 'Запись кэша',
                    build: 'Построение',
                    navigating: 'Навигация',
                    cancelled: 'Отменено'
                  };

                  const TIMING_LABELS = {
                    hash_check: 'Проверка',
                    sampling: 'Выборка',
                    cache_write: 'Запись кэша',
                    build: 'Построение',
                    preview_build: 'Предпросмотр'
                  };
                  const TIMING_SEQUENCE = ['hash_check', 'sampling', 'cache_write', 'build', 'preview_build'];

                  let previewCapabilities = { sample: false, anchors: false };
                  let suppressVisibilityEvent = false;

                  function updateProgress(payload) {
                    if (!payload) { return; }
                    progressTitle.textContent = payload.title || 'Загрузка облака…';
                    cancelButton.disabled = !payload.cancelEnabled;
                    updateStepProgress(payload.steps);
                    renderStatuses(payload);
                  }

                  function updateStepProgress(steps) {
                    if (!Array.isArray(steps)) { return; }
                    const byKey = {};
                    steps.forEach(step => {
                      if (step && step.key) {
                        byKey[step.key] = step;
                      }
                    });
                    progressSteps.forEach(stepElement => {
                      const key = stepElement.dataset.key;
                      const data = byKey[key] || {};
                      stepElement.classList.remove('pending', 'active', 'complete');
                      const status = data.status || 'pending';
                      stepElement.classList.add(status);
                      const statusLabel = stepElement.querySelector('.status');
                      if (statusLabel) {
                        const percent = (typeof data.percent === 'number') ? Math.round(data.percent * 100) : null;
                        statusLabel.textContent = percent !== null ? percent + '%' : '';
                      }
                    });
                  }

                  function setManagerVisible(visible) {
                    const show = !!visible;
                    if (show) {
                      managerSection.classList.remove('hidden');
                      managerButton.classList.add('toggle');
                      managerButton.textContent = 'Скрыть менеджер';
                    } else {
                      managerSection.classList.add('hidden');
                      managerButton.classList.remove('toggle');
                      managerButton.textContent = 'Менеджер кэша';
                    }
                  }

                  function renderClouds(clouds) {
                    if (!Array.isArray(clouds) || !clouds.length) {
                      cloudList.innerHTML = '<div class="empty">Кэш не найден.</div>';
                      return;
                    }
                    const rows = clouds.map(cloud => {
                      const classes = ['cloud'];
                      if (cloud.active) { classes.push('active'); }
                      const name = cloud.name || cloud.id;
                      const updated = cloud.updatedAt ? 'Обновлено: ' + cloud.updatedAt : '';
                      const source = cloud.sourcePath ? 'Источник: ' + cloud.sourcePath : '';
                      const cache = cloud.cachePath ? 'Кэш: ' + cloud.cachePath : '';
                      const meta = [updated, source, cache].filter(Boolean).join('<br>');
                      return '<div class="' + classes.join(' ') + '"><div class="name">' + name + '</div><div class="meta">' + meta + '</div></div>';
                    }).join('');
                    cloudList.innerHTML = rows;
                  }

                  function renderSettings(settings) {
                    const target = document.getElementById('settings_list');
                    if (!settings || !Object.keys(settings).length) {
                      target.innerHTML = '<div class="empty">Нет данных.</div>';
                      return;
                    }
                    const rows = Object.keys(settings).map(key => {
                      const label = settings[key].label || key;
                      const value = settings[key].value || '';
                      return '<dt>' + label + '</dt><dd>' + value + '</dd>';
                    }).join('');
                    target.innerHTML = rows;
                  }

                  function updatePreviewState(state) {
                    state = state || {};
                    const capabilities = state.capabilities || {};
                    previewCapabilities.sample = !!capabilities.sample;
                    previewCapabilities.anchors = !!capabilities.anchors;

                    suppressVisibilityEvent = true;
                    const showPoints = !!state.showPoints && previewCapabilities.sample;
                    const showAnchors = !!state.showAnchors && previewCapabilities.sample && previewCapabilities.anchors;
                    togglePoints.checked = showPoints;
                    toggleAnchors.checked = showAnchors;
                    togglePoints.disabled = !previewCapabilities.sample;
                    togglePointsLabel.classList.toggle('disabled', togglePoints.disabled);
                    const anchorsDisabled = !previewCapabilities.sample || !togglePoints.checked || !previewCapabilities.anchors;
                    toggleAnchors.disabled = anchorsDisabled;
                    toggleAnchorsLabel.classList.toggle('disabled', anchorsDisabled);
                    previewHint.style.display = previewCapabilities.sample ? 'none' : 'block';
                    suppressVisibilityEvent = false;
                  }

                  function notifyVisibility() {
                    if (suppressVisibilityEvent) { return; }
                    if (!previewCapabilities.sample) { return; }
                    const payload = {
                      points: !!togglePoints.checked,
                      anchors: !!toggleAnchors.checked && !!togglePoints.checked && previewCapabilities.anchors
                    };
                    if (window.sketchup && window.sketchup.toggleVisibility) {
                      window.sketchup.toggleVisibility(JSON.stringify(payload));
                    }
                  }

                  function renderStatuses(payload) {
                    const stageKey = (payload && payload.stage) ? payload.stage.toString() : '';
                    statusStage.textContent = STAGE_LABELS[stageKey] || '—';
                    const cacheHit = !!(payload && (payload.cacheHit || payload.cache_hit));
                    statusCache.classList.remove('cache-hit', 'cache-miss');
                    statusCache.classList.add(cacheHit ? 'cache-hit' : 'cache-miss');
                    statusCache.textContent = cacheHit ? 'Кэш обновлён' : 'Новый импорт';
                    const sampleReady = !!(payload && payload.sampleReady);
                    const anchorsReady = !!(payload && payload.anchorsReady);
                    statusSample.textContent = sampleReady ? 'Готово' : 'Готовится…';
                    if (!sampleReady) {
                      statusAnchors.textContent = 'Нет данных';
                    } else if (anchorsReady) {
                      statusAnchors.textContent = 'Готово';
                    } else {
                      statusAnchors.textContent = 'Недоступно';
                    }
                    const completionStatus = readCompletionStatus(payload);
                    const completed = completionStatus === 'completed';
                    statusTimings.classList.toggle('pending', !completed);
                    statusTimings.textContent = completed ? formatTimings(payload && payload.timings, { cacheHit: cacheHit }) : 'Ожидание…';
                    const errorInfo = payload && payload.error;
                    if (errorInfo && errorInfo.message) {
                      statusError.textContent = errorInfo.message;
                      statusErrorRow.classList.remove('hidden');
                      statusErrorRow.classList.add('error');
                    } else {
                      statusError.textContent = '—';
                      statusErrorRow.classList.add('hidden');
                    }
                  }

                  function readCompletionStatus(payload) {
                    if (!payload) { return ''; }
                    const raw = payload.completionStatus || payload.completion_status;
                    return raw ? raw.toString() : '';
                  }

                  function readStageEntry(stages, key) {
                    if (!stages || typeof stages !== 'object') { return null; }
                    const raw = stages[key] || stages[key.toString()];
                    if (raw === undefined || raw === null) { return null; }
                    if (typeof raw === 'number') {
                      return { duration: raw, points: 0 };
                    }
                    if (typeof raw === 'object') {
                      const duration = Number(raw.duration || raw.total || raw.total_duration || 0);
                      const points = Number(raw.points || raw.point_count || 0);
                      return { duration: duration, points: points };
                    }
                    return null;
                  }

                  function formatTimings(timings, options) {
                    if (!timings || typeof timings !== 'object') { return '—'; }
                    const parts = [];
                    const total = formatDuration(timings.total || timings.total_duration);
                    const totalPoints = formatPoints(timings.total_points);
                    const cacheHit = options && options.cacheHit;
                    if (total) {
                      const label = cacheHit ? 'Кэш' : 'Импорт';
                      let headline = label + ': ' + total;
                      if (totalPoints) { headline += ' (' + totalPoints + ')'; }
                      parts.push(headline);
                    } else if (totalPoints) {
                      parts.push(totalPoints);
                    }
                    const stages = timings.stages || {};
                    TIMING_SEQUENCE.forEach(key => {
                      const entry = readStageEntry(stages, key);
                      if (!entry) { return; }
                      const duration = formatDuration(entry.duration);
                      if (!duration) { return; }
                      let label = TIMING_LABELS[key] || key;
                      const pointsLabel = formatPoints(entry.points);
                      if (pointsLabel) { label += ' (' + pointsLabel + ')'; }
                      parts.push(label + ': ' + duration);
                    });
                    return parts.length ? parts.join(', ') : '—';
                  }

                  function formatDuration(value) {
                    const seconds = Number(value);
                    if (!isFinite(seconds) || seconds <= 0) { return null; }
                    if (seconds < 1) {
                      return Math.round(seconds * 1000) + ' мс';
                    }
                    if (seconds < 60) {
                      return seconds.toFixed(1) + ' с';
                    }
                    const minutes = Math.floor(seconds / 60);
                    const remaining = Math.round(seconds % 60);
                    if (minutes >= 60) {
                      const hours = Math.floor(minutes / 60);
                      const mins = minutes % 60;
                      const hourLabel = hours + ' ч';
                      const minuteLabel = mins > 0 ? ' ' + mins + ' мин' : '';
                      return hourLabel + minuteLabel;
                    }
                    const secondLabel = remaining > 0 ? ' ' + remaining + ' с' : '';
                    return minutes + ' мин' + secondLabel;
                  }

                  function formatPoints(value) {
                    const points = Number(value);
                    if (!isFinite(points) || points <= 0) { return ''; }
                    if (points >= 1000000) {
                      const millions = points / 1000000;
                      return (millions >= 10 ? Math.round(millions) : millions.toFixed(1).replace(/\.0$/, '')) + ' млн точек';
                    }
                    if (points >= 1000) {
                      const thousands = points / 1000;
                      return (thousands >= 10 ? Math.round(thousands) : thousands.toFixed(1).replace(/\.0$/, '')) + ' тыс. точек';
                    }
                    return points.toLocaleString('ru-RU') + ' точек';
                  }

                  cancelButton.addEventListener('click', () => {
                    if (window.sketchup && window.sketchup.cancel) {
                      window.sketchup.cancel();
                    }
                  });

                  managerButton.addEventListener('click', () => {
                    const willShow = managerSection.classList.contains('hidden');
                    setManagerVisible(willShow);
                    if (window.sketchup && window.sketchup.toggleManager) {
                      window.sketchup.toggleManager(willShow ? 'true' : 'false');
                    }
                  });

                  togglePoints.addEventListener('change', () => {
                    if (!previewCapabilities.sample && togglePoints.checked) {
                      togglePoints.checked = false;
                      return;
                    }
                    if (!togglePoints.checked) {
                      toggleAnchors.checked = false;
                    }
                    const anchorsDisabled = !previewCapabilities.sample || !togglePoints.checked || !previewCapabilities.anchors;
                    toggleAnchors.disabled = anchorsDisabled;
                    toggleAnchorsLabel.classList.toggle('disabled', anchorsDisabled);
                    togglePointsLabel.classList.toggle('disabled', togglePoints.disabled);
                    previewHint.style.display = previewCapabilities.sample ? 'none' : 'block';
                    notifyVisibility();
                  });

                  toggleAnchors.addEventListener('change', () => {
                    if (!togglePoints.checked || !previewCapabilities.anchors) {
                      toggleAnchors.checked = false;
                      return;
                    }
                    notifyVisibility();
                  });

                  window.dialogProgress = {
                    updateProgress: updateProgress,
                    setManagerVisible: setManagerVisible,
                    updateClouds: renderClouds,
                    updateSettings: renderSettings,
                    updatePreviewState: updatePreviewState
                  };

                  window.addEventListener('load', function() {
                    if (window.sketchup && window.sketchup.ready) {
                      window.sketchup.ready();
                    }
                  });
                })();
              </script>
            </body>
          </html>
        HTML
      end

      def push_full_state
        return unless using_html_dialog?
        return unless @dialog

        push_progress_update
        push_preview_state
        push_clouds
        push_settings
      end

      def push_progress_update
        payload = JSON.generate(progress_payload)
        dispatch_script("window.dialogProgress && window.dialogProgress.updateProgress(#{payload})")
      end

      def push_clouds
        payload = JSON.generate(@cloud_records)
        dispatch_script("window.dialogProgress && window.dialogProgress.updateClouds(#{payload})")
      end

      def push_settings
        payload = JSON.generate(settings_payload)
        dispatch_script("window.dialogProgress && window.dialogProgress.updateSettings(#{payload})")
      end

      def push_preview_state
        return if using_fallback?

        state_payload = {
          showPoints: !!@visibility_state[:points],
          showAnchors: !!@visibility_state[:anchors],
          capabilities: {
            sample: !!@preview_available,
            anchors: !!@anchors_available
          }
        }
        preview_json = JSON.generate(state_payload)
        dispatch_script("window.dialogProgress && window.dialogProgress.updatePreviewState(#{preview_json})")
      end

      def progress_payload
        {
          title: STATE_TITLES.fetch(state, STATE_TITLES[:idle]),
          cancelEnabled: cancel_enabled?,
          steps: build_step_entries,
          stage: state,
          cacheHit: @cache_hit,
          completionStatus: @completion_status,
          sampleReady: !!@preview_available,
          anchorsReady: !!@anchors_available,
          timings: @latest_timings,
          error: @latest_error_info
        }
      end

      def build_step_entries
        sampling_ratio = @stage_progress[:sampling].to_f.clamp(0.0, 1.0)
        parsing_ratio = [sampling_ratio / 0.35, 1.0].min
        sampling_only_ratio = if sampling_ratio > 0.35
                                ((sampling_ratio - 0.35) / 0.65).clamp(0.0, 1.0)
                              else
                                0.0
                              end

        step_progress = {
          hash: @stage_progress[:hash_check].to_f.clamp(0.0, 1.0),
          parsing: parsing_ratio,
          sampling: sampling_only_ratio,
          cache: @stage_progress[:cache_write].to_f.clamp(0.0, 1.0),
          build: @stage_progress[:build].to_f.clamp(0.0, 1.0)
        }

        STEP_SEQUENCE.map do |key|
          {
            key: key,
            label: STEP_LABELS[key],
            status: step_status_for(key, step_progress[key]),
            percent: step_progress[key]
          }
        end
      end

      def step_status_for(key, ratio)
        return 'complete' if ratio >= 0.999

        current_step = current_step_for_state
        case key
        when current_step
          'active'
        when ->(value) { step_order(value) < step_order(current_step) }
          'complete'
        else
          'pending'
        end
      end

      def current_step_for_state
        case state
        when :hash_check, :initializing
          :hash
        when :sampling
          sampling_ratio = @stage_progress[:sampling].to_f
          sampling_ratio >= 0.35 ? :sampling : :parsing
        when :cache_write
          :cache
        when :build, :navigating
          :build
        when :cancelled
          :hash
        else
          :hash
        end
      end

      def step_order(key)
        STEP_SEQUENCE.index(key) || STEP_SEQUENCE.length
      end

      def settings_payload
        return {} unless @settings.is_a?(Hash)

        {
          mode: { label: 'Режим', value: safe_string(@settings[:mode] || '-') },
          budget: { label: 'Бюджет точек', value: formatted_budget(@settings[:budget]) },
          point_size: { label: 'Размер точки', value: formatted_point_size(@settings[:point_size]) },
          memory_limit: { label: 'Лимит памяти', value: formatted_memory(@settings[:memory_limit]) }
        }
      end

      def formatted_budget(value)
        number = value.to_i
        return '—' if number <= 0

        if number >= 1_000_000
          format('%.1f млн', number / 1_000_000.0)
        elsif number >= 1_000
          format('%.1f тыс', number / 1_000.0)
        else
          number.to_s
        end
      end

      def formatted_point_size(value)
        value = value.to_i
        value = 1 if value <= 0
        "#{value} px"
      end

      def formatted_memory(value)
        return '—' unless value

        "#{value.to_i} МБ"
      end

      def safe_string(value)
        string = value.to_s
        string.empty? ? '—' : string
      end

      def dispatch_script(script)
        return if script.nil? || script.empty?

        if @dialog && @html_ready
          @dialog.execute_script(script)
        else
          @pending_scripts << script
        end
      rescue StandardError
        nil
      end

      def flush_pending_scripts
        return unless @dialog && @html_ready

        scripts = @pending_scripts.dup
        @pending_scripts.clear
        scripts.each { |code| @dialog.execute_script(code) }
      end

      def default_stage_progress
        {
          hash_check: 0.0,
          sampling: 0.0,
          cache_write: 0.0,
          build: 0.0
        }
      end

      def default_stage_timings
        default_stage_progress.keys.each_with_object({}) do |stage, memo|
          memo[stage] = blank_stage_entry
        end
      end

      def blank_stage_entry
        { duration: 0.0, points: 0, segments: [] }
      end

      def build_visibility_state(settings)
        {
          points: !!settings&.dig(:preview_show_points),
          anchors: !!settings&.dig(:preview_anchor_only)
        }
      end

      def safe_hash(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, raw), memo|
          memo[key.to_sym] = raw
        end
      end

      def extract_optional_boolean(hash, key)
        symbol_key = key.to_sym
        string_key = key.to_s

        if hash.key?(symbol_key)
          value = hash[symbol_key]
        elsif hash.key?(string_key)
          value = hash[string_key]
        else
          return nil
        end

        case value
        when nil then nil
        when true, 'true', '1', 1 then true
        when false, 'false', '0', 0 then false
        else
          !!value
        end
      end

      def normalize_timings(value)
        data = safe_hash(value)

        total = normalize_float(data[:total] || data['total'])
        total_points = normalize_integer(data[:total_points] || data['total_points'])
        cache_hit = normalize_optional_boolean(data[:cache_hit] || data['cache_hit'])
        status = normalize_string(data[:status] || data['status'])
        started_at = normalize_timestamp(data[:started_at] || data['started_at'])
        finished_at = normalize_timestamp(data[:finished_at] || data['finished_at'])
        generated_at = normalize_timestamp(data[:generated_at] || data['generated_at'])

        stages_source = data[:stages] || data['stages'] || {}
        stages_hash = default_stage_timings.transform_values { blank_stage_entry }

        safe_hash(stages_source).each do |stage, raw|
          stages_hash[stage.to_sym] = normalize_stage_entry(raw)
        end

        preview_stage = :preview_build
        unless stages_hash.key?(preview_stage)
          raw = stages_source[preview_stage] || stages_source[preview_stage.to_s]
          stages_hash[preview_stage] = normalize_stage_entry(raw)
        end

        {
          total: total,
          total_points: total_points,
          cache_hit: cache_hit.nil? ? false : cache_hit,
          status: status,
          started_at: started_at,
          finished_at: finished_at,
          generated_at: generated_at,
          stages: stages_hash,
          metadata: normalize_metadata(data[:metadata] || data['metadata'])
        }
      rescue StandardError
        {
          total: 0.0,
          total_points: 0,
          cache_hit: false,
          status: nil,
          started_at: nil,
          finished_at: nil,
          generated_at: nil,
          stages: default_stage_timings.merge(preview_build: blank_stage_entry),
          metadata: {}
        }
      end

      def normalize_stage_entry(raw)
        case raw
        when Hash
          hash = safe_hash(raw)
          duration = normalize_float(hash[:duration] || hash['duration'] || hash[:total] || hash['total'])
          points = normalize_integer(hash[:points] || hash['points'])
          segments = normalize_segments(hash[:segments] || hash['segments'])
          { duration: duration, points: points, segments: segments }
        when Numeric
          { duration: normalize_float(raw), points: 0, segments: [] }
        else
          blank_stage_entry
        end
      rescue StandardError
        blank_stage_entry
      end

      def normalize_segments(value)
        Array(value).each_with_object([]) do |segment, memo|
          next unless segment.is_a?(Hash)

          hash = safe_hash(segment)
          normalized = {
            started_at: normalize_timestamp(hash[:started_at] || hash['started_at']),
            finished_at: normalize_timestamp(hash[:finished_at] || hash['finished_at']),
            duration: normalize_float(hash[:duration] || hash['duration']),
            points: normalize_integer(hash[:points] || hash['points'])
          }
          metadata = normalize_metadata(hash[:metadata] || hash['metadata'])
          normalized[:metadata] = metadata if metadata.any?
          memo << normalized
        end
      rescue StandardError
        []
      end

      def normalize_timestamp(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      rescue StandardError
        nil
      end

      def normalize_integer(value)
        return 0 if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        0
      end

      def normalize_optional_boolean(value)
        case value
        when nil then nil
        when true, 'true', '1', 1 then true
        when false, 'false', '0', 0 then false
        else
          !!value
        end
      rescue StandardError
        nil
      end

      def normalize_string(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      rescue StandardError
        nil
      end

      def normalize_metadata(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, raw), memo|
          memo[key.to_sym] = raw
        end
      rescue StandardError
        {}
      end

      def normalize_error(value)
        case value
        when nil
          nil
        when String
          message = value.to_s.strip
          message.empty? ? nil : { message: message }
        when Hash
          data = value
          message = data[:message] || data['message']
          message = message.to_s.strip if message
          return nil if message.nil? || message.empty?

          normalized = { message: message }
          klass = data[:class] || data['class']
          normalized[:class] = klass.to_s unless klass.nil? || klass.to_s.strip.empty?
          backtrace = data[:backtrace] || data['backtrace']
          backtrace = Array(backtrace).map { |line| line.to_s.strip }.reject(&:empty?)
          normalized[:backtrace] = backtrace if backtrace.any?
          normalized
        else
          nil
        end
      rescue StandardError
        nil
      end

      def normalize_float(value)
        return 0.0 if value.nil?

        Float(value)
      rescue ArgumentError, TypeError
        0.0
      end

      def load_cached_clouds
        return {} unless @cache_loader.respond_to?(:call)

        result = @cache_loader.call
        result.is_a?(Hash) ? result : {}
      rescue StandardError
        {}
      end

      def normalize_clouds(clouds_hash)
        active_ids = if @manager&.respond_to?(:clouds)
                       @manager.clouds.keys.map(&:to_s)
                     else
                       []
                     end

        clouds_hash.map do |id, data|
          data = {} unless data.is_a?(Hash)
          normalized_id = id.to_s
          {
            id: normalized_id,
            name: data['name'] || data[:name] || normalized_id,
            sourcePath: data['source_path'] || data[:source_path],
            cachePath: data['cache_path'] || data[:cache_path],
            updatedAt: data['updated_at'] || data[:updated_at],
            active: active_ids.include?(normalized_id)
          }
        end.sort_by { |entry| entry[:name].to_s.downcase }
      rescue StandardError
        []
      end

      def handle_visibility_request(payload)
        data = parse_json(payload)
        points = !!data['points']
        anchors = !!data['anchors'] && points
        @visibility_state = { points: points, anchors: anchors }
        @on_visibility_change&.call(points: points, anchors: anchors)
        push_preview_state
      end

      def handle_manager_toggle(payload)
        visible = parse_boolean(payload)
        @manager_visible = visible
        @on_manager_visibility_change&.call(visible) if @on_manager_visibility_change
        auto_close_if_complete if %i[navigating cancelled].include?(state)
      end

      def parse_json(value)
        case value
        when String
          JSON.parse(value)
        when Hash
          value
        else
          {}
        end
      rescue JSON::ParserError, TypeError
        {}
      end

      def parse_boolean(value)
        case value
        when true, 'true', '1', 1 then true
        else false
        end
      end

      def auto_close_if_complete
        return unless using_html_dialog?
        return unless %i[navigating cancelled].include?(state)
        return if @manager_visible

        hide!
      end
    end
  end
end
