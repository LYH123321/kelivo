import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/live2d_bridge.dart';
import '../../../icons/lucide_adapter.dart';

/// npu18: settings page for the Live2D floating pet (Android).
class Live2dSettingsPage extends StatefulWidget {
  const Live2dSettingsPage({super.key});

  @override
  State<Live2dSettingsPage> createState() => _Live2dSettingsPageState();
}

class _Live2dSettingsPageState extends State<Live2dSettingsPage> {
  static const String _kModelKey = 'live2d.pet.model';
  static const String _kScaleKey = 'live2d.pet.scale';
  static const String _kFlipKey = 'live2d.pet.flip';
  static const String _kPosXKey = 'live2d.pet.pos_x';
  static const String _kPosYKey = 'live2d.pet.pos_y';

  bool _loading = true;
  bool _enabled = false;
  String _modelPath = Live2dBridge.models.first['path']!;
  bool _hasOverlayPermission = true;

  // 调节参数
  double _scale = 1.0;
  bool _flip = false;
  double _posX = 0.62;
  double _posY = 1.0;

  // 动态扫描到的本地 SD 卡自定义模型列表
  List<Map<String, String>> _localModels = [];

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    String modelPath = Live2dBridge.models.first['path']!;
    double scale = 1.0;
    bool flip = false;
    double posX = 0.62;
    double posY = 1.0;

    try {
      final prefs = await SharedPreferences.getInstance();
      modelPath = prefs.getString(_kModelKey) ?? modelPath;
      scale = prefs.getDouble(_kScaleKey) ?? 1.0;
      flip = prefs.getBool(_kFlipKey) ?? false;
      posX = prefs.getDouble(_kPosXKey) ?? 0.62;
      posY = prefs.getDouble(_kPosYKey) ?? 1.0;
    } catch (_) {}

    final showing = await Live2dBridge.isShowing();
    final canDraw = await Live2dBridge.canDrawOverlays();
    await _scanLocalModels();

    if (!mounted) return;
    setState(() {
      _modelPath = modelPath;
      _scale = scale;
      _flip = flip;
      _posX = posX;
      _posY = posY;
      _enabled = showing;
      _hasOverlayPermission = canDraw;
      _loading = false;
    });

    if (showing) {
      _syncTransform();
    }
  }

  Future<void> _scanLocalModels() async {
    final list = <Map<String, String>>[];
    try {
      final dir = Directory('/sdcard/Kelivo/live2d');
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        for (final e in entities) {
          if (e is Directory) {
            final folderName = e.path.split('/').last;
            try {
              final subFiles = await e.list().toList();
              for (final f in subFiles) {
                if (f.path.endsWith('.model3.json') || f.path.endsWith('.model.json')) {
                  final fileName = f.path.split('/').last;
                  list.add({
                    'id': 'local_$folderName',
                    'name': folderName,
                    'path': 'custom/$folderName/$fileName',
                    'isLocal': 'true',
                  });
                  break;
                }
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    _localModels = list;
  }

  Future<void> _syncTransform() async {
    await Live2dBridge.setTransform(
      scale: _scale,
      flip: _flip,
      x: _posX,
      y: _posY,
    );
  }

  Future<void> _persistTransform() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kScaleKey, _scale);
      await prefs.setBool(_kFlipKey, _flip);
      await prefs.setDouble(_kPosXKey, _posX);
      await prefs.setDouble(_kPosYKey, _posY);
    } catch (_) {}
  }

  Future<void> _refreshPermission() async {
    final canDraw = await Live2dBridge.canDrawOverlays();
    if (!mounted) return;
    setState(() => _hasOverlayPermission = canDraw);
  }

  Future<void> _toggle(bool v) async {
    if (v) {
      if (!_hasOverlayPermission) {
        await Live2dBridge.openOverlaySettings();
        if (!mounted) return;
        setState(() => _enabled = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请授予「显示在其他应用上层」权限后再打开')),
        );
        Future<void>.delayed(const Duration(seconds: 3), _refreshPermission);
        return;
      }
      final ok = await Live2dBridge.show(modelPath: _modelPath);
      if (!mounted) return;
      setState(() => _enabled = ok);
      if (ok) {
        Future<void>.delayed(const Duration(milliseconds: 300), _syncTransform);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('悬浮窗启动失败，请重试或检查权限')),
        );
      }
      return;
    }
    await Live2dBridge.hide();
    if (!mounted) return;
    setState(() => _enabled = false);
  }

  Future<void> _selectModel(Map<String, String> model) async {
    final path = model['path']!;
    setState(() => _modelPath = path);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kModelKey, path);
    } catch (_) {}
    if (_enabled) {
      final ok = await Live2dBridge.show(modelPath: path);
      if (!mounted) return;
      setState(() => _enabled = ok);
      if (ok) {
        Future<void>.delayed(const Duration(milliseconds: 300), _syncTransform);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('切换模型失败，请重试')),
        );
      }
    }
  }

  void _resetTransform() {
    setState(() {
      _scale = 1.0;
      _flip = false;
      _posX = 0.62;
      _posY = 1.0;
    });
    _syncTransform();
    _persistTransform();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allModels = [...Live2dBridge.models, ..._localModels];

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Live2D 桌宠'),
        actions: [
          IconButton(
            tooltip: '扫描刷新 SD 卡模型',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _scanLocalModels();
              if (mounted) setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已刷新，当前找到 ${_localModels.length} 个本地模型')),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // 1. 总开关卡片
                Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: Icon(Lucide.Sparkles, color: cs.primary),
                        title: const Text('启用桌宠'),
                        subtitle: const Text(
                          '悬浮透明窗口显示 Live2D 模型，聊天回复会触发光口型',
                        ),
                        value: _enabled,
                        onChanged: _toggle,
                      ),
                      if (!_hasOverlayPermission)
                        ListTile(
                          leading: Icon(Icons.shield_outlined, color: cs.error),
                          title: const Text('缺少悬浮窗权限'),
                          subtitle: const Text('点击前往系统设置授权「显示在其他应用上层」'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Live2dBridge.openOverlaySettings();
                            Future<void>.delayed(
                              const Duration(seconds: 3),
                              _refreshPermission,
                            );
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 2. 形态与位置调节控制板
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.tune, size: 20, color: cs.primary),
                              const SizedBox(width: 8),
                              const Text(
                                '姿态与位置调节',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.restore, size: 16),
                            label: const Text('重置'),
                            onPressed: _resetTransform,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 大小缩放
                      Row(
                        children: [
                          const Icon(Icons.photo_size_select_large, size: 18),
                          const SizedBox(width: 8),
                          Text('缩放比例: ${(_scale * 100).toInt()}%'),
                          Expanded(
                            child: Slider(
                              value: _scale,
                              min: 0.3,
                              max: 2.2,
                              divisions: 38,
                              onChanged: (v) {
                                setState(() => _scale = v);
                                _syncTransform();
                              },
                              onChangeEnd: (_) => _persistTransform(),
                            ),
                          ),
                        ],
                      ),

                      // 正反翻转
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.flip, size: 20),
                        title: const Text('正反面翻转 (镜像对称)'),
                        subtitle: Text(_flip ? '当前：水平翻转朝向' : '当前：原始正向'),
                        value: _flip,
                        onChanged: (v) {
                          setState(() => _flip = v);
                          _syncTransform();
                          _persistTransform();
                        },
                      ),

                      // 水平位置 (X)
                      Row(
                        children: [
                          const Icon(Icons.swap_horiz, size: 18),
                          const SizedBox(width: 8),
                          Text('左右位置: ${(_posX * 100).toInt()}%'),
                          Expanded(
                            child: Slider(
                              value: _posX,
                              min: 0.0,
                              max: 1.2,
                              divisions: 24,
                              onChanged: (v) {
                                setState(() => _posX = v);
                                _syncTransform();
                              },
                              onChangeEnd: (_) => _persistTransform(),
                            ),
                          ),
                        ],
                      ),

                      // 垂直位置 (Y)
                      Row(
                        children: [
                          const Icon(Icons.swap_vert, size: 18),
                          const SizedBox(width: 8),
                          Text('上下高度: ${(_posY * 100).toInt()}%'),
                          Expanded(
                            child: Slider(
                              value: _posY,
                              min: 0.3,
                              max: 1.2,
                              divisions: 18,
                              onChanged: (v) {
                                setState(() => _posY = v);
                                _syncTransform();
                              },
                              onChangeEnd: (_) => _persistTransform(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 3. 模型选择列表
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '选择模型 (内置 & 本地自定义)',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.6),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '支持 /sdcard/Kelivo/live2d/',
                        style: TextStyle(
                          color: cs.primary.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                ...allModels.map((m) {
                  final path = m['path']!;
                  final selected = path == _modelPath;
                  final isLocal = m['isLocal'] == 'true';

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? cs.primary.withValues(alpha: 0.12)
                          : cs.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _selectModel(m),
                        child: ListTile(
                          leading: Icon(
                            isLocal ? Icons.folder_zip_outlined : Lucide.Bot,
                            color: selected ? cs.primary : cs.onSurface,
                          ),
                          title: Text(
                            m['name'] ?? path,
                            style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: selected ? cs.primary : cs.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            isLocal ? '本地模型: $path' : '内置预装模型',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                          trailing: selected
                              ? Icon(Icons.check_circle, color: cs.primary)
                              : null,
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '提示：可在上方滑块实时无级调节大小和位置；将 Live2D 模型放入 /sdcard/Kelivo/live2d/ 即可自动识别；右上角按钮可重新扫描。',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}