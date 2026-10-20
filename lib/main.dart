import 'package:flutter/material.dart';

import 'state/editor_state.dart';
import 'theme/theme_controller.dart';
import 'ui/editor/editor_page.dart';

void main() {
  runApp(const PindouStudioApp());
}

/// 应用根：持有主题控制器，打开即编辑器（单页直入，无图库首页）。
class PindouStudioApp extends StatefulWidget {
  const PindouStudioApp({super.key});

  @override
  State<PindouStudioApp> createState() => _PindouStudioAppState();
}

class _PindouStudioAppState extends State<PindouStudioApp> {
  late final ThemeController _themeController;

  @override
  void initState() {
    super.initState();
    _themeController = ThemeController();
    // 异步读取持久化主题：首帧先以默认主题渲染，读完后通知重建。
    _themeController.load();
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeController,
      builder: (context, _) => MaterialApp(
        title: '拼豆工作室',
        debugShowCheckedModeBanner: false,
        theme: _themeController.current.themeData,
        home: _EditorHome(themeController: _themeController),
      ),
    );
  }
}

/// 编辑器宿主：EditorState 在应用级持有，生命周期与进程一致；
/// 项目的新建/打开/保存收敛到编辑器 AppBar（保存按钮 + 项目菜单），
/// 主题设置入口同样在 AppBar（齿轮图标）。
class _EditorHome extends StatefulWidget {
  const _EditorHome({required this.themeController});

  final ThemeController themeController;

  @override
  State<_EditorHome> createState() => _EditorHomeState();
}

class _EditorHomeState extends State<_EditorHome> {
  late final EditorState _editorState;

  @override
  void initState() {
    super.initState();
    _editorState = EditorState();
  }

  @override
  void dispose() {
    _editorState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      state: _editorState,
      themeController: widget.themeController,
    );
  }
}
