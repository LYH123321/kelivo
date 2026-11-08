import 'package:flutter/services.dart';

/// npu18: bridge to the native Live2D floating pet (Android).
/// The native side (Live2dService.kt) serves bundled pixi-live2d assets on
/// 127.0.0.1:18888 and shows a TYPE_APPLICATION_OVERLAY WebView.
class Live2dBridge {
  static const MethodChannel _ch = MethodChannel('app.live2d');

  /// Bundled models (assets/live2d/models/*).
  static const List<Map<String, String>> models = [
    {
      'id': 'purple_bird',
      'name': 'PurpleBird',
      'path': 'models/PurpleBird/PurpleBird.model3.json',
    },
    {
      'id': 'little_devil',
      'name': '小恶魔',
      'path': 'models/小恶魔.model3.json',
    },
    {
      'id': 'haru',
      'name': 'Haru',
      'path': 'models/Haru/haru_greeter_t03.model3.json',
    },
  ];

  static Future<bool> show({
    String modelPath = 'models/PurpleBird/PurpleBird.model3.json',
  }) async {
    try {
      final r = await _ch.invokeMethod('show', {'model': modelPath});
      return r == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> hide() async {
    try {
      await _ch.invokeMethod('hide');
    } on PlatformException {
    } on MissingPluginException {}
  }

  static Future<bool> isShowing() async {
    try {
      final r = await _ch.invokeMethod('isShowing');
      return r == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Whether the app can show a TYPE_APPLICATION_OVERLAY window.
  static Future<bool> canDrawOverlays() async {
    try {
      final r = await _ch.invokeMethod('canDrawOverlays');
      return r == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Open the system "Display over other apps" settings page for this app.
  static Future<void> openOverlaySettings() async {
    try {
      await _ch.invokeMethod('openOverlaySettings');
    } on PlatformException {
    } on MissingPluginException {}
  }

  /// Make the model lip-sync a chat reply (best effort, fire and forget).
  static Future<void> speak(String text) async {
    try {
      await _ch.invokeMethod('speak', {'text': text});
    } on PlatformException {
    } on MissingPluginException {}
  }
}