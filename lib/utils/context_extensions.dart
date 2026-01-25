import 'package:flutter/material.dart';
import 'snackbar_helper.dart';

/// Extension methods for BuildContext
extension ContextExtensions on BuildContext {
  /// Show error message
  void showError(String message) {
    SnackBarHelper.showError(this, message);
  }

  /// Show success message
  void showSuccess(String message) {
    SnackBarHelper.showSuccess(this, message);
  }

  /// Show info message
  void showInfo(String message) {
    SnackBarHelper.showInfo(this, message);
  }

  /// Show loading indicator
  void showLoading(String message) {
    SnackBarHelper.showLoading(this, message);
  }

  /// Hide current SnackBar
  void hideSnackBar() {
    SnackBarHelper.hide(this);
  }
}
