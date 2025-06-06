// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

bool get isNonMac => defaultTargetPlatform != TargetPlatform.macOS;
bool get isMac => defaultTargetPlatform == TargetPlatform.macOS;

String pluralize(String word, int count) {
  return count == 1 ? word : '${word}s';
}

String titleCase(String phrase) {
  return phrase.substring(0, 1).toUpperCase() + phrase.substring(1);
}

bool hasFlutterImports(List<String> imports) {
  return imports.any((import) => import.startsWith('package:flutter/'));
}

bool hasPackageWebImport(List<String> imports) {
  return imports.any((import) => import.startsWith('package:web/'));
}

extension ColorExtension on Color {
  Color get lighter {
    final hsl = HSLColor.fromColor(this);
    return hsl.withLightness((hsl.lightness + 0.1).clamp(0.0, 1.0)).toColor();
  }

  Color get darker {
    final hsl = HSLColor.fromColor(this);
    return hsl.withLightness((hsl.lightness - 0.1).clamp(0.0, 1.0)).toColor();
  }
}

/// Support a stack of status messages.
///
/// Fires a notification when the top-most status changes.
class StatusController {
  final List<Message> messages = [];

  void showToast(
    String toastMessage, {
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    final message = Message._(this, toastMessage);
    messages.add(message);

    // Create in a 'opening' state.
    _recalcStateValue();

    // Transition to a 'showing' state.
    Timer(animationDelay, () {
      _updateMessageState(message, MessageState.showing);
    });

    // Finally, start the 'closing' animation.
    Timer(duration, message.close);
  }

  Message showMessage({required String initialText, String? name}) {
    final message = Message._(this, initialText, name: name);
    messages.add(message);
    _recalcStateValue();
    return message;
  }

  final ValueNotifier<MessageStatus> _state = ValueNotifier(
    MessageStatus.empty,
  );

  ValueListenable<MessageStatus> get state => _state;

  Message? getNamedMessage(String name) {
    return messages.firstWhereOrNull((message) {
      return message.name == name && message.state != MessageState.closing;
    });
  }

  void _recalcStateValue() {
    if (messages.isEmpty) {
      _state.value = MessageStatus.empty;
    } else {
      final value = messages.last;
      _state.value = MessageStatus(message: value.message, state: value.state);
    }
  }

  void _close(Message message) {
    _updateMessageState(message, MessageState.closing);

    Timer(animationDelay, () {
      messages.remove(message);
      _recalcStateValue();
    });
  }

  void _updateMessageState(Message message, MessageState state) {
    message._state = state;
    _recalcStateValue();
  }
}

class Message {
  final StatusController _parent;
  final String? name;

  String _message;
  MessageState _state = MessageState.opening;

  Message._(StatusController parent, String message, {this.name})
    : _parent = parent,
      _message = message;

  MessageState get state => _state;

  String get message => _message;

  void updateText(String newMessage) {
    _message = newMessage;
    _parent._recalcStateValue();
  }

  void close() => _parent._close(this);
}

class MessageStatus {
  static final MessageStatus empty = MessageStatus(
    message: '',
    state: MessageState.closing,
  );

  final String message;
  final MessageState state;

  MessageStatus({required this.message, required this.state});

  @override
  bool operator ==(Object other) {
    if (other is! MessageStatus) return false;
    return message == other.message && state == other.state;
  }

  @override
  int get hashCode => message.hashCode;

  @override
  String toString() => '[$state] $message';
}

enum MessageState { opening, showing, closing }

extension StringUtils on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

extension TextEditingControllerExtensions on TextEditingController {
  // set the source w/o scrolling to the top
  set textNoScroll(String text) {
    value = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 0),
    );
  }
}
