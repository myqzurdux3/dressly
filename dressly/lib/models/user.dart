class AppUser {
  final int id;
  final String email;

  /// Optional name to sign in with instead of the email. Empty when unset.
  final String username;
  final String? createdAt;

  /// The EFFECTIVE answer from the server (database flag or email allowlist),
  /// so the app never reimplements the rule to decide what to show.
  final bool isAdmin;

  AppUser({
    required this.id,
    required this.email,
    this.username = '',
    this.createdAt,
    this.isAdmin = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as int,
      email: json['email'] as String,
      username: (json['username'] ?? '') as String,
      createdAt: json['created_at'] as String?,
      isAdmin: json['is_admin'] == true || json['is_admin'] == 1,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'username': username,
        'created_at': createdAt,
        'is_admin': isAdmin,
      };
}
