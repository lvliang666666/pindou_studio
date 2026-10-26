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

    test('原图留存：保存写入 sources/，读取还原字节', () async {
      final sourceBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final project = SavedProject.fromPattern(
        id: 'p_src',
        name: '带原图',
        pattern: _makePattern(),
        sourceExt: 'png',
      );
      await repo.saveProject(project, sourceImageBytes: sourceBytes);

      final loaded = await repo.loadProject('p_src');
      expect(loaded!.sourceExt, 'png');
      final restored = await repo.loadSourceImage(loaded);
      expect(restored, sourceBytes);
    });

    test('无原图项目：loadSourceImage 返回 null', () async {
      final project = SavedProject.fromPattern(
        id: 'p_nosrc',
        name: '无原图',
        pattern: _makePattern(),
      );
      await repo.saveProject(project);
      final loaded = await repo.loadProject('p_nosrc');
      expect(loaded!.sourceExt, isNull);
      expect(await repo.loadSourceImage(loaded), isNull);
    });

    test('删除项目连带删除原图', () async {
      final project = SavedProject.fromPattern(
        id: 'p_del',
        name: '待删',
        pattern: _makePattern(),
        sourceExt: 'jpg',
      );
      await repo.saveProject(
        project,
        sourceImageBytes: Uint8List.fromList([7, 7, 7]),
      );
      expect(await repo.loadSourceImage(project), isNotNull);

      await repo.deleteProject('p_del');
      expect(await repo.loadProject('p_del'), isNull);
      // 原图文件已删：重新构造同 id 项目读取应返回 null（文件不存在）。
      expect(
        await repo.loadSourceImage(
          SavedProject.fromPattern(
            id: 'p_del',
            name: 'x',
            pattern: _makePattern(),
            sourceExt: 'jpg',
          ),
        ),
        isNull,
      );
    });

    test('复制项目：新 id 独立，名称加副本后缀，原图缩略图跟随', () async {
      final project = SavedProject.fromPattern(
        id: 'p_orig',
        name: '原件',
        pattern: _makePattern(),
        sourceExt: 'png',
      );
      await repo.saveProject(
        project,
        thumbnailPng: Uint8List.fromList([4, 4]),
        sourceImageBytes: Uint8List.fromList([8, 8, 8]),
      );

      final newId = await repo.duplicateProject('p_orig');
      expect(newId, isNotNull);
      expect(newId, isNot('p_orig'));

      final copy = await repo.loadProject(newId!);
      expect(copy!.name, '原件 副本');
      expect(copy.toPattern()!.width, 4);
      expect(await repo.loadThumbnail(newId), isNotNull);
      expect(await repo.loadSourceImage(copy), [8, 8, 8]);

      // 原件不受影响。
      expect(await repo.loadProject('p_orig'), isNotNull);
    });

    test('复制不存在的项目返回 null', () async {
      expect(await repo.duplicateProject('p_missing'), isNull);
    });

    test('非法扩展名被拒绝（不写文件）', () async {
      final project = SavedProject.fromPattern(
        id: 'p_badext',
        name: '坏扩展名',
        pattern: _makePattern(),
        sourceExt: '../evil',
      );
      await repo.saveProject(
        project,
        sourceImageBytes: Uint8List.fromList([1]),
      );
      // JSON 里保留了原始 ext，但磁盘上不应写出 sources/ 下的文件。
      final sourcesDir = Directory('${tempDir.path}/sources');
      expect(sourcesDir.listSync().whereType<File>(), isEmpty);
    });

    test('导入历史：记录后可列出，新→旧排序', () async {
      await repo.recordImport(Uint8List.fromList([1]), 'a.png');
      await repo.recordImport(Uint8List.fromList([2]), 'b.jpg');
      final records = await repo.listImports();
      expect(records.length, 2);
      expect(records[0].fileName, 'b.jpg'); // 最新在前
      expect(records[1].fileName, 'a.png');
      // 字节可还原。
      expect(await records[1].file.readAsBytes(), [1]);
    });

    test('导入历史：文件名非法字符被替换', () async {
      await repo.recordImport(Uint8List.fromList([1]), 'a<b>:c?.png');
      final records = await repo.listImports();
      expect(records.length, 1);
      expect(records[0].fileName, 'a_b__c_.png');
    });

    test('导入历史：超出上限自动清理最旧的', () async {
      for (var i = 0; i < ProjectRepository.maxImportHistory + 3; i++) {
        await repo.recordImport(
          Uint8List.fromList([i]),
          'img$i.png',
        );
        // 文件名含毫秒时间戳，同毫秒内多次导入会互相覆盖——
        // 主动错开时间保证每条独立。
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final records = await repo.listImports();
      expect(records.length, ProjectRepository.maxImportHistory);
      // 最新的保留，最旧的 3 条被清理。
      expect(records.first.fileName, endsWith('img14.png'));
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

    test('loadImage 记录原图字节与扩展名，save 留存到仓库', () async {
      final state = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state.dispose);

      // 构造 8x8 红色 PNG 字节。
      final png = await ProjectRepository.renderThumbnail(_makePattern());
      await state.loadImage(png, 'cat.png');
      expect(state.pattern, isNotNull);

      final id = await state.save(name: '带图项目');
      final loaded = await state.repository.loadProject(id);
      expect(loaded!.sourceExt, 'png');
      expect(loaded.sourceFileName, 'cat.png');
      final restored = await state.repository.loadSourceImage(loaded);
      expect(restored, png);
    });

    test('loadProject 恢复留存的原图（预览与像素可用）', () async {
      // 保存带原图的项目。
      final state1 = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state1.dispose);
      final png = await ProjectRepository.renderThumbnail(_makePattern());
      await state1.loadImage(png, 'dog.png');
      final id = await state1.save(name: '原图恢复');

      // 新状态加载：原图应异步恢复。
      final state2 = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state2.dispose);
      final project = await state2.repository.loadProject(id);
      await state2.loadProject(project!);

      expect(state2.previewImage, isNotNull);
      expect(state2.srcWidth, greaterThan(0));
      expect(state2.srcHeight, greaterThan(0));
      expect(state2.fileName, 'dog.png');
    });

    test('旧项目无原图：loadProject 正常打开，原图为空', () async {
      // 手工构造无 sourceExt 的项目 JSON（模拟旧版本数据）。
      final project = SavedProject.fromPattern(
        id: 'p_legacy',
        name: '旧项目',
        pattern: _makePattern(),
      );
      await ProjectRepository(storageRoot: tempDir).saveProject(project);

      final state = EditorState(repository: ProjectRepository(storageRoot: tempDir));
      addTearDown(state.dispose);
      final loaded = await state.repository.loadProject('p_legacy');
      await state.loadProject(loaded!);

      expect(state.pattern, isNotNull);
      expect(state.previewImage, isNull);
      expect(state.srcWidth, 0);
    });
  });
}
