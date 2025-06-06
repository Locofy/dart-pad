// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';

import 'package:logging/logging.dart';

import 'context.dart';

const bool verboseLogging = false;

final _wsRegex = RegExp(r' \s+');

void emitLogsToStdout() {
  Logger.root.onRecord.listen((LogRecord record) {
    if (verboseLogging || record.level >= Level.INFO) {
      final String stackTrace;
      if (record.stackTrace case final recordStackTrace?) {
        final lines = recordStackTrace
            .toString()
            .split('\n')
            .take(5)
            .join(' ')
            .replaceAll(_wsRegex, ' ');
        stackTrace = ' $lines';
      } else {
        stackTrace = '';
      }

      // Check if the message is already a Map
      Map<String, dynamic>? messageJson;
      if (record.object != null) {
        messageJson = record.object as Map<String, dynamic>;
      } else {
        messageJson = {'message': record.message};
      }

      final log = {
        'timestamp': record.time.toIso8601String(),
        'level': record.level.name,
        'logger': record.loggerName,
        ...messageJson, // Merge the JSON fields
      };
      if (record.error != null) {
        log['error'] = record.error.toString();
      }
      if (stackTrace.isNotEmpty) {
        log['stackTrace'] = stackTrace;
      }

      print(jsonEncode(log));
    }
  });
}

class DartPadLogger {
  final Logger logger;

  DartPadLogger(String name) : logger = Logger(name);

  void fine(String s, DartPadRequestContext ctx) {
    if (ctx.enableLogging) {
      logger.fine(s);
    }
  }

  /// Logs a generic fine message that doesn't relate to a request.
  void genericFine(String s) {
    logger.fine(s);
  }

  void info(String s, DartPadRequestContext ctx) {
    if (ctx.enableLogging) {
      logger.info(s);
    }
  }

  /// Logs a generic info message that doesn't relate to a request.
  void genericInfo(String s) {
    logger.info(s);
  }

  void warning(
    String s,
    DartPadRequestContext ctx, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (ctx.enableLogging) {
      logger.warning(s, error, stackTrace);
    }
  }

  /// Logs a generic warning message that doesn't relate to a request.
  void genericWarning(String s) {
    logger.warning(s);
  }

  void severe(
    String s,
    DartPadRequestContext ctx, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (ctx.enableLogging) {
      logger.severe(s, error, stackTrace);
    }
  }

  /// Logs a generic severe message that doesn't relate to a request.
  void genericSevere(String s, {Object? error, StackTrace? stackTrace}) {
    logger.severe(s, error, stackTrace);
  }
}
