import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/state/editor_state.dart';

/// 底板缩回（_shrinkToBoard）后手动编辑坐标重映射测试。
///
/// 背景：图纸等比缩小后 manualEdits/_autoCodes 里的坐标还是旧尺寸的，
/// 不重映射会导致撤销/重转时涂错格子（批次B回归修复的验证）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  BeadPattern makePattern(int w, int h, {BeadColor? color}) {
    final bead = color ?? BeadPalette.colors.first;
    return BeadPattern(
      width: w,
      height: h,
      cells: List.unmodifiable(List<BeadColor?>.filled(w * h, bead)),
      counts: List.unmodifiable([BeadCount(color: bead, count: w * h)]),
    );
  }

  group('缩回底板后手动编辑重映射', () {
    test('manualEdits 坐标按缩放比例重映射到新尺寸内', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 60);
      // 旧尺寸 (100x60) 上的编辑：缩放比 0.5，(10,4) -> (5,2)。
      state.manualEdits['10,4'] = 'A1';
      state.manualEdits['99,59'] = 'B2';

      state.setShowBoard(true);

      // 图纸已缩小。
      expect(state.pattern!.width, 50);
      expect(state.pattern!.height, 30);
      // 所有编辑坐标都在新尺寸范围内。
      for (final key in state.manualEdits.keys) {
        final parts = key.split(',');
        final x = int.parse(parts[0]);
        final y = int.parse(parts[1]);
        expect(x, lessThan(50), reason: '编辑坐标 x=$x 超出新宽度');
        expect(y, lessThan(30), reason: '编辑坐标 y=$y 超出新高度');
      }
      // 精确映射：(10,4) -> (5,2)，(99,59) -> (49,29)。
      expect(state.manualEdits['5,2'], 'A1');
      expect(state.manualEdits['49,29'], 'B2');
      // 旧坐标键已清除。
      expect(state.manualEdits.containsKey('10,4'), isFalse);
      expect(state.manualEdits.containsKey('99,59'), isFalse);
    });

    test('同格多编辑合并：保留最后一个（与重采样语义一致）', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 100);
      // 缩放比 0.5：(2,2) 与 (3,2) 都映射到 (1,1)。
      state.manualEdits['2,2'] = 'A1';
      state.manualEdits['3,2'] = 'B2';

      state.setShowBoard(true);

      expect(state.manualEdits.length, 1);
      expect(state.manualEdits['1,1'], 'B2');
    });

    test('自动色表按新图纸内容重建', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 60);
      state.manualEdits['10,4'] = 'A1';

      state.setShowBoard(true);

      // 自动色表键与新编辑键一致，值为缩放后该格的实际色号。
      expect(state.autoCodesKeys, equals(state.manualEdits.keys.toSet()));
      state.autoCodesEntries.forEach((key, value) {
        final parts = key.split(',');
        final bead = state.pattern!.cellAt(
            int.parse(parts[0]), int.parse(parts[1]));
        expect(value, bead?.code ?? '');
      });
    });

    test('撤销栈清空（旧笔画坐标失效，保留会涂错位置）', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 60);
      state.manualEdits['10,4'] = 'A1';

      // 模拟已有撤销历史（单格编辑走完整路径入撤销栈）。
      // 底色是 colors.first（通用卡 A1 白色），改涂黑色 B1 保证有变化。
      final black = BeadPalette.byCode['B1']!;
      final changed = state.editCell(5, 5, black);
      expect(changed.$1, isTrue, reason: '编辑应生效（B1 黑与底色白不同）');
      expect(state.canUndo, isTrue);

      state.setShowBoard(true);

      // 缩回后撤销栈作废（坐标已失效）。
      expect(state.canUndo, isFalse);
      expect(state.canRedo, isFalse);
    });

    test('无手动编辑时缩回不报错', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 60);

      final msg = state.setShowBoard(true);
      expect(msg, isNotNull);
      expect(state.manualEdits, isEmpty);
      expect(state.pattern!.width, 50);
    });
  });
}
