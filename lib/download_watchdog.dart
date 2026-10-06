import 'dart:async';

import 'core_bridge.dart';

/// 下载看门狗：前台运行时周期性检查下载任务，
/// 对「失败 / 暂停」状态的任务自动恢复重试，
/// 解决下载中断后必须手动重试、回前台不自动续传的问题。
class DownloadWatchdog {
  DownloadWatchdog._();

  static final DownloadWatchdog instance = DownloadWatchdog._();

  AppRepository? _repository;
  Timer? _timer;
  bool _busy = false;
  bool _running = false;

  /// 同一任务在窗口期内的自动恢复次数，防止失败循环无限重试。
  final Map<String, int> _resumeCount = {};
  final Map<String, DateTime> _windowStart = {};
  static const Duration _window = Duration(minutes: 10);
  static const int _maxAutoResumePerWindow = 3;
  static const Duration _interval = Duration(seconds: 20);

  void start(AppRepository repository) {
    _repository = repository;
    _running = true;
    _timer ??= Timer.periodic(_interval, (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  /// 立即触发一次检查（例如回前台时）。
  void kick() {
    if (!_running) return;
    unawaited(_tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _resumeCount.clear();
    _windowStart.clear();
  }

  Future<void> _tick() async {
    if (_busy) return;
    final repository = _repository;
    if (repository == null) return;
    _busy = true;
    try {
      final jobs = await repository.downloads();
      final recoverable = jobs
          .where((job) => job.state == 'failed' || job.state == 'paused')
          .toList();
      final now = DateTime.now();
      // 过滤掉窗口期内已自动恢复过多次的任务
      final eligible = recoverable.where((job) {
        final start = _windowStart[job.id];
        if (start == null || now.difference(start) > _window) {
          _windowStart[job.id] = now;
          _resumeCount[job.id] = 1;
          return true;
        }
        final count = _resumeCount[job.id] ?? 0;
        if (count >= _maxAutoResumePerWindow) return false;
        _resumeCount[job.id] = count + 1;
        return true;
      }).toList();
      if (eligible.isEmpty) return;
      // 统一恢复：native resumeAll 会把 paused/failed 任务重新入队
      await repository.controlDownloads('resumeAll');
    } catch (_) {
      // 网络或初始化异常，静默等待下个周期重试
    } finally {
      _busy = false;
    }
  }
}
