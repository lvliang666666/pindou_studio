import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/data/project_model.dart';
import 'package:pindou_studio/data/project_repository.dart';
import 'package:pindou_studio/state/editor_state.dart';

/// 构造 4x4 纯红图纸。
BeadPattern _makePattern() {
  final px = Uint8List(8 * 8 * 4);
  for (int i = 0; i < px.length; i += 4) {
    px[i] = 220;
    px[i + 1] = 30;
    px[i + 2] = 40;
    px[i + 3] = 255;
  }
  return BeadConverter.convert(
    pixels: px,
    srcWidth: 8,
    srcHeight: 8,
    options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
  );
}

void main() {
  group('SavedProject 序列化', () {
    test('JSON 往返：图纸数据无损', () {
      final pattern = _makePattern();
      final project = SavedProject.fromPattern(
        id: 'p_test',
        name: '测试项目',
        pattern: pattern,
        manualEdits: {'0,0': 'A1'},
        sourceFileName: 'cat.png',
        sourceWidth: 8,
        sourceHeight: 8,
      );

      final restored = SavedProject.tryParseJson(project.toJsonString());
      expect(restored, isNotNull);
      expect(restored!.id, 'p_test');
      expect(restored.name, '测试项目');
      expect(restored.width, 4);
      expect(restored.height, 4);
      expect(restored.manualEdits['0,0'], 'A1');
      expect(restored.sourceFileName, 'cat.png');

      // 图纸还原：格子与统计一致。
      final pattern2 = restored.toPattern()!;
      expect(pattern2.width, pattern.width);
      expect(pattern2.height, pattern.height);
      for (int i = 0; i < pattern.cells.length; i++) {
        expect(pattern2.cells[i].code, pattern.cells[i].code);
      }
      expect(pattern2.counts.length, pattern.counts.length);
    });

    test('RLE 压缩：纯色图编码很短', () {
      final pattern = _makePattern(); // 16 格同色
      final project = SavedProject.fromPattern(
        id: 'p_rle',
        name: 'rle',
        pattern: pattern,
      );
      final json = project.toJsonString();
      // 16 格同色 RLE 后只有 1 对 [色号, 16]。
      expect(json.contains('["D1",16]'), isTrue);
    });

    test('损坏 JSON 返回 null 而不抛异常', () {
      expect(SavedProject.tryParseJson('not json'), isNull);
      expect(SavedProject.tryParseJson('{"width": "x"}'), isNull);
    });
  });

  group('ProjectRepository', () {
    late Directory tempDir;
    late ProjectRepository repo;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pindou_test');
      repo = ProjectRepository(storageRoot: tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('保存后可列出并加载', () async {
      final pattern = _makePattern();
      final project = SavedProject.fromPattern(
        id: 'p_a',
        name: '项目A',
        pattern: pattern,
      );
      await repo.saveProject(project, thumbnailPng: Uint8List.fromList([1, 2, 3]));

      final list = await repo.listProjects();
      expect(list.length, 1);
      expect(list.first.id, 'p_a');
      expect(list.first.name, '项目A');
      expect(list.first.hasThumbnail, isTrue);

      final loaded = await repo.loadProject('p_a');
      expect(loaded, isNotNull);
      expect(loaded!.name, '项目A');
      expect(loaded.toPattern()!.width, 4);
    });

    test('重命名与删除', () async {
      final project = SavedProject.fromPattern(
        id: 'p_b',
        name: '旧名',
        pattern: _makePattern(),
      );
      await repo.saveProject(project);

      await repo.renameProject('p_b', '新名');
      var loaded = await repo.loadProject('p_b');
      expect(loaded!.name, '新名');

      await repo.deleteProject('p_b');
      expect(await repo.loadProject('p_b'), isNull);
      expect(await repo.listProjects(), isEmpty);
    });

    test('缩略图读写', () async {
      final bytes = Uint8List.fromList([9, 8, 7]);
      final project = SavedProject.fromPattern(
        id: 'p_c',
        name: 'c',
        pattern: _makePattern(),
      );
      await repo.saveProject(project, thumbnailPng: bytes);
      final loaded = await repo.loadThumbnail('p_c');
      expect(loaded, isNotNull);
      expect(loaded, bytes);
      expect(await repo.loadThumbnail('missing'), isNull);
    });

    test('缩略图渲染生成有效 PNG', () async {
      final png = await ProjectRepository.renderThumbnail(_makePattern());
      expect(png.length, greaterThan(100));
      // PNG 魔数。
      expect(png[0], 0x89);
      expect(png[1], 0x50);
    });
  });

  group('EditorState 项目保存/加载', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pindou_state_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('save 后 projectId 固化且脏标记清除', () async {
      final state = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state.dispose);
      state.pattern = _makePattern();
      state.editCell(0, 0, BeadPalette.byCode['A1']!);
      expect(state.hasUnsavedChanges, isTrue);

      final id = await state.save(name: '我的项目');
      expect(id, isNotEmpty);
      expect(state.projectId, id);
      expect(state.projectName, '我的项目');
      expect(state.hasUnsavedChanges, isFalse);

      // 再次保存复用同一 id。
      state.editCell(1, 1, BeadPalette.byCode['A1']!);
      final id2 = await state.save();
      expect(id2, id);
    });

    test('loadProject 恢复图纸与手动编辑', () async {
      // 先保存一个项目。
      final state1 = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state1.dispose);
      state1.pattern = _makePattern();
      state1.editCell(2, 2, BeadPalette.byCode['A1']!);
      final id = await state1.save(name: '加载测试');

      // 新状态加载。
      final state2 = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state2.dispose);
      final project = await state2.repository.loadProject(id);
      await state2.loadProject(project!);

      expect(state2.projectId, id);
      expect(state2.projectName, '加载测试');
      expect(state2.pattern!.width, 4);
      expect(state2.pattern!.cellAt(2, 2).code, 'A1');
      expect(state2.manualEdits['2,2'], 'A1');
      expect(state2.hasUnsavedChanges, isFalse);
    });

    test('reset 清空全部状态', () async {
      final state = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state.dispose);
      state.pattern = _makePattern();
      await state.save(name: 'x');
      expect(state.projectId, isNotNull);

      state.reset();
      expect(state.projectId, isNull);
      expect(state.projectName, isEmpty);
      expect(state.pattern, isNull);
      expect(state.hasUnsavedChanges, isFalse);
      expect(state.gridWidthCtrl.text, '29');
    });
  });
}
