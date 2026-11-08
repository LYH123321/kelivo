import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
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

  bool _loading = true;
  bool _enabled = false;
  String _modelPath = Live2dBridge.models.first['path']!;
  bool _hasOverlayPermission = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    String modelPath = Live2dBridge.models.first['path']!;
    try {
      final prefs = await SharedPreferences.getInstance();
      modelPath = prefs.getString(_kModelKey) ?? modelPath;
    } catch (_) {}
    final showing = await Live2dBridge.isShowing();
    final canDraw = await Live2dBridge.canDrawOverlays();
    if (!mounted) return;
    setState(() {
      _modelPath = modelPath;
      _enabled = showing;
      _hasOverlayPermission = canDraw;
      _loading = false;
    });
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
      if (!ok) {
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
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('切换模型失败，请重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Live2D 桌宠')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
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
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    '选择模型',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ...Live2dBridge.models.map((m) {
                  final path = m['path']!;
                  final selected = path == _modelPath;
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
                            Lucide.Bot,
                            color: selected ? cs.primary : cs.onSurface,
                          ),
                          title: Text(
                            m['name'] ?? path,
                            style: TextStyle(
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color:
                                  selected ? cs.primary : cs.onSurface,
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
                    '提示：桌宠悬浮窗不可点击、不挡操作；聊天收到回复时模型会张嘴「说话」。切换模型立即生效。',
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
