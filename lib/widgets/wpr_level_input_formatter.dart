import 'package:flutter/services.dart';

/// Custom input formatter for WPR (Williams %R) levels
/// Ensures minus sign at start and only digits after
class WprLevelInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String newText = newValue.text;

    // Remove all non-digit characters
    String digitsOnly = newText.replaceAll(RegExp(r'[^0-9]'), '');

    // If trying to delete the minus sign from a non-empty field, prevent it
    if (oldValue.text.startsWith('-') &&
        newText.isNotEmpty &&
        !newText.startsWith('-')) {
      // Restore the old value if user is trying to delete the minus
      return oldValue;
    }

    // Always prepend minus if there are digits
    if (digitsOnly.isNotEmpty) {
      newText = '-$digitsOnly';
    } else {
      // If empty, keep minus sign if it was there before
      newText = oldValue.text.startsWith('-') ? '-' : '';
    }

    // Calculate cursor position
    int cursorPosition = newValue.selection.baseOffset;

    // Adjust cursor if it's before or at the minus sign position (position 0)
    if (newText.startsWith('-')) {
      if (cursorPosition <= 0) {
        // If cursor is before or at minus, move it after minus
        cursorPosition = 1;
      } else if (cursorPosition > newText.length) {
        cursorPosition = newText.length;
      }
    } else {
      if (cursorPosition > newText.length) {
        cursorPosition = newText.length;
      }
    }

    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursorPosition),
    );
  }
}
