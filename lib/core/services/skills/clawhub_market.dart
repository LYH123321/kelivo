import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Client for the public ClawHub registry (https://clawhub.com).
/// Used by the in-app plugin marketplace.
class ClawHubPackage {
  final String name;
  final String ownerHandle;
  final String summary;
  final int downloads;
  final bool featured;
  const ClawHubPackage({
    required this.name,
    required this.ownerHandle,
    required this.summary,
    required this.downloads,
    required this.featured,
  });

  String get reference => '$ownerHandle/$name';
}

class ClawHubClient {
  ClawHubClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const _base = 'https://clawhub.com/api/v1';

  Future<List<ClawHubPackage>> search(
    String query, {
    int limit = 30,
  }) async {
    final uri = Uri.parse(
      '$_base/search?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
    );
    final resp = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('ClawHub search failed: HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final results = decoded is Map ? decoded['results'] : decoded;
    if (results is! List) return const [];
    final out = <ClawHubPackage>[];
    for (final item in results) {
      if (item is! Map) continue;
      final install = item['install'];
      final reference = install is Map ? (install['reference'] ?? '') : '';
      final parts = reference.toString().split('/');
      if (parts.length < 2) continue;
      final native = item['native'];
      final skill = native is Map ? native['skill'] : null;
      out.add(
        ClawHubPackage(
          name: parts.last,
          ownerHandle: parts[0],
          summary: (skill is Map ? (skill['summary'] ?? '') : '')
              .toString(),
          downloads: item['downloads'] is num
              ? (item['downloads'] as num).toInt()
              : 0,
          featured: item['featured'] == true,
        ),
      );
    }
    return out;
  }

  /// Downloads the install zip for a package and returns the local file.
  Future<File> downloadZip(
    String ownerHandle,
    String slug, {
    String? version,
    void Function(int received, int? total)? onProgress,
  }) async {
    final params = <String, String>{'slug': slug, 'ownerHandle': ownerHandle};
    if (version != null && version.isNotEmpty) {
      params['version'] = version;
    }
    final uri = Uri.parse('$_base/download').replace(
      queryParameters: params,
    );
    final request = http.Request('GET', uri);
    final response = await _client.send(request).timeout(
      const Duration(minutes: 2),
    );
    if (response.statusCode != 200) {
      throw Exception('ClawHub download failed: HTTP ${response.statusCode}');
    }
    final tmp = await Directory.systemTemp.createTemp('clawhub-');
    final file = File('${tmp.path}/$slug.zip');
    final sink = file.openWrite();
    var received = 0;
    await response.stream.forEach((chunk) {
      received += chunk.length;
      onProgress?.call(received, response.contentLength);
      sink.add(chunk);
    });
    await sink.flush();
    await sink.close();
    return file;
  }

  void dispose() {
    _client.close();
  }
}
