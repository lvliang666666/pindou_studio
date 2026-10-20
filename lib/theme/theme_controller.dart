import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'pindou_theme.dart';

/// 主题控制器：内存生效 + settings.json 持久化。
///
/// 存储位置与项目库一致：`文档/PindouStudio/settings.json`，
/// 内容 `{"themeId": "mac"}`。读取失败/缺文件/未知 id 一律回退默认主题。
///
/// [storageRoot] 可注入（测试用临时目录），仿照 ProjectRepository。
class ThemeController extends ChangeNotifier {
  ThemeController({this.storageRoot});

  /// 存储根目录（null = 系统文档目录下的 PindouStudio）。
  final Directory? storageRoot;

  PindouTheme _current = pindouThemeById('default');

  /// 当前主题（启动时先给默认，load() 完成后可能更新）。
  PindouTheme get current => _current;

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

  /// 启动时读取持久化主题；失败静默回退默认（首帧已用默认渲染，无阻塞）。
  Future<void> load() async {
    try {
      final file = await _ensureFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return;
      final id = json['themeId'];
      if (id is! String) return;
      _apply(id);
    } catch (_) {
      // 坏 JSON / 无权限等：保持默认主题。
    }
  }

  /// 切换主题：立即生效并异步落盘（落盘失败不影响界面）。
  Future<void> select(String themeId) async {
    if (!_apply(themeId)) return;
    notifyListeners();
    try {
      final file = await _ensureFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({'themeId': themeId}),
      );
    } catch (_) {
      // 持久化失败不阻断切换。
    }
  }

  /// 应用主题 id；未知 id 返回 false 且不改动。
  bool _apply(String themeId) {
    final theme = pindouThemeById(themeId);
    if (identical(theme, _current)) return false;
    _current = theme;
    return true;
  }
}
