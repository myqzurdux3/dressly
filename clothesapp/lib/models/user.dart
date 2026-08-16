class AppUser {
  final int id;
  final String email;
  final String? createdAt;

  /// The EFFECTIVE answer from the server (database flag or email allowlist),
  /// so the app never reimplements the rule to decide what to show.
  final bool isAdmin;

  AppUser({
    required this.id,
    required this.email,
    this.createdAt,
    this.isAdmin = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as int,
      email: json['email'] as String,
      createdAt: json['created_at'] as String?,
      isAdmin: json['is_admin'] == true || json['is_admin'] == 1,
    );
  }
}