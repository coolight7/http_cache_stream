import 'dart:io';

extension FileExtensions on File {
  ///Returns the length of the file, or null if the file does not exist.
  int? lengthSyncOrNull() {
    try {
      return lengthSync();
    } on FileSystemException {
      return null;
    }
  }
}
