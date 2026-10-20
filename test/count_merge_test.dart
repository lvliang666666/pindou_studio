import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/state/editor_state.dart';

/// 复现"图纸已有 K3，涂 K3 后统计出现两行 K3"的问题。
void main() {
  test('笔画涂已有颜色应累加到同一行', () {
    final state = EditorState();
    // 构造 4x4 图纸：3 格 K3 + 13 格 D1（转换引擎产生，均为 palette 单例）。
    final k3 = BeadPalette.byCode['K3']!;
    final d1 = BeadPalette.byCode['D1']!;
    final cells = <BeadColor>[
      k3, k3, k3, d1,
      d1, d1, d1, d1,
      d1, d1, d1, d1,
      d1, d1, d1, d1,
    ];
    state.pattern = BeadPattern(
      width: 4,
      height: 4,
      cells: List.unmodifiable(cells),
      counts: List.unmodifiable([
        BeadCount(color: d1, count: 13),
        BeadCount(color: k3, count: 3),
      ]),
    );

    // 笔画涂 2 格 K3。
    state.beginStroke();
    state.paintCell(0, 1, k3);
    state.paintCell(1, 1, k3);
    state.endStroke();

    final k3Rows = state.pattern!.counts
        .where((bc) => bc.color.code == 'K3')
        .toList();
    expect(k3Rows.length, 1, reason: 'K3 应只有一行');
    expect(k3Rows.first.count, 5, reason: 'K3 应累加为 5');
    expect(state.pattern!.counts.length, 2, reason: '总行数应为 2');

    // 撤销后同样不应有重复。
    state.undo();
    final k3Rows2 = state.pattern!.counts
        .where((bc) => bc.color.code == 'K3')
        .toList();
    expect(k3Rows2.length, 1);
    expect(k3Rows2.first.count, 3);
    state.dispose();
  });

  test('笔画涂新颜色（图纸原本没有）应新增一行', () {
    final state = EditorState();
    final d1 = BeadPalette.byCode['D1']!;
    final m1 = BeadPalette.byCode['M1']!;
    final cells = List<BeadColor>.filled(16, d1);
    state.pattern = BeadPattern(
      width: 4,
      height: 4,
      cells: List.unmodifiable(cells),
      counts: List.unmodifiable([BeadCount(color: d1, count: 16)]),
    );

    state.beginStroke();
    state.paintCell(0, 0, m1);
    state.endStroke();

    final m1Rows = state.pattern!.counts
        .where((bc) => bc.color.code == 'M1')
        .toList();
    expect(m1Rows.length, 1);
    expect(m1Rows.first.count, 1);
    expect(state.pattern!.counts.length, 2);
    state.dispose();
  });

  test('同一笔画内涂了又擦（回到原色）不应产生重复行', () {
    final state = EditorState();
    final k3 = BeadPalette.byCode['K3']!;
    final d1 = BeadPalette.byCode['D1']!;
    final cells = <BeadColor>[
      k3, d1, d1, d1,
      d1, d1, d1, d1,
      d1, d1, d1, d1,
      d1, d1, d1, d1,
    ];
    state.pattern = BeadPattern(
      width: 4,
      height: 4,
      cells: List.unmodifiable(cells),
      counts: List.unmodifiable([
        BeadCount(color: d1, count: 15),
        BeadCount(color: k3, count: 1),
      ]),
    );

    // 涂 (1,0) 为 K3 再擦除（恢复 D1）。
    state.beginStroke();
    state.paintCell(1, 0, k3);
    state.eraseCell(1, 0);
    state.endStroke();

    final k3Rows = state.pattern!.counts
        .where((bc) => bc.color.code == 'K3')
        .toList();
    expect(k3Rows.length, 1);
    expect(k3Rows.first.count, 1);
    expect(state.pattern!.counts.length, 2);
    state.dispose();
  });
}
