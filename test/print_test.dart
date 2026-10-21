import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/ui/print_service.dart';

/// 构造纯色测试图纸（源图不小于目标网格，降采样不放大）。
BeadPattern _pattern(int w, int h) {
  final src = w > h ? w : h;
  final px = Uint8List(src * src * 4);
  for (int i = 0; i < px.length; i += 4) {
    px[i] = 220;
    px[i + 1] = 30;
    px[i + 2] = 40;
    px[i + 3] = 255;
  }
  return BeadConverter.convert(
    pixels: px,
    srcWidth: src,
    srcHeight: src,
    options: ConvertOptions(gridWidth: w, gridHeight: h, dither: false),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('页数计算', () {
    test('单板图纸 = 1 板页 + 1 图例页', () {
      final p = _pattern(29, 29);
      expect(p.width, 29, reason: '前置：图纸尺寸正确');
      expect(PrintService.pageCount(p), 2);
    });

    test('30x30 = 4 板 + 1 图例 = 5 页', () {
      final p = _pattern(30, 30);
      expect(p.width, 30, reason: '前置：图纸尺寸正确');
      expect(PrintService.pageCount(p), 5);
    });

    test('58x29 = 2 板 + 1 图例 = 3 页', () {
      final p = _pattern(58, 29);
      expect(p.width, 58, reason: '前置：图纸尺寸正确');
      expect(PrintService.pageCount(p), 3);
    });

    test('87x87 = 9 板 + 1 图例 = 10 页', () {
      final p = _pattern(87, 87);
      expect(p.width, 87, reason: '前置：图纸尺寸正确');
      expect(PrintService.pageCount(p), 10);
    });
  });

  group('字体加载', () {
    test('全部候选缺失时抛出可读错误', () async {
      PrintService.resetFontCache();
      addTearDown(PrintService.resetFontCache);
      expect(
        () => PrintService.loadFont(
            candidates: [r'C:\no\such\font1.ttf', r'C:\no\such\font2.ttf']),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('未找到可用的系统中文字体'),
        )),
      );
    });

    test('真实系统字体可加载（simhei.ttf 存在于 Win10/11）', () async {
      PrintService.resetFontCache();
      addTearDown(PrintService.resetFontCache);
      // Windows 测试环境应能找到黑体；找不到则跳过（非 Windows CI）。
      try {
        final font = await PrintService.loadFont();
        expect(font, isNotNull);
      } on StateError catch (e) {
        if (!e.message.contains('未找到')) rethrow;
      }
    });
  });

  group('PDF 生成', () {
    test('4x4 图纸产出合法 PDF（%PDF- 头 + 非空）', () async {
      PrintService.resetFontCache();
      addTearDown(PrintService.resetFontCache);
      final bytes = await PrintService.buildPdf(_pattern(4, 4));
      expect(bytes, isNotEmpty);
      // PDF 魔数（规范头为 %PDF-1.x）。
      final head = String.fromCharCodes(bytes.take(5));
      expect(head, '%PDF-');
    });

    test('30x30 图纸（4 板）产出合法 PDF 且体积更大', () async {
      PrintService.resetFontCache();
      addTearDown(PrintService.resetFontCache);
      final small = await PrintService.buildPdf(_pattern(4, 4));
      final large = await PrintService.buildPdf(_pattern(30, 30));
      expect(String.fromCharCodes(large.take(5)), '%PDF-');
      // 4 板页 + 图例页，内容更多。
      expect(large.length, greaterThan(small.length));
    });

    test('PDF 包含中文字体嵌入（Type0/CIDFont）', () async {
      PrintService.resetFontCache();
      addTearDown(PrintService.resetFontCache);
      final bytes = await PrintService.buildPdf(_pattern(4, 4));
      final text = String.fromCharCodes(bytes);
      // Type0 CID 字体是中文嵌入的标志（simhei 走 unicode 路径）。
      expect(text.contains('/Type0'), isTrue,
          reason: '中文字体应以 Type0 CID 形式嵌入');
    });
  });
}
