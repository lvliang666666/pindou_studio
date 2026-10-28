import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/palette.dart';
import 'pindou_theme.dart';

/// 应用设置：主题 + 色卡等用户偏好，持久化到
/// `文档/PindouStudio/settings.json`。
///
/// 读取失败/缺文件/未知 id 一律回退默认值。
/// [storageRoot] 可注入（测试用临时目录），仿照 ProjectRepository。
class AppSettings extends ChangeNotifier {
  AppSettings({this.storageRoot});

  /// 存储根目录（null = 系统文档目录下的 PindouStudio）。
  final Directory? storageRoot;

  PindouTheme _theme = pindouThemeById('default');
  String _paletteId = 'default';
  int _boardSize = 50;

  /// 单豆物理边长（mm）：底板显示模式下换算底板实际尺寸。
  double _beadSize = 5.0;

  /// 当前主题。
  PindouTheme get theme => _theme;

  /// 当前色卡 id。
  String get paletteId => _paletteId;

  /// 底板尺寸（正方形边长，豆数）。最小 50，最大 200。
  int get boardSize => _boardSize;

  /// 单豆物理边长（mm）。最小 2.5，最大 10。
  double get beadSize => _beadSize;

  File? _settingsFile;

  Future<File> _ensureFile() async {
    if (_settingsFile != null) return _settingsFile!;
    final docPath = storageRoot?.path ?? await _documentsPath();
    final root = Directory(
        '$docPath${Platform.pathSeparator}PindouStudio');
    await root.create(recursive: true);
    _settingsFile = File('${root.path}${Platform.pathSeparator}settings.json');
    return _settingsFile!;
  }

  static Future<String> _documentsPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// 启动时读取持久化设置；失败静默回退默认（首帧已用默认渲染，无阻塞）。
  Future<void> load() async {
    try {
      final file = await _ensureFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return;
      var changed = false;
      final themeId = json['themeId'];
      if (themeId is String) {
        final t = pindouThemeById(themeId);
        if (!identical(t, _theme)) {
          _theme = t;
          changed = true;
        }
      }
      final pid = json['paletteId'];
      if (pid is String && BeadPalette.all.containsKey(pid)) {
        if (_paletteId != pid) {
          _paletteId = pid;
          BeadPalette.setActive(pid);
          changed = true;
        }
      }
      final bs = json['boardSize'];
      if (bs is int && bs >= 50 && bs <= 200) {
        if (_boardSize != bs) {
          _boardSize = bs;
          changed = true;
        }
      }
      final bd = json['beadSize'];
      if (bd is num && bd >= 2.5 && bd <= 10) {
        final v = bd.toDouble();
        if (_beadSize != v) {
          _beadSize = v;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    } catch (_) {
      // 坏 JSON / 无权限等：保持默认设置。
    }
  }

  /// 更新主题：立即生效并异步落盘（落盘失败不影响界面）。
  Future<void> setTheme(String themeId) async {
    final t = pindouThemeById(themeId);
    if (identical(t, _theme)) return;
    _theme = t;
    notifyListeners();
    await _persist();
  }

  /// 更新色卡：立即生效并异步落盘。
  Future<void> setPalette(String id) async {
    if (!BeadPalette.all.containsKey(id) || _paletteId == id) return;
    _paletteId = id;
    BeadPalette.setActive(id);
    notifyListeners();
    await _persist();
  }

  /// 更新底板尺寸：立即生效并异步落盘。
  /// [size] 限制在 50~200（正方形边长，豆数，最小 50）。
  Future<void> setBoardSize(int size) async {
    final s = size.clamp(50, 200);
    if (_boardSize == s) return;
    _boardSize = s;
    notifyListeners();
    await _persist();
  }

  /// 更新单豆物理边长（mm）：立即生效并异步落盘。
  /// [size] 限制在 2.5~10。
  Future<void> setBeadSize(double size) async {
    final s = size.clamp(2.5, 10.0);
    if (_beadSize == s) return;
    _beadSize = s;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final file = await _ensureFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'themeId': _theme.id,
          'paletteId': _paletteId,
          'boardSize': _boardSize,
          'beadSize': _beadSize,
        }),
      );
    } catch (_) {
      // 持久化失败不阻断切换。
    }
  }
}
