// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bazel_worker/driver.dart';
import 'package:dartpad_shared/model.dart';
import 'package:googleapis/storage/v1.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:sentry/sentry.dart';
import 'package:uuid/uuid.dart';

import 'caching.dart';
import 'common.dart';
import 'common_server.dart';
import 'context.dart';
import 'pkg/gcp_cdn_sevice.dart';
import 'pkg/gcs_service.dart';
import 'project_templates.dart';
import 'pub.dart';
import 'sdk.dart';

final Logger _logger = Logger('compiler');

final uuid = const Uuid();

/// An interface to the dart2js compiler. A compiler object can process one
/// compile at a time.
class Compiler {
  final Sdk _sdk;
  final String _dartPath;
  final BazelWorkerDriver _ddcDriver;
  final String _storageBucket;

  final ProjectTemplates _projectTemplates;

  final String _gcsCDNBucket =
      Platform.environment['GCS_CDN_BUCKET'] ?? 'gcs-cdn-dev';
  late final GCSService _gcsService;
  late final GCDNService _gCDNService;
  late final ServerCache _cache;

  static const flutterBuildResultDirectory = 'flutter-build';
  static const flutterBuildCacheKeyTemplate = 'flutter-build:%s';
  static final flutterBuildCacheExpiration = Duration(
    seconds:
        Platform.environment.containsKey(
          'FLUTTER_BUILD_CACHE_EXPIRATION_IN_SECONDS',
        )
        ? int.parse(
            Platform.environment['FLUTTER_BUILD_CACHE_EXPIRATION_IN_SECONDS']!,
          )
        : 86400, // default to 24 hours
  );
  static final flutterCDNBaseUrl =
      Platform.environment['GCS_CDN_BASE_URL'] ??
      'https://storage.googleapis.com/gcs-cdn-dev';
  static final gCDNProjectId =
      Platform.environment['GCS_CDN_PROJECT_ID'] ?? 'lightning-dev-423309';
  static final gCDNURLMapName =
      Platform.environment['GCS_CDN_URL_MAP_NAME'] ?? 'cdn-lb';

  Compiler(
      Sdk sdk, ServerCache cache, {
        required String storageBucket,
      }) : this._(sdk,
      path.join(sdk.dartSdkPath, 'bin', 'dart'),
      storageBucket,
      GCSService(),
      GCDNService(gCDNProjectId, gCDNURLMapName),
      cache
  );

  Compiler._(this._sdk, this._dartPath, this._storageBucket, this._gcsService, this._gCDNService, this._cache)
      : _ddcDriver = BazelWorkerDriver(
          () => Process.start(_dartPath, [
        path.join(_sdk.dartSdkPath, 'bin', 'snapshots',
            'dartdevc.dart.snapshot'),
        '--persistent_worker'
      ]),
      maxWorkers: 1),
        _projectTemplates = ProjectTemplates.instance;

  /// Compile the given string and return the resulting [CompilationResults].
  Future<CompilationResults> compile(
    String source,
    DartPadRequestContext ctx, {
    bool returnSourceMap = false,
  }) async {
    final temp = Directory.systemTemp.createTempSync('dartpad');
    _logger.fine('Temp directory created: ${temp.path}', ctx);

    try {
      _copyPath(_projectTemplates.dartPath, temp.path);
      Directory(path.join(temp.path, 'lib')).createSync(recursive: true);

      final arguments = <String>[
        'compile',
        'js',
        '--suppress-hints',
        '--terse',
        if (!returnSourceMap) '--no-source-maps',
        '--packages=${path.join('.dart_tool', 'package_config.json')}',
        '--enable-asserts',
        if (_sdk.experiments.isNotEmpty)
          '--enable-experiment=${_sdk.experiments.join(",")}',
        '-o',
        '$kMainDart.js',
        path.join('lib', kMainDart),
      ];

      File(path.join(temp.path, 'lib', kMainDart)).writeAsStringSync(source);

      final mainJs = File(path.join(temp.path, '$kMainDart.js'));
      final mainSourceMap = File(path.join(temp.path, '$kMainDart.js.map'));

      _logger.fine('About to exec: $_dartPath ${arguments.join(' ')}', ctx);

      final result = await Process.run(
        _dartPath,
        arguments,
        workingDirectory: temp.path,
      );

      if (result.exitCode != 0) {
        final results = CompilationResults(
          problems: <CompilationProblem>[
            CompilationProblem._(result.stdout as String),
          ],
        );
        return results;
      } else {
        String? sourceMap;
        if (returnSourceMap && mainSourceMap.existsSync()) {
          sourceMap = mainSourceMap.readAsStringSync();
        }
        final results = CompilationResults(
          compiledJS: mainJs.readAsStringSync(),
          sourceMap: sourceMap,
        );
        return results;
      }
    } catch (e, st) {
      _logger.warning('Compiler failed: $e\n$st', ctx);
      rethrow;
    } finally {
      temp.deleteSync(recursive: true);
      _logger.fine('temp folder removed: ${temp.path}', ctx);
    }
  }

  /// Compile the given string and return the resulting [DDCCompilationResults].
  ///
  /// [useNew] determines whether or not to use the hot reload enabled module
  /// system for DDC. When [useNew] is true, a null [deltaDill] will result in
  /// a hot restart and a non-null [deltaDill] will result in a hot reload. If
  /// [useNew] is false, the result will always be a hot restart.
  Future<DDCCompilationResults> _compileDDC(
    String source,
    DartPadRequestContext ctx, {
    String? deltaDill,
    required bool useNew,
  }) async {
    final imports = getAllImportsFor(source);

    final temp = Directory.systemTemp.createTempSync('dartpad');
    _logger.fine('Temp directory created: ${temp.path}', ctx);

    try {
      final usingFlutter = usesFlutterWeb(imports);
      if (usingFlutter) {
        _copyPath(_projectTemplates.flutterPath, temp.path);
      } else {
        _copyPath(_projectTemplates.dartPath, temp.path);
      }

      Directory(path.join(temp.path, 'lib')).createSync(recursive: true);

      final mainPath = path.join(temp.path, 'lib', kMainDart);
      File(mainPath).writeAsStringSync(source);

      String compilePath;
      if (useNew && deltaDill != null) {
        // Hot reloads should not recompile the bootstrap library.
        compilePath = mainPath;
      } else {
        // All hot restart (or initial compile) requests should include the
        // bootstrap library.
        final bootstrapPath = path.join(temp.path, 'lib', kBootstrapDart);
        final bootstrapContents = usingFlutter
            ? kBootstrapFlutterCode
            : kBootstrapDartCode;

        File(bootstrapPath).writeAsStringSync(bootstrapContents);
        compilePath = bootstrapPath;
      }
      final newDeltaKernelPath = path.join(temp.path, 'new_kernel.dill');
      String? oldDillPath;
      if (deltaDill != null) {
        final oldDillBytes = base64Decode(deltaDill);
        oldDillPath = path.join(temp.path, 'old_kernel.dill');
        File(oldDillPath)
          ..createSync()
          ..writeAsBytesSync(oldDillBytes);
      }

      final mainJsPath = path.join(temp.path, '$kMainDart.js');

      // Later versions of Flutter remove the "sound" suffix from the file. If
      // the suffixed version does not exist, the unsuffixed version is the
      // sound file.
      var ddcOutlinePath = '${_sdk.flutterWebSdkPath}/ddc_outline_sound.dill';
      if (!File(ddcOutlinePath).existsSync()) {
        ddcOutlinePath = '${_sdk.flutterWebSdkPath}/ddc_outline.dill';
      }

      final arguments = <String>[
        if (useNew) ...[
          '--modules=ddc',
          '--canary',
          '--reload-delta-kernel=$newDeltaKernelPath',
          if (oldDillPath != null) '--reload-last-accepted-kernel=$oldDillPath',
        ],
        if (!useNew) ...['--modules=amd', '--module-name=dartpad_main'],
        '--no-summarize',
        if (usingFlutter) ...[
          '-s',
          _projectTemplates.summaryFilePath,
          '-s',
          ddcOutlinePath,
        ],
        ...['-o', mainJsPath],
        '--enable-asserts',
        if (_sdk.experiments.isNotEmpty)
          '--enable-experiment=${_sdk.experiments.join(",")}',
        compilePath,
        '--packages=${path.join(temp.path, '.dart_tool', 'package_config.json')}',
      ];

      _logger.fine(
        'About to exec dartdevc worker: ${arguments.join(' ')}"',
        ctx,
      );

      final response = await _ddcDriver.doWork(
        WorkRequest(arguments: arguments),
      );
      if (response.exitCode != 0) {
        return DDCCompilationResults.failed([
          CompilationProblem._(_rewritePaths(response.output)),
        ]);
      } else {
        final mainJs = File(mainJsPath);
        final newDeltaDill = File(newDeltaKernelPath);

        var compiledJs = mainJs.readAsStringSync();

        if (!useNew) {
          // The `--single-out-file` option for dartdevc was removed in v2.7.0. As
          // a result, the JS code produced above does *not* provide a name for
          // the module it contains. That's a problem for DartPad, since it's
          // adding the code to a script tag in an iframe rather than loading it
          // as an individual file from baseURL. As a workaround, this replace
          // statement injects a name into the module definition.
          compiledJs = compiledJs.replaceFirst(
            'define([',
            "define('dartpad_main', [",
          );
        }

        final results = DDCCompilationResults(
          compiledJS: compiledJs,
          deltaDill: useNew
              ? base64Encode(newDeltaDill.readAsBytesSync())
              : null,
          modulesBaseUrl:
              'https://storage.googleapis.com/$_storageBucket'
              '/${_sdk.dartVersion}/',
        );
        return results;
      }
    } catch (e, st) {
      _logger.warning('Compiler failed: $e\n$st', ctx);
      rethrow;
    } finally {
      temp.deleteSync(recursive: true);
      _logger.fine('temp folder removed: ${temp.path}', ctx);
    }
  }

  Future<DDCCompilationResults> compileDDC(
    String source,
    DartPadRequestContext ctx,
  ) async {
    return await _compileDDC(source, ctx, useNew: false);
  }

  Future<DDCCompilationResults> compileNewDDC(
    String source,
    DartPadRequestContext ctx,
  ) async {
    return await _compileDDC(source, ctx, useNew: true);
  }

  Future<DDCCompilationResults> compileNewDDCReload(
    String source,
    String deltaDill,
    DartPadRequestContext ctx,
  ) async {
    return await _compileDDC(source, ctx, deltaDill: deltaDill, useNew: true);
  }

  /// Compile the given string and return the resulting [BuildCodeResponse].
  Future<String> build(String requestId, BuildCodeRequest request) async {
    // make a GET request to the URL
    // to check if the file exists and is accessible
    final getFileResponse = await http.get(Uri.parse(request.sourceFileUrl));
    if (getFileResponse.statusCode != 200) {
      _logger.warning({
        'request_id': requestId,
        'message': 'Failed to download file',
        'status_code': getFileResponse.statusCode,
        'response_body': getFileResponse.body.toString(),
      });

      throw BadRequest(
        'Failed to download file: ${getFileResponse.statusCode}',
      );
    }

    // generate random string for buildId
    final buildId = uuid.v1().replaceAll('-', '');
    _logger.info({
      'request_id': requestId,
      'project_id': request.projectId,
      'page_id': request.pageId,
      'screen_id': request.screenId,
      'node_id': request.nodeId,
      'source_file_url': request.sourceFileUrl,
      'build_id': buildId,
      'message': 'Received request to build flutter code to JS',
    });

    // set request to cache
    final requestJSON = request.toJson();
    requestJSON.addEntries([MapEntry('buildId', buildId)]);
    requestJSON.addEntries([const MapEntry('status', 'processing')]);
    await _cache.set(
      _getBuildCacheKey(buildId),
      jsonEncode(requestJSON),
      expiration: flutterBuildCacheExpiration,
    );

    // perform build in background
    unawaited(_performBuild(requestId, getFileResponse, request, buildId));

    // return buildId to client
    return buildId;
  }

  /// Method to perform the actual build
  Future<void> _performBuild(
    String requestId,
    http.Response getFileResponse,
    BuildCodeRequest request,
    String buildId,
  ) async {
    // Read data from cache
    var cachedDataStr = await _cache.get(_getBuildCacheKey(buildId));
    if (cachedDataStr == null) {
      _logger.warning({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Cache data not found for buildId',
      });
      cachedDataStr = request.toJson().toString();
    }

    final cachedData = jsonDecode(cachedDataStr) as Map<String, dynamic>;
    final temp = Directory.systemTemp.createTempSync('dartpad');
    _logger.info({
      'request_id': requestId,
      'build_id': buildId,
      'path': temp.path,
      'message': 'Temp directory created',
    });
    try {
      final source = getFileResponse.body;
      final imports = getAllImportsFor(source);
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Got all imports for source code',
        'imports': imports.toString(),
      });

      final usingFlutter = usesFlutterWeb(imports);
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Detected usingFlutter',
        'using_flutter': usingFlutter,
      });

      if (usingFlutter) {
        _copyPath(_projectTemplates.flutterPath, temp.path);
      } else {
        _copyPath(_projectTemplates.dartPath, temp.path);
      }

      Directory(path.join(temp.path, 'lib')).createSync(recursive: true);
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Copied project templates to temp directory',
        'path': path.join(temp.path, 'lib'),
      });

      final bootstrapPath = path.join(temp.path, 'lib', kBootstrapDart);
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'About to write bootstrap file',
        'path': bootstrapPath,
      });

      final bootstrapContents = usingFlutter
          ? kBootstrapFlutterCode
          : kBootstrapDartCode;
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Bootstrap contents',
        'contents': bootstrapContents,
      });

      File(bootstrapPath).writeAsStringSync(bootstrapContents);
      File(path.join(temp.path, 'lib', kMainDart)).writeAsStringSync(source);
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Wrote main.dart file',
        'path': path.join(temp.path, 'lib', kMainDart),
      });

      final arguments = <String>[
        '--modules=amd',
        '--no-summarize',
        if (usingFlutter) ...[
          '-s',
          _projectTemplates.summaryFilePath,
          '-s',
          '${_sdk.flutterWebSdkPath}/ddc_outline_sound.dill',
        ],
        ...['-o', path.join(temp.path, '$kMainDart.js')],
        ...['--module-name', 'dartpad_main'],
        '--enable-asserts',
        if (_sdk.experiments.isNotEmpty)
          '--enable-experiment=${_sdk.experiments.join(",")}',
        bootstrapPath,
        '--packages=${path.join(temp.path, '.dart_tool', 'package_config.json')}',
      ];

      final mainJs = File(path.join(temp.path, '$kMainDart.js'));
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'About to exec dartdevc worker',
        'arguments': arguments.join(' '),
      });

      final response = await _ddcDriver.doWork(
        WorkRequest(arguments: arguments),
      );

      if (response.exitCode != 0) {
        throw Exception(_rewritePaths(response.output));
      }

      // The `--single-out-file` option for dartdevc was removed in v2.7.0. As
      // a result, the JS code produced above does *not* provide a name for
      // the module it contains. That's a problem for DartPad, since it's
      // adding the code to a script tag in an iframe rather than loading it
      // as an individual file from baseURL. As a workaround, this replace
      // statement injects a name into the module definition.
      final processedJs = mainJs.readAsStringSync().replaceFirst(
        'define([',
        "define('dartpad_main', [",
      );

      // Upload processedJs to GCS with content type 'application/javascript'
      final media = Media(
        Stream.fromIterable([processedJs.codeUnits]),
        processedJs.length,
        contentType: 'application/javascript',
      );

      final key = path.joinAll([
        flutterBuildResultDirectory,
        request.projectId,
        request.pageId,
        request.screenId,
        request.nodeId ?? '',
        '$kMainDart.js',
      ]);
      await _gcsService.upload(_gcsCDNBucket, media, key);
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Uploaded processed JS to GCS',
        'key': key,
      });

      // TODO: Invalidate CDN cache
      await _gCDNService.invalidateCache('/$key');

      final files = <Map<String, dynamic>>[];
      files.add(<String, dynamic>{
        'name': 'main.dart.js',
        'cdnUrl': '$flutterCDNBaseUrl/$key',
      });

      // Set build result to cache
      cachedData['status'] = 'completed';
      cachedData['files'] = files;
      await _cache.set(
        _getBuildCacheKey(buildId),
        jsonEncode(cachedData),
        expiration: flutterBuildCacheExpiration,
      );
      _logger.info({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Build process completed',
      });
    } catch (e, st) {
      _logger.warning({
        'request_id': requestId,
        'build_id': buildId,
        'message': 'Build flutter code to JS failed',
        'error': e.toString(),
        'stack_trace': st.toString(),
      });

      // Set failed status and error message to cache
      cachedData['status'] = 'failed';
      cachedData['error'] = e.toString();
      await _cache.set(
        _getBuildCacheKey(buildId),
        jsonEncode(cachedData),
        expiration: flutterBuildCacheExpiration,
      );

      unawaited(
        Sentry.captureEvent(
          SentryEvent(
            message: const SentryMessage('Build flutter code to JS failed'),
            tags: {
              'request_id': requestId,
              'build_id': buildId,
              'error': e.toString(),
              'stack_trace': st.toString(),
            },
          ),
        ),
      );

      rethrow;
    } finally {
      temp.deleteSync(recursive: true);
      _logger.fine('Temp folder removed: ${temp.path}');
    }
  }

  /// Get the status of a build based on the provided buildId.
  Future<Map<String, dynamic>?> getBuild(String buildId) async {
    // Retrieve cached data using the buildId
    final cachedDataStr = await _cache.get(_getBuildCacheKey(buildId));
    if (cachedDataStr == null) {
      _logger.warning('Cache data not found for buildId: $buildId');
      return null;
    }

    final cachedData = jsonDecode(cachedDataStr) as Map<String, dynamic>;
    return cachedData;
  }

  String _getBuildCacheKey(String buildId) {
    return flutterBuildCacheKeyTemplate.replaceAll('%s', buildId);
  }

  Future<void> dispose() async {
    return _ddcDriver.terminateWorkers();
  }
}

/// The result of a dart2js compile.
class CompilationResults {
  final String? compiledJS;
  final String? sourceMap;
  final List<CompilationProblem> problems;

  CompilationResults({
    this.compiledJS,
    this.problems = const <CompilationProblem>[],
    this.sourceMap,
  });

  bool get hasOutput => compiledJS != null && compiledJS!.isNotEmpty;

  /// This is true if there were no errors.
  bool get success => problems.isEmpty;

  @override
  String toString() => success
      ? 'CompilationResults: Success'
      : 'Compilation errors: ${problems.join('\n')}';
}

/// The result of a DDC compile.
class DDCCompilationResults {
  final String? compiledJS;
  final String? deltaDill;
  final String? modulesBaseUrl;
  final List<CompilationProblem> problems;

  DDCCompilationResults({this.compiledJS, this.deltaDill, this.modulesBaseUrl})
    : problems = const <CompilationProblem>[];

  const DDCCompilationResults.failed(this.problems)
    : compiledJS = null,
      deltaDill = null,
      modulesBaseUrl = null;

  bool get hasOutput => compiledJS != null && compiledJS!.isNotEmpty;

  /// This is true if there were no errors.
  bool get success => problems.isEmpty;

  @override
  String toString() => success
      ? 'CompilationResults: Success'
      : 'Compilation errors: ${problems.join('\n')}';
}

/// An issue associated with [CompilationResults].
class CompilationProblem implements Comparable<CompilationProblem> {
  final String message;

  const CompilationProblem._(this.message);

  @override
  int compareTo(CompilationProblem other) => message.compareTo(other.message);

  @override
  String toString() => message;
}

/// Copies all of the files in the [from] directory to [to].
///
/// This is similar to `cp -R <from> <to>`:
/// * Symlinks are supported.
/// * Existing files are over-written, if any.
/// * If [to] is within [from], throws [ArgumentError] (an infinite operation).
/// * If [from] and [to] are canonically the same, no operation occurs.
///
/// Returns a future that completes when complete.
void _copyPath(String from, String to) {
  if (_doNothing(from, to)) {
    return;
  }

  Directory(to).createSync(recursive: true);
  for (final file in Directory(from).listSync(recursive: true)) {
    final copyTo = path.join(to, path.relative(file.path, from: from));
    if (file is Directory) {
      Directory(copyTo).createSync(recursive: true);
    } else if (file is File) {
      File(file.path).copySync(copyTo);
    } else if (file is Link) {
      Link(copyTo).createSync(file.targetSync(), recursive: true);
    }
  }
}

bool _doNothing(String from, String to) {
  if (path.canonicalize(from) == path.canonicalize(to)) {
    return true;
  }
  if (path.isWithin(from, to)) {
    throw ArgumentError('Cannot copy from $from to $to');
  }
  return false;
}

/// Remove any references to 'bootstrap.dart' and replace with referenced to
/// 'main.dart'.
String _rewritePaths(String output) {
  final lines = output.split('\n');

  return lines
      .map((line) {
        const token1 = 'lib/bootstrap.dart:';
        var index = line.indexOf(token1);
        if (index != -1) {
          return 'main.dart:${line.substring(index + token1.length)}';
        }

        const token2 = 'lib/main.dart:';
        index = line.indexOf(token2);
        if (index != -1) {
          return 'main.dart:${line.substring(index + token2.length)}';
        }

        return line;
      })
      .join('\n');
}
