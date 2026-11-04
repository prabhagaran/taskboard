/// Connection details from the QR code on the website's settings screen.
class SetupLink {
  const SetupLink({required this.url, required this.token});

  final String url;
  final String token;

  /// Returns null unless [text] is a TaskBoard setup link.
  static SetupLink? parse(String text) {
    final match = RegExp(r'#connect=([\w-]{20,120})\.([\w-]{16,128})$').firstMatch(text.trim());
    if (match == null) return null;
    return SetupLink(
      url: 'https://script.google.com/macros/s/${match[1]}/exec',
      token: match[2]!,
    );
  }
}
