import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/main.dart';
import 'package:pindou_studio/theme/pindou_theme.dart';
import 'package:pindou_studio/theme/theme_controller.dart';
import 'package:pindou_studio/ui/pattern_canvas.dart';

void main() {
  group('主题定义', () {
    test('4 套主题 id 唯一且非空', () {
      final ids = kPindouThemes.map((t) => t.id).toSet();
      expect(ids.length, 4);
      for (final t in kPindouThemes) {
        expect(t.id, isNotEmpty);
        expect(t.name, isNotEmpty);
      }
    });

    test('每套主题都挂载了画布配色扩展', () {
      for (final t in kPindouThemes) {
        final ext = t.themeData.extension<PindouCanvasColors>();
        expect(ext, isNotNull, reason: '主题 ${t.id} 缺少 PindouCanvasColors');
      }
    });

    test('pindouThemeById：已知 id 命中，未知 id 回退默认', () {
      expect(pindouThemeById('mac').id, 'mac');
      expect(pindouThemeById('hacker').id, 'hacker');
      expect(pindouThemeById('no-such-theme').id, 'default');
    });

    test('PindouCanvasColors == 语义：同字段相等，异字段不等', () {
      final a = PindouCanvasColors.light;
      final b = PindouCanvasColors.light;
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(PindouCanvasColors.hacker)));
      // copyWith 单字段变化后不等。
      expect(
        a.copyWith(gridThin: Colors.red),
        isNot(equals(a)),
      );
    });
  });

  group('AppSettings 持久化', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('pindou_theme_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('select 后落盘，重新 load 恢复', () async {
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      await settings.setTheme('hacker');
      expect(settings.theme.id, 'hacker');

      // 落盘文件存在且内容正确。
      final file = File(
          '${tempDir.path}${Platform.pathSeparator}PindouStudio'
          '${Platform.pathSeparator}settings.json');
      expect(file.existsSync(), isTrue);
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(json['themeId'], 'hacker');

      // 新控制器 load 后恢复。
      final settings2 = AppSettings(storageRoot: tempDir);
      addTearDown(settings2.dispose);
      await settings2.load();
      expect(settings2.theme.id, 'hacker');
    });

    test('boardSize 设置后落盘，重新 load 恢复', () async {
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      await settings.setBoardSize(50);
      expect(settings.boardSize, 50);

      final settings2 = AppSettings(storageRoot: tempDir);
      addTearDown(settings2.dispose);
      await settings2.load();
      expect(settings2.boardSize, 50);
    });

    test('boardSize 越界值被钳制（29~200）', () async {
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      await settings.setBoardSize(10);
      expect(settings.boardSize, 29);
      await settings.setBoardSize(500);
      expect(settings.boardSize, 200);
    });

    test('boardSize 缺失时回退 29', () async {
      final dir = Directory(
          '${tempDir.path}${Platform.pathSeparator}PindouStudio')
        ..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}settings.json')
          .writeAsStringSync('{"themeId": "default"}');
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.boardSize, 29);
    });

    test('坏 JSON 回退默认主题', () async {
      final dir = Directory(
          '${tempDir.path}${Platform.pathSeparator}PindouStudio')
        ..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}settings.json')
          .writeAsStringSync('{not valid json');
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.theme.id, 'default');
    });

    test('未知 themeId 回退默认主题', () async {
      final dir = Directory(
          '${tempDir.path}${Platform.pathSeparator}PindouStudio')
        ..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}settings.json')
          .writeAsStringSync('{"themeId": "ghost"}');
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.theme.id, 'default');
    });

    test('select 相同主题不重复通知', () async {
      final settings = AppSettings(storageRoot: tempDir);
      addTearDown(settings.dispose);
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setTheme('default');
      expect(notified, 0, reason: '与当前主题相同不应通知');
      await settings.setTheme('codex');
      expect(notified, 1);
    });
  });

  group('主题切换 Widget 冒烟', () {
    testWidgets('设置对话框切换黑客风：主色与画布配色即时生效', (tester) async {
      final app = const PindouStudioApp();
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // 打开设置对话框。
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('主题外观'), findsOneWidget);

      // 点击「黑客风」卡片。
      await tester.tap(find.text('黑客风'));
      await tester.pumpAndSettle();

      // MaterialApp 主色已切换为 matrix 绿。
      final context = tester.element(find.byType(PatternCanvas).first);
      expect(Theme.of(context).colorScheme.primary, const Color(0xFF00FF41));

      // 画布收到黑客风配色。
      final canvas = tester.widget<PatternCanvas>(
          find.byType(PatternCanvas).first);
      expect(canvas.colors, same(PindouCanvasColors.hacker));
      expect(canvas.colors.gridThin, const Color(0xFF003B00));

      // 关闭对话框。
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    });

    testWidgets('切换 Codex 风：画布底色与网格线跟随', (tester) async {
      await tester.pumpWidget(const PindouStudioApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex 风'));
      await tester.pumpAndSettle();

      final canvas = tester.widget<PatternCanvas>(
          find.byType(PatternCanvas).first);
      expect(canvas.colors.canvasBg, const Color(0xFF0D1117));
      expect(canvas.colors.gridMajor, const Color(0xFF484F58));
      // 深色主题的脚手架背景。
      final context = tester.element(find.byType(PatternCanvas).first);
      expect(Theme.of(context).brightness, Brightness.dark);
    });
  });
}
