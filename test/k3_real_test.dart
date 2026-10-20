import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/state/editor_state.dart';

/// 通过真实转换引擎产生图纸（含 K3），再画笔涂 K3，验证统计合并。
void main() {
  test('真实转换图纸：涂已有 K3 累加到同一行', () {
    final state = EditorState();
    // 构造 8x8 图像：左上 2x2 区域接近 K3 浅粉(250,205,215)，
    // 其余接近 D1 正红(220,30,40)。转换后图纸应同时含 K3 与 D1。
    final px = Uint8List(8 * 8 * 4);
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        final idx = (y * 8 + x) * 4;
        final isPink = x < 2 && y < 2;
        px[idx] = isPink ? 250 : 220;
        px[idx + 1] = isPink ? 205 : 30;
        px[idx + 2] = isPink ? 215 : 40;
        px[idx + 3] = 255;
      }
    }
    state.pattern = BeadConverter.convert(
      pixels: px,
      srcWidth: 8,
      srcHeight: 8,
      options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
    );

    final codes = state.pattern!.counts.map((bc) => bc.color.code).toList();
    expect(codes.contains('K3'), isTrue, reason: '转换结果应含 K3');

    final k3Before = state.pattern!.counts
        .firstWhere((bc) => bc.color.code == 'K3')
        .count;

    // 画笔涂 1 格 K3（笔画路径）。
    final k3 = BeadPalette.byCode['K3']!;
    state.beginStroke();
    state.paintCell(3, 3, k3);
    state.endStroke();

    final k3Rows = state.pattern!.counts
        .where((bc) => bc.color.code == 'K3')
        .toList();
    expect(k3Rows.length, 1, reason: 'K3 应只有一行');
    expect(k3Rows.first.count, k3Before + 1);

    // 单格点击路径（弹窗换色）同样验证。
    state.editCell(2, 3, k3);
    final k3Rows2 = state.pattern!.counts
        .where((bc) => bc.color.code == 'K3')
        .toList();
    expect(k3Rows2.length, 1);
    expect(k3Rows2.first.count, k3Before + 2);
    state.dispose();
  });
}
