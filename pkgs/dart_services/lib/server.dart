// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dartpad_shared/backend_client.dart';
import 'package:dartpad_shared/constants.dart';
import 'package:dartpad_shared/services.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:sentry/sentry.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf;
import 'package:shelf_gzip/shelf_gzip.dart';

import 'src/caching.dart';
import 'src/common_server.dart';
import 'src/context.dart';
import 'src/logging.dart';
import 'src/sdk.dart';

final DartPadLogger _logger = DartPadLogger('services');

Future<void> main(List<String> args) async {
  final parser =
      ArgParser()
        ..addOption('port', valueHelp: 'port', help: 'The port to listen on.')
        ..addOption(
          'redis-url',
          valueHelp: 'url',
          help: 'The redis server url.',
        )
        ..addOption(
          'storage-bucket',
          valueHelp: 'name',
          help:
              'The name of the Cloud Storage bucket for compilation artifacts.',
          defaultsTo: 'nnbd_artifacts',
        )
        ..addFlag(
          'help',
          abbr: 'h',
          negatable: false,
          help: 'Show this usage information.',
        );

  final results = parser.parse(args);
  if (results['help'] as bool) {
    print('dart bin/server.dart <options>\n');
    print(parser.usage);
    exit(0);
  }

  if (!results.wasParsed('redis-url')) {
    print('warning: no redis server specified.\n');
  }

  final sdk = Sdk.fromLocalFlutter();

  final int port;

  // Read port from args; fall back to using an env. variable.
  if (results.wasParsed('port')) {
    port = int.parse(results['port'] as String);
  } else if (Platform.environment['PORT'] case final environmentPath?) {
    port = int.parse(environmentPath);
  } else {
    port = 8080;
  }

  Logger.root.level = Level.FINER;
  emitLogsToStdout();

  final String redisServerUri;
  if (results.wasParsed('redis-url')) {
    redisServerUri = results['redis-url'] as String;
  } else if (Platform.environment.containsKey('REDIS_CONNECTION_URL')) {
    redisServerUri = Platform.environment['REDIS_CONNECTION_URL']!;
  } else {
    redisServerUri = 'redis://localhost:6379';
  }

  final storageBucket =
      results['storage-bucket'] as String? ?? 'nnbd_artifacts';

  final cloudRunEnvVars = Platform.environment.entries
      .where((entry) => entry.key.startsWith('K_'))
      .map((entry) => '${entry.key}:${entry.value}')
      .join(',');

  _logger.genericInfo(
    '''
Starting dart-services:
  port: $port
  sdkPath: ${sdk.dartSdkPath}
  redisServerUri: $redisServerUri
  Cloud Run Environment variables: $cloudRunEnvVars'''.trim(),
  );

  final server = await EndpointsServer.serve(
    port,
    sdk,
    redisServerUri,
    storageBucket,
  );

  // Sentry is used for error tracking.
  final sentryDsn = Platform.environment['SENTRY_DSN'];
  if (sentryDsn != null && sentryDsn.isNotEmpty) {
    await Sentry.init((options) {
      options.dsn = sentryDsn;
      options.environment = Platform.environment['ENVIRONMENT'] ?? 'development';
      // Set tracesSampleRate to 1.0 to capture 100% of transactions for performance monitoring.
      // We recommend adjusting this value in production.
      options.tracesSampleRate = 1.0;
      options.compressPayload = true;
    });
  } else {
    _logger.genericInfo('Sentry DSN not provided. Skipping Sentry initialization.');
  }

  _logger.genericInfo('Listening on port ${server.port}');
}

class EndpointsServer {
  static Future<EndpointsServer> serve(
    int port,
    Sdk sdk,
    String? redisServerUri,
    String storageBucket,
  ) async {
    final endpointsServer = EndpointsServer._(
      sdk,
      redisServerUri,
      storageBucket,
    );
    await endpointsServer._init();

    endpointsServer.server = await shelf.serve(
      endpointsServer.handler,
      InternetAddress.anyIPv4,
      port,
    );

    return endpointsServer;
  }

  late final HttpServer server;

  late final Handler handler;

  late final CommonServerApi commonServer;

  EndpointsServer._(Sdk sdk, String? redisServerUri, String storageBucket) {
    // The name of the Cloud Run revision being run, for more detail please see:
    // https://cloud.google.com/run/docs/reference/container-contract#env-vars
    final serverVersion = Platform.environment['K_REVISION'];

    final cache =
        redisServerUri == null
            ? NoopCache()
            : RedisCache(redisServerUri, sdk, serverVersion);

    commonServer = CommonServerApi(
      CommonServerImpl(sdk, cache, storageBucket: storageBucket),
    );

    final pipeline = const Pipeline()
        .addMiddleware(logRequestsToLogger(_logger))
        .addMiddleware(createCustomCorsHeadersMiddleware())
        .addMiddleware(exceptionResponse())
        .addMiddleware(gzipMiddleware);

    handler = pipeline.addHandler(commonServer.router.call);
  }

  Future<void> _init() => commonServer.init();

  int get port => server.port;

  Future<void> close() async {
    await commonServer.shutdown();
    await server.close();
  }
}

Middleware exceptionResponse() {
  return (Handler handler) {
    return (Request request) async {
      try {
        return await handler(request);
      } catch (e, st) {
        if (e is BadRequest) {
          return Response.badRequest(body: e.message);
        }

        final ctx = DartPadRequestContext.fromRequest(request);

        _logger.severe('${request.requestedUri.path} $e', ctx, null, st);

        return Response.badRequest(body: '$e');
      }
    };
  };
}

@visibleForTesting
class TestServerRunner {
  static const _port = 8080;
  late final DartServicesClient client;
  final sdk = Sdk.fromLocalFlutter();

  Completer<void>? _started;

  /// Starts the server if it is not already running.
  ///
  /// If the port is occupied, assumes the server is already started.
  Future<DartServicesClient> maybeStart() async {
    if (_started != null) {
      await _started!.future;
      return client;
    }

    _started = Completer<void>();
    try {
      await EndpointsServer.serve(_port, sdk, null, 'nnbd_artifacts');
    } on SocketException {
      // This is expected if the server is already running.
    }
    client = DartServicesClient(
      DartServicesHttpClient(),
      rootUrl: 'http://$localhostIp:$_port/',
    );
    _started!.complete();
    return client;
  }
}
