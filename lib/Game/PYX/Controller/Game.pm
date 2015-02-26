package Game::PYX::Controller::Game;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::IOLoop;
use Mojo::JSON qw/decode_json encode_json false true/;
use Mojo::Util 'md5_sum';
use Scalar::Util 'weaken';

sub page {
	my $self = shift;
	my $userid = $self->session->{userid};
	unless (defined $userid and $self->user_exists($userid)) { # New user
		$userid = md5_sum $self->tx->remote_address . '$' . rand . '$' . time;
		$self->set_user_exists($userid);
		$self->session->{userid} = $userid;
	}
	$self->session(expiration => 31536000); # approx 1 year
	$self->render;
}

sub connect {
	my $self = shift;
	$self->finish(1011 => 'User session not found')
		unless my $userid = $self->session->{userid};
	$self->stash->{userid} = $userid;
	
	$self->app->log->debug('WebSocket opened');
	$self->inactivity_timeout(30);
	
	$self->on(message => \&on_ws_message);
	$self->on(finish => \&on_ws_close);
	
	weaken $self;
	Mojo::IOLoop->singleton->on(finish => sub { $self->loop_finish });
	
	$self->ws_send({ action => 'user_data', user => $self->user_data });
}

sub loop_finish {
	my $self = shift;
	$self->finish(1001 => 'Server exiting');
}

sub ws_send {
	my ($self, $data) = @_;
	$self->send(encode_json $data);
}

my %ws_dispatch = (
	set_nick => 'ws_set_nick',
	chat => 'ws_chat',
	game_list => 'ws_game_list',
	create_game => 'ws_create_game',
	join_game => 'ws_join_game',
	start_game => 'ws_start_game',
	game_state => 'ws_game_state',
	card_data => 'ws_card_data',
	heartbeat => undef,
);

sub on_ws_message {
	my ($self, $msg) = @_;
	my $nick = $self->stash->{nick};
	return $self->app->log->warn("Received invalid WebSocket message from $nick: $msg")
		unless my $data = eval { decode_json $msg };
	$self->app->log->debug("Received WebSocket message from $nick: $msg");
	
	my $action = $data->{action} // 'unknown';
	if (exists $ws_dispatch{$action}) {
		my $method = $ws_dispatch{$action} // return;
		return $self->$method($data);
	} else {
		return $self->app->log->warn("Received unknown WebSocket action from $nick: $action");
	}
}

sub ws_set_nick {
	my ($self, $data) = @_;
	my $nick = $data->{nick};
	my $userid = $self->stash->{userid};
	$self->set_user_nick($nick);
	$self->stash->{nick} = $nick;
	$self->ws_send({ action => 'confirm_nick', confirmed => true, nick => $nick });
}

sub ws_chat {
	my ($self, $data) = @_;
	my $nick = $self->stash->{nick};
	my $game = $data->{game} // return;
	my $msg = $data->{msg};
	$self->app->log->debug("[$game] <$nick> $msg");
	$self->backend_publish("game:$game" => {
		game => $game, from => $nick, action => 'user_chat', msg => $msg, time => time
	});
}

sub ws_game_list {
	my $self = shift;
	$self->ws_send({ action => 'game_list', games => $self->game_list });
}

sub ws_create_game {
	my ($self, $data) = @_;
	my $game = $data->{game};
	$self->create_game($game);
}

sub ws_join_game {
	my ($self, $data) = @_;
	my $nick = $self->stash->{nick};
	my $game = $data->{game};
	return $self->app->log->warn("$nick tried to join game $game, but it does not exist")
		unless $self->game_exists($game);
	$self->join_game($game);
}

sub ws_start_game {
	my ($self, $data) = @_;
	my $userid = $self->stash->{userid};
	my $nick = $self->stash->{nick};
	my $game = $data->{game};
	my $status = $self->game_status($game);
	return $self->app->log->warn("$nick tried to start game $game, but it is already in progress")
		unless $status eq 'unstarted';
	my $host = $self->game_host($game);
	return $self->app->log->warn("$nick tried to start game $game, but is not the host")
		unless defined $host and $host eq $userid;
	$self->start_game($game);
}

sub ws_game_state {
	my ($self, $data) = @_;
	my $game = $data->{game};
	$self->ws_send({ game => $game, action => 'game_state', state => $self->game_state($game) });
}

sub ws_card_data {
	my ($self, $data) = @_;
	my $black_cards = $data->{cards}{black} // [];
	my $white_cards = $data->{cards}{white} // [];
	$self->ws_send({ action => 'card_data',
		cards => $self->card_data($black_cards, $white_cards) });
}

sub on_ws_close {
	my ($self, $code, $reason) = @_;
	my $nick = $self->stash->{nick};
	$self->app->log->debug("WebSocket for $nick closed with status $code");
	my $games = $self->user_games;
	foreach my $game (@$games) {
		$self->backend_publish("game:$game" =>
			{ game => $game, from => $nick, action => 'user_disconnect', time => time });
	}
	$self->unsubscribe_from_games($games);
}

sub on_backend_message {
	my ($self, $data) = @_;
	my $nick = $self->stash->{nick};
	my $action = $data->{action} // 'unknown';
	my $game = $data->{game};
	if ($action eq 'user_chat' or $action eq 'user_join' or $action eq 'user_leave' or $action eq 'user_disconnect') {
		$self->ws_send($data);
	} elsif ($action eq 'start_turn') {
		$self->ws_send({ game => $game, action => 'game_state', state => $self->game_state($game) });
	} else {
		$self->app->log->warn("Received unknown action for $nick: $action");
	}
}

sub create_game {
	my ($self, $game) = @_;
	$self->init_game($game);
	$self->ws_send({ action => 'confirm_create', confirmed => true, game => $game });
	$self->join_game($game);
}

sub join_game {
	my ($self, $game) = @_;
	my $userid = $self->stash->{userid};
	$self->subscribe_to_game($game);
	$self->add_game_player($game, $userid);
	$self->set_expires($game);
	$self->ws_send({ action => 'confirm_join', confirmed => true, game => $game });
}

sub remove_player {
	my ($self, $game, $userid) = @_;
	$self->remove_game_player($game, $userid);
	$self->set_expires($game);
}

sub start_game {
	my ($self, $game) = @_;
	# TODO: game options
	my @sets = qw/1151 1152 100211 1155 1256 100154 100415 100257 1153 1154 1488
		100422 100049 100050 100051 100312 100485 100560 100532 100531 100017/;
	my $cards = $self->gather_cards(\@sets);
	my $players = $self->game_players($game);
	my $hand_size = 7;
	my @to_deal = splice @{$cards->{white}}, 0, $hand_size * @$players;
	$self->clear_hands($game, $players);
	$self->deal_to_players($game, $players, \@to_deal);
	$self->set_game_started($game, $cards->{black}, $cards->{white});
	$self->start_turn($game);
}

sub start_turn {
	my ($self, $game) = @_;
	
	$self->set_next_czar($game);
	
	my $black_card = $self->draw_black_card($game);
	my $draw = $self->black_card_draw_count($black_card);
	$self->draw_white_cards($game) for 1..$draw;
	
	$self->set_expires($game);
	
	$self->backend_publish("game:$game" => { game => $game, action => 'start_turn' });
}

1;

