import 'package:equatable/equatable.dart';

class UserProfile extends Equatable {
  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    this.cognitoSub,
    this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final String? cognitoSub;
  final DateTime? createdAt;

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
    id: j['id'] as String,
    name: j['name'] as String,
    email: j['email'] as String,
    cognitoSub: j['cognito_sub'] as String?,
    createdAt: j['created_at'] == null
        ? null
        : DateTime.parse(j['created_at'] as String),
  );

  @override
  List<Object?> get props => [id, name, email, cognitoSub, createdAt];
}
