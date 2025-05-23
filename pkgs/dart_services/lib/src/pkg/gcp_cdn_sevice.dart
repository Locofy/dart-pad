import 'dart:convert';

import 'package:googleapis/compute/v1.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final Logger _logger = Logger('compiler');

class GCDNService {
  late http.Client _authClient;
  final String _projectId;
  final String _urlMapName;

  GCDNService(this._projectId, this._urlMapName) {
    init();
  }

  Future<void> init() async {
    // Obtain an authenticated HTTP client
    _authClient = await clientViaApplicationDefaultCredentials(
      scopes: [ComputeApi.computeScope],
    );
  }

  Future<void> invalidateCache(String path) async {
    final url = 'https://compute.googleapis.com/compute/v1/projects/$_projectId/global/urlMaps/$_urlMapName/invalidateCache';

    // Prepare the payload
    final body = {
      'path': path,
    };

    // Send the cache invalidation request
    final response = await _authClient.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
     _logger.info('Cache invalidated for $path successfully.');
    } else {
      _logger.severe('Failed to invalidate cache for $path: ${response.body}');
    }
  }
}
