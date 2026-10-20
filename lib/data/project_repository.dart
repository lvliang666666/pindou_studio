import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/converter.dart';
import 'project_model.dart';

/// 项目库条目（列表展示用的轻量信息）。
class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.width,
    required this.height,
    required this.colorCount,
    required this.totalBeads,
    this.hasThumbnail = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int width;
  final int height;
  final int colorCount;
  final int totalBeads;
  final bool hasThumbnail;
}

/// 项目仓库：基于文件系统的项目持久化。
///
/// 目录结构：
/// ```
/// <文档>/PindouStudio/
///   projects/<id>.json      项目数据
///   thumbs/<id>.png         缩略图
/// ```
/// 存储目录可通过 [storageRoot] 注入（测试用临时目录）。
class ProjectRepository {
  ProjectRepository({this.storageRoot});

  /// 存储根目录（null = 用系统文档目录下的 PindouStudio）。
  final Directory? storageRoot;

  Directory? _projectsDir;
  Directory? _thumbsDir;

  Future<Directory> _ensureDirs() async {
    if (_projectsDir != null) {
      return _projectsDir!;
    }
    final root = storageRoot ??
        Directory(await _documentsPath()).childDir('PindouStudio');
    _projectsDir = root.childDir('projects')..createSync(recursive: true);
    _thumbsDir = root.childDir('thumbs')..createSync(recursive: true);
    return _projectsDir!;
  }

  static Future<String> _documentsPath() async {
    // 桌面端与移动端统一走 path_provider。
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  File _projectFile(String id) => File('${_projectsDir!.path}/$id.json');
  File _thumbFile(String id) => File('${_thumbsDir!.path}/$id.png');

  /// 列出全部项目（按更新时间降序）。
  Future<List<ProjectSummary>> listProjects() async {
    await _ensureDirs();
    final result = <ProjectSummary>[];
    await for (final entity in _projectsDir!.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final project = SavedProject.tryParseJson(await entity.readAsString());
        if (project == null) continue;
        result.add(ProjectSummary(
          id: project.id,
          name: project.name,
          createdAt: project.createdAt,
          updatedAt: project.updatedAt,
          width: project.width,
          height: project.height,
          colorCount: project.toPattern()?.colorCount ?? 0,
          totalBeads: project.width * project.height,
          hasThumbnail: _thumbFile(project.id).existsSync(),
        ));
      } catch (_) {
        // 单个损坏文件不影响整体列表。
      }
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// 读取单个项目；不存在或损坏返回 null。
  Future<SavedProject?> loadProject(String id) async {
    await _ensureDirs();
    final file = _projectFile(id);
    if (!file.existsSync()) return null;
    return SavedProject.tryParseJson(await file.readAsString());
  }

  /// 保存项目（写入 JSON + 更新缩略图）。
  Future<void> saveProject(SavedProject project, {Uint8List? thumbnailPng}) async {
    await _ensureDirs();
    await _projectFile(project.id).writeAsString(project.toJsonString());
    if (thumbnailPng != null) {
      await _thumbFile(project.id).writeAsBytes(thumbnailPng, flush: true);
    }
  }

  /// 删除项目（JSON + 缩略图）。
  Future<void> deleteProject(String id) async {
    await _ensureDirs();
    final file = _projectFile(id);
    if (file.existsSync()) await file.delete();
    final thumb = _thumbFile(id);
    if (thumb.existsSync()) await thumb.delete();
  }

  /// 重命名（更新 JSON 内的 name 与 updatedAt）。
  Future<void> renameProject(String id, String newName) async {
    final project = await loadProject(id);
    if (project == null) return;
    project
      ..name = newName
      ..updatedAt = DateTime.now();
    await _projectFile(id).writeAsString(project.toJsonString());
  }

  /// 读取缩略图文件；不存在返回 null。
  Future<Uint8List?> loadThumbnail(String id) async {
    await _ensureDirs();
    final thumb = _thumbFile(id);
    if (!thumb.existsSync()) return null;
    return await thumb.readAsBytes();
  }

  /// 生成图纸缩略图 PNG（小尺寸纯色块网格，无文字）。
  static Future<Uint8List> renderThumbnail(BeadPattern pattern,
      {int maxSize = 240}) async {
    final cell = (maxSize / pattern.width.clamp(1, maxSize)).clamp(1.0, 12.0);
    final w = (pattern.width * cell).round().clamp(1, 1024);
    final h = (pattern.height * cell).round().clamp(1, 1024);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = Colors.white,
    );
    final fill = Paint()..style = PaintingStyle.fill;
    final sx = w / pattern.width;
    final sy = h / pattern.height;
    for (int y = 0; y < pattern.height; y++) {
      for (int x = 0; x < pattern.width; x++) {
        fill.color = Color(pattern.cellAt(x, y).argb);
        canvas.drawRect(
          Rect.fromLTWH(x * sx, y * sy, sx + 0.5, sy + 0.5),
          fill,
        );
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }
}

extension on Directory {
  Directory childDir(String name) => Directory('$path/$name');
}
