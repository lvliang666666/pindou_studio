import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/state/editor_state.dart';

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

  group('底板显示模式', () {
    test('setShowBoard 开启：图纸不超出时无提示', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.pattern = makePattern(50, 50);
      state.boardSize = 50;

      final msg = state.setShowBoard(true);
      expect(state.showBoard, isTrue);
      expect(msg, isNull);
      // 图纸尺寸不变。
      expect(state.pattern!.width, 50);
      expect(state.pattern!.height, 50);
    });

    test('setShowBoard 关闭：直接切换无缩放', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.setShowBoard(true);
      state.pattern = makePattern(50, 50);

      state.setShowBoard(false);
      expect(state.showBoard, isFalse);
      expect(state.pattern!.width, 50);
    });

    test('图纸超出底板：自动等比缩小并返回提示', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 60);

      final msg = state.setShowBoard(true);
      expect(msg, isNotNull);
      expect(msg, contains('超出'));
      // 100x60 → 等比缩到 50x30（scale = 50/100 = 0.5）。
      expect(state.pattern!.width, 50);
      expect(state.pattern!.height, 30);
      // 尺寸输入框同步。
      expect(state.gridWidthCtrl.text, '50');
      expect(state.gridHeightCtrl.text, '30');
      // 缩小后不再超出。
      expect(state.pattern!.width <= state.boardSize, isTrue);
    });

    test('竖长图超出：按高度缩回', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(40, 120);

      state.setShowBoard(true);
      // 40x120 → 缩到 16x50（40 * 50/120 = 16.67 → 16）。
      expect(state.pattern!.height, 50);
      expect(state.pattern!.width, 16);
    });

    test('syncBoardSize：底板缩小后图纸超出同样缩回', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 100;
      state.showBoard = true;
      state.pattern = makePattern(80, 80);

      // 底板从 100 缩到 60：80x80 图纸超出，缩到 60x60。
      final msg = state.syncBoardSize(60);
      expect(state.boardSize, 60);
      expect(msg, isNotNull);
      expect(state.pattern!.width, 60);
      expect(state.pattern!.height, 60);
    });

    test('syncBoardSize：底板变大不放大图纸', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(50, 50);

      final msg = state.syncBoardSize(80);
      expect(msg, isNull); // 不超出不提示
      expect(state.pattern!.width, 50); // 不放大
    });

    test('重采样保持颜色：纯色图缩小后仍是同色', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.showBoard = true;
      state.pattern = makePattern(100, 100);

      state.setShowBoard(true);
      expect(state.pattern!.width, 50);
      expect(state.pattern!.counts.length, 1);
      expect(state.pattern!.totalBeads, 50 * 50);
    });

    test('重采样空格语义：半透明区域（空格）缩小后保持空格', () {
      // 100x100 图纸：左半实豆右半空格，缩到 50x50 后左半实豆右半空格。
      final bead = BeadPalette.colors.first;
      final cells = List<BeadColor?>.generate(100 * 100, (i) {
        final x = i % 100;
        return x < 50 ? bead : null;
      });
      final p = BeadPattern(
        width: 100,
        height: 100,
        cells: List.unmodifiable(cells),
        counts: List.unmodifiable([BeadCount(color: bead, count: 5000)]),
      );

      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.pattern = p;
      state.setShowBoard(true);

      expect(state.pattern!.width, 50);
      // 左半（x<25）实豆，右半空格。
      expect(state.pattern!.cellAt(0, 25), isNotNull);
      expect(state.pattern!.cellAt(40, 25), isNull);
    });

    test('无图纸时开启底板：正常切换无异常', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;

      final msg = state.setShowBoard(true);
      expect(state.showBoard, isTrue);
      expect(msg, isNull);
    });

    test('movePatternOnBoard：图纸小于底板时可移动并钳制在底板内', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 100;
      state.pattern = makePattern(50, 50);
      state.setShowBoard(true);

      // 向右下移动 10 格。
      expect(state.movePatternOnBoard(10, 10), isTrue);
      expect(state.boardOffsetX, 10);
      expect(state.boardOffsetY, 10);

      // 越界移动被钳制到上限（100-50=50）。
      state.movePatternOnBoard(100, 100);
      expect(state.boardOffsetX, 50);
      expect(state.boardOffsetY, 50);

      // 反向移动回 0，再移负数钳制在 0。
      state.movePatternOnBoard(-100, -100);
      expect(state.boardOffsetX, 0);
      expect(state.boardOffsetY, 0);
      expect(state.movePatternOnBoard(-5, -5), isFalse);
    });

    test('movePatternOnBoard：图纸等于底板尺寸时无移动空间', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 50;
      state.pattern = makePattern(50, 50);
      state.setShowBoard(true);

      // maxOffset = 0，任何移动都无效。
      expect(state.movePatternOnBoard(5, 5), isFalse);
      expect(state.boardOffsetX, 0);
      expect(state.boardOffsetY, 0);
    });

    test('movePatternOnBoard：底板未显示时不移动', () {
      final state = EditorState();
      addTearDown(state.dispose);
      state.boardSize = 100;
      state.pattern = makePattern(50, 50);
      // 不开启 showBoard。

      expect(state.movePatternOnBoard(5, 5), isFalse);
      expect(state.boardOffsetX, 0);
    });
  });
}
