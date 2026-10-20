import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/state/editor_state.dart';

/// 极端场景：counts 中出现"同 code 不同实例"的 BeadColor 时，
/// 按 code 判等应保证聚合为一行。
void main() {
  test('同 code 不同实例的 BeadColor 聚合为一行', () {
    final state = EditorState();
    final k3Singleton = BeadPalette.byCode['K3']!;
    // 手工构造一个与 K3 同 code 但不同实例的对象（模拟任何
    // 意外路径产生的"相等但不同实例"）。
    final k3Clone = BeadColor(
      code: 'K3', name: '浅粉', red: 250, green: 205, blue: 215,
    );
    expect(identical(k3Singleton, k3Clone), isFalse);
    expect(k3Clone, equals(k3Singleton), reason: '按 code 判等应相等');

    final d1 = BeadPalette.byCode['D1']!;
    final cells = List<BeadColor>.filled(16, d1);
    cells[0] = k3Singleton;
    cells[1] = k3Clone;
    state.pattern = BeadPattern(
      width: 4,
      height: 4,
      cells: List.unmodifiable(cells),
      counts: List.unmodifiable([
        BeadCount(color: d1, count: 14),
        BeadCount(color: k3Singleton, count: 1),
        BeadCount(color: k3Clone, count: 1),
      ]),
    );

    // 涂一格 K3（单例）——聚合后 K3 应只有一行、数量 3。
    state.beginStroke();
    state.paintCell(2, 0, k3Singleton);
    state.endStroke();

    final k3Rows = state.pattern!.counts
        .where((bc) => bc.color.code == 'K3')
        .toList();
    expect(k3Rows.length, 1, reason: 'K3 必须只有一行');
    expect(k3Rows.first.count, 3);
    expect(state.pattern!.counts.length, 2);
    state.dispose();
  });
}
