class AppUser {
  final int id;
  final String email;
  final String? createdAt;

  AppUser({required this.id, required this.email, this.createdAt});

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as int,
      email: json['email'] as String,
      createdAt: json['created_at'] as String?,
    );
  }
}