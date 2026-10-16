import 'package:equatable/equatable.dart';

import '../../models/user_profile.dart';

sealed class SessionState extends Equatable {
  const SessionState();
  @override
  List<Object?> get props => [];
}

class SessionUnknown extends SessionState {
  const SessionUnknown();
}

class SessionAuthenticated extends SessionState {
  const SessionAuthenticated(this.user);
  final UserProfile user;
  @override
  List<Object?> get props => [user];
}

class SessionUnauthenticated extends SessionState {
  const SessionUnauthenticated({this.message});
  final String? message;
  @override
  List<Object?> get props => [message];
}

class SessionUnavailable extends SessionState {
  const SessionUnavailable(this.message);
  final String message;
  @override
  List<Object?> get props => [message];
}
