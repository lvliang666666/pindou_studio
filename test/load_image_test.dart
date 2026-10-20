import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pindou_studio/state/editor_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadImage 接受 JPEG（3 通道）不越界', () async {
    // 构造 64x64 红色图像并编码为 JPEG（解码后为 3 通道 RGB）。
    final src = img.Image(width: 64, height: 64);
    for (final p in src) {
      p.r = 220;
      p.g = 30;
      p.b = 40;
      p.a = 255;
    }
    final jpegBytes = Uint8List.fromList(img.encodeJpg(src, quality: 90));

    final state = EditorState();
    addTearDown(state.dispose);
    await state.loadImage(jpegBytes, 'test.jpg');

    expect(state.pattern, isNotNull);
    expect(state.pattern!.width, 29);
    expect(state.pattern!.height, 29);
    expect(state.pattern!.totalBeads, 29 * 29);
    // 红色图应量化为 D1 正红。
    expect(state.pattern!.cellAt(0, 0).code, 'D1');
  });

  test('loadImage 接受 PNG（RGBA）正常', () async {
    final src = img.Image(width: 64, height: 64);
    for (final p in src) {
      p.r = 220;
      p.g = 30;
      p.b = 40;
      p.a = 255;
    }
    final pngBytes = Uint8List.fromList(img.encodePng(src));

    final state = EditorState();
    addTearDown(state.dispose);
    await state.loadImage(pngBytes, 'test.png');

    expect(state.pattern, isNotNull);
    expect(state.pattern!.cellAt(0, 0).code, 'D1');
  });

  test('loadImage 拒绝无效字节并抛 FormatException', () async {
    final state = EditorState();
    addTearDown(state.dispose);
    expect(
      () => state.loadImage(Uint8List.fromList([1, 2, 3]), 'bad.jpg'),
      throwsFormatException,
    );
  });
}
